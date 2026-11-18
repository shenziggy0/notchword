"""Persistent budget for the local Pi morphology job."""
import json
from decimal import Decimal


PEAK_INPUT = Decimal("0.30") / 1_000_000
PEAK_OUTPUT = Decimal("1.20") / 1_000_000
# Model catalogue: 1M context tokens, up to 384K output tokens. Budget the
# maximum even when a routine batch normally costs much less.
ATTEMPT_RESERVE = 1_000_000 * PEAK_INPUT + 384_000 * PEAK_OUTPUT


class BudgetStop(RuntimeError):
    pass


def session_cost(session):
    total = Decimal(0)
    metered = False
    with session.open(encoding="utf-8") as events:
        for line in events:
            event = json.loads(line)
            message = event.get("message", {})
            usage = message.get("usage")
            if message.get("role") != "assistant" or not usage:
                continue
            reported = Decimal(str(usage.get("cost", {}).get("total", 0)))
            tokens_in = sum(int(usage.get(key, 0)) for key in ("input", "cacheRead", "cacheWrite"))
            tokens_out = int(usage.get("output", 0))
            if reported or tokens_in or tokens_out:
                metered = True
                total += max(reported, tokens_in * PEAK_INPUT + tokens_out * PEAK_OUTPUT)
    return total if metered else None


class Budget:
    def __init__(self, path, limit, previous, write_text):
        self.path = path
        self.limit = limit
        self.write_text = write_text
        self.records = json.loads(path.read_text(encoding="utf-8")) if path.exists() else []
        if not self.records:
            self.records.append({"status": "recorded", "usd": str(previous), "source": "previous spend"})
            self.save()
        elif Decimal(self.records[0]["usd"]) != previous:
            raise BudgetStop("前序用量与账本不一致。续跑时请使用相同的前序费用")

    def save(self):
        self.write_text(self.path, json.dumps(self.records, ensure_ascii=False, indent=2) + "\n")

    @property
    def spent(self):
        return sum((Decimal(row["usd"]) for row in self.records), Decimal(0))

    def reserve(self, batch):
        if any(row["status"] == "reserved" for row in self.records):
            raise BudgetStop("上一笔请求的费用未核实。为保护预算，先停止后续调用")
        if self.limit is not None and self.spent + ATTEMPT_RESERVE > self.limit:
            raise BudgetStop(f"已记 US${self.spent:.4f}，剩余额度不足以覆盖下一次调用的上限")
        entry = {"status": "reserved", "batch": batch, "usd": str(ATTEMPT_RESERVE)}
        self.records.append(entry)
        self.save()
        return entry

    def attach(self, entry, run_file):
        entry["run_file"] = str(run_file)
        self.save()

    def settle(self, entry, run_file):
        result = json.loads(run_file.read_text(encoding="utf-8"))
        path = result.get("session_file")
        cost = session_cost(run_file.parent / "sessions" / path.rsplit("/", 1)[-1]) if path else None
        if not result.get("exit_code") and result.get("status") == "process_succeeded" and cost is not None:
            entry.update(status="recorded", usd=str(cost))
            self.save()
            limit = f" / US${self.limit:.2f}" if self.limit is not None else ""
            print(f"本次按峰值费率计 US${cost:.4f}，累计 US${self.spent:.4f}{limit}", flush=True)
            if self.limit is not None and self.spent > self.limit:
                raise BudgetStop("累计费用超过预算，已停止后续调用")
            return
        if cost is not None and cost > ATTEMPT_RESERVE:
            entry["usd"] = str(cost)
            self.save()
        raise BudgetStop(f"Pi 未正常结束或没有可核实的用量，保留费用预留并暂停。运行记录 {run_file}")
