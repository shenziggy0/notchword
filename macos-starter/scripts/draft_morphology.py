#!/usr/bin/env python3
"""Draft wordparts in resumable batches. Keep all output separate from shipped data."""
import argparse
import fcntl
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from collections import defaultdict
from decimal import Decimal, InvalidOperation
from pathlib import Path

from build_wordparts import (
    DEFAULT_TAGS, MORPHEME_HEADER, WORDPARTS_HEADER, build, index_morphemes,
    read_manual_bindings, read_tsv, read_word_list, resolve_piece, target_words,
)
from morphology_budget import Budget, BudgetStop


def write_text(path, value):
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, delete=False) as stream:
        staging = Path(stream.name)
        stream.write(value)
    try:
        staging.replace(path)
    finally:
        staging.unlink(missing_ok=True)


def append_rows(seed, header, rows):
    body = "".join("\t".join(row[key] for key in header) + "\n" for row in rows)
    return seed.read_text(encoding="utf-8").rstrip("\n") + "\n" + body


def parse_draft(response, expected, candidates, existing_parts):
    parts, words, simplex, review = [], [], set(), {}
    keyed_parts = {part["key"]: part for part in existing_parts}
    conflicting_keys, conflicting_forms = set(), set()
    reported = set()
    lines = response.strip("\n").splitlines()
    if len(lines) >= 2 and lines[0].strip().lower() in {"```tsv", "```"} and lines[-1].strip() == "```":
        lines = lines[1:-1]
    for line in lines:
        if not line.strip():
            continue
        record, *fields = line.split("\t")
        if record == "PART" and len(fields) == len(MORPHEME_HEADER):
            part = dict(zip(MORPHEME_HEADER, fields))
            key = part["key"]
            if prior := keyed_parts.get(key):
                if prior != part:
                    conflicting_keys.add(key)
                    conflicting_forms.update(prior["forms"].split())
                    conflicting_forms.update(part["forms"].split())
            else:
                keyed_parts[key] = part
                parts.append(part)
            continue
        width = {"WORD": 4, "SIMPLEX": 1, "REVIEW": 2}.get(record, -1)
        if width >= 0 and len(fields) > width and not any(fields[width:]):
            fields = fields[:width]
        if len(fields) != width:
            raise ValueError("模型输出行结构错误")
        word = fields[0]
        if word not in expected or word in reported:
            raise ValueError(f"意外或重复词：{word}")
        reported.add(word)
        if record == "WORD":
            segments, origin, source = fields[1:]
            if len(segments.split()) < 2 or not origin.strip() or source not in {"ai", "wiktionary"}:
                raise ValueError(f"{word} 至少需要两个片段、有效词源和来源")
            spelling = " ".join(piece.partition("@")[0] for piece in segments.split())
            if source == "wiktionary" and spelling not in candidates.get(word, ()):
                source = "ai"
            words.append(dict(zip(WORDPARTS_HEADER, [word, segments, origin, source])))
        elif record == "SIMPLEX":
            if candidates.get(word):
                review[word] = "有可拼回原词的 Wiktionary 拆分候选，需确认适用词义和单纯词判定"
            else:
                simplex.add(word)
        elif fields[1].strip():
            review[word] = fields[1]
        else:
            raise ValueError(f"{word} 缺少复核原因")
    if not reported:
        raise ValueError("模型未返回目标词")
    review.update(dict.fromkeys(expected - reported, "模型回应遗漏此词，待补稿"))
    accepted = []
    for row in words:
        for piece in row["segments"].split():
            form, _, key = piece.partition("@")
            if key in conflicting_keys or (not key and form in conflicting_forms):
                review[row["word"]] = f"语素 {key or form} 的定义与当前词表或同批记录冲突"
                break
        else:
            accepted.append(row)
    return [part for part in parts if part["key"] not in conflicting_keys], accepted, simplex, review


def unqualified_forms(words, manual_bindings):
    return {piece for row in words for piece in row["segments"].split()
            if "@" not in piece and (row["source"] != "manual" or piece not in manual_bindings)}


def validate_draft(response, batch, candidates, parts, words, database, manual_bindings=None):
    added_parts, added_words, simplex, review = parse_draft(response, set(batch), candidates, parts)
    protected = unqualified_forms(words, manual_bindings or {})
    for part in added_parts:
        # New homographs cannot change how existing unqualified segments resolve.
        part["forms"] = " ".join(form for form in part["forms"].split() if form not in protected)
    added_parts = [part for part in added_parts if part["forms"]]
    ids, forms = index_morphemes(parts + added_parts)
    accepted = []
    accepted_keys = set()
    for row in added_words:
        word = row["word"]
        try:
            resolved = [resolve_piece(piece, forms, ids, word) for piece in row["segments"].split()]
            spelling = "".join(form for form, _ in resolved)
            if spelling != word:
                raise ValueError(f"拆分拼回为 {spelling}")
        except (SystemExit, ValueError) as error:
            review[word] = str(error)
        else:
            accepted.append(row)
            accepted_keys.update(key for _, key in resolved)
    added_parts = [part for part in added_parts if part["key"] in accepted_keys]
    build(parts + added_parts, words + accepted, database, manual_bindings=manual_bindings)
    return added_parts, accepted, simplex, review


def run_pi(runner, cli, prompt, workspace, budget, batch):
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", suffix=".md", dir=workspace,
                                     delete=False) as stream:
        task = Path(stream.name)
        stream.write(
            f"目标：为 RFC 0006 词素库起草一批待判定词。工作目录：{workspace}。"
            "思考强度 high，因为任务和格式明确。只输出 TSV，禁止编辑文件、再次调用 AI、提交或推送。\n"
            + prompt
        )
    try:
        ticket = budget.reserve(batch)
        run_file = None
        with subprocess.Popen(
            [sys.executable, str(runner), "--cwd", str(workspace), "--prompt-file", str(task),
             "--access", "none", "--pi-bin", cli, "--model", "deepseek-flash", "--thinking", "high", "--timeout", "900"],
            cwd=workspace, stdout=subprocess.PIPE, text=True,
        ) as process:
            for line in process.stdout:
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(event, dict) and event.get("run_file"):
                    run_file = Path(event["run_file"])
                    budget.attach(ticket, run_file)
                    print(f"Pi 批次 {batch} 正在运行：{run_file}", flush=True)
        if run_file is None:
            raise BudgetStop(f"Pi 运行记录缺失（退出码 {process.returncode}），保留预留金额并暂停")
        budget.settle(ticket, run_file)
    finally:
        task.unlink(missing_ok=True)
    response = (run_file.parent / "result.md").read_text(encoding="utf-8")
    return response, run_file.parent


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dictionary", type=Path, default=Path("Sources/Englishwords/Resources/dictionary.sqlite"))
    for name, filename in (("morphemes", "morphemes.tsv"), ("words", "wordparts.tsv"),
                           ("simplex", "simplex.txt"), ("extra", "wordlist-extra.txt")):
        parser.add_argument(f"--{name}", type=Path, default=Path("data") / filename)
    parser.add_argument("--prompt", type=Path, default=Path("scripts/prompts/morphology.md"))
    parser.add_argument("--candidates", type=Path, required=True)
    parser.add_argument("--evidence", type=Path)
    parser.add_argument("--manual-form-bindings", type=Path)
    parser.add_argument("--run-dir", type=Path, required=True)
    spending = parser.add_mutually_exclusive_group(required=True)
    spending.add_argument("--budget-usd", type=Decimal)
    spending.add_argument("--no-budget-limit", action="store_true", help="继续记账，取消支出上限")
    parser.add_argument("--budget-ledger", type=Path, help="在多个暂存批次之间共享费用记录")
    parser.add_argument("--previous-spend-usd", type=Decimal, default=Decimal(0))
    parser.add_argument("--pi-cli", default="pi")
    parser.add_argument("--pi-runner", type=Path,
                        default=Path.home() / ".codex/skills/pi-cli/scripts/run_pi.py")
    parser.add_argument("--batch-size", type=int, default=150)
    parser.add_argument("--max-batches", type=int)
    try:
        args = parser.parse_args()
    except InvalidOperation:
        parser.error("预算和前序费用须为美元金额")
    if not args.previous_spend_usd.is_finite() or args.previous_spend_usd < 0:
        parser.error("前序费用须为非负的美元金额")
    if args.budget_usd is not None and (
        not args.budget_usd.is_finite() or args.budget_usd <= 0 or args.previous_spend_usd > args.budget_usd
    ):
        parser.error("预算须为正数，并覆盖前序费用")
    if not 1 <= args.batch_size <= 200 or (args.max_batches is not None and args.max_batches < 1):
        parser.error("批大小须为 1—200，试跑批次数须为正数")
    return args


def main():
    args = arguments()
    cli = shutil.which(args.pi_cli)
    if cli is None or not args.pi_runner.is_file():
        raise SystemExit("需要本机 Pi CLI 和 pi-cli 技能的 run_pi.py")
    runner = args.pi_runner.resolve()
    model_list = subprocess.run([cli, "--list-models", "deepseek-flash"],
                                capture_output=True, text=True, timeout=15, check=True)
    if not any(row.split()[1:2] == ["deepseek-flash"] for row in model_list.stdout.splitlines()):
        raise SystemExit("Pi 未列出 deepseek-flash 模型")
    candidates = defaultdict(list)
    for row in read_tsv(args.candidates, ["word", "segments"]):
        candidates[row["word"]].append(row["segments"])
    evidence = defaultdict(list)
    if args.evidence:
        for row in read_tsv(args.evidence, ["word", "etymology"]):
            evidence[row["word"]].append(row["etymology"])
    parts = read_tsv(args.morphemes, MORPHEME_HEADER)
    words = read_tsv(args.words, WORDPARTS_HEADER)
    manual_bindings = read_manual_bindings(args.manual_form_bindings)
    simplex = set(read_word_list(args.simplex))
    targets = target_words(args.dictionary, DEFAULT_TAGS, args.extra)
    pending = sorted(targets - simplex - {row["word"] for row in words})
    base_parts, base_words, base_simplex = len(parts), len(words), set(simplex)
    prompt = args.prompt.read_text(encoding="utf-8")

    output = args.run_dir.resolve()
    if output in {path.resolve().parent for path in (args.morphemes, args.words, args.simplex)}:
        raise SystemExit("运行目录必须与源数据目录分离")
    output.mkdir(parents=True, exist_ok=True)
    # The descriptor stays open until main exits, so concurrent runs cannot
    # reserve from the same budget or write over one another's checkpoints.
    lock = (output / "run.lock").open("a", encoding="utf-8")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise SystemExit("此运行目录已有批处理正在执行")
    ledger = (args.budget_ledger or output / "budget.json").resolve()
    ledger.parent.mkdir(parents=True, exist_ok=True)
    ledger_lock = ledger.with_suffix(ledger.suffix + ".lock").open("a", encoding="utf-8")
    try:
        fcntl.flock(ledger_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise SystemExit("此预算已有批处理正在执行")
    budget = Budget(ledger, args.budget_usd, args.previous_spend_usd, write_text)
    manifest = {
        "model": "deepseek-flash", "thinking": "high", "batch_size": args.batch_size,
        "inputs": {key: hashlib.sha256(getattr(args, key).read_bytes()).hexdigest()
                   for key in ("dictionary", "morphemes", "words", "simplex", "extra", "prompt", "candidates")},
    }
    for key in ("evidence", "manual_form_bindings"):
        if path := getattr(args, key):
            manifest["inputs"][key] = hashlib.sha256(path.read_bytes()).hexdigest()
    manifest_path = output / "manifest.json"
    if manifest_path.exists() and json.loads(manifest_path.read_text(encoding="utf-8")) != manifest:
        raise SystemExit("输入或配置与上次不同，请使用新的运行目录")
    write_text(manifest_path, json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    print(f"目标词 {len(targets)}；待起草 {len(pending)}；每批最多 {args.batch_size} 词", flush=True)

    review = {}
    fetched = 0
    with tempfile.TemporaryDirectory(prefix="ew-morph-") as temp:
        temporary = Path(temp)
        workspace = temporary / "pi"
        workspace.mkdir()
        for start in range(0, len(pending), args.batch_size):
            batch = pending[start:start + args.batch_size]
            batch_path = output / f"batch-{start // args.batch_size + 1:04d}.tsv"
            if batch_path.exists():
                draft = validate_draft(batch_path.read_text(encoding="utf-8"), batch, candidates, parts,
                                       words, temporary / "check.sqlite", manual_bindings)
            else:
                if args.max_batches is not None and fetched >= args.max_batches:
                    break
                fetched += 1
                summary = "\n".join(f"{row['key']}\t{row['role']}\t{row['forms']}\t{row['zh']}" for row in parts)
                inputs = "\n".join(
                    f"{word}\t{' | '.join(candidates[word]) or '-'}\t{' | '.join(evidence[word]) or '-'}"
                    for word in batch
                )
                protected = " ".join(sorted(unqualified_forms(words, manual_bindings)))
                request = (f"{prompt}\n既有拆分中未写 key 的受保护拼写：{protected}\n"
                           "允许为缺少的语素新增 PART，词形只列实际引用的表面形式。"
                           "只有受保护拼写不可新增同形；其他同形语素可用不同 key。"
                           "可表达常见屈折后缀，遇拼写变化可使用有依据的表面词干。\n"
                           f"现有语素（key、角色、词形、含义）：\n{summary}\n待判定词、候选及词源摘录：\n{inputs}")
                error = ""
                draft = None
                stopped = False
                for _ in range(3):
                    correction = f"\n上次校验失败，请修正并重发整个批次：{error}" if error else ""
                    try:
                        response, run_dir = run_pi(runner, cli, request + correction, workspace, budget,
                                                   start // args.batch_size + 1)
                    except (RuntimeError, subprocess.TimeoutExpired) as failure:
                        error = str(failure)
                        stopped = True
                        break
                    try:
                        validated = validate_draft(response, batch, candidates, parts, words,
                                                   temporary / "check.sqlite", manual_bindings)
                    except (ValueError, SystemExit) as failure:
                        error = str(failure)[:400]
                        write_text(run_dir / "review.md", f"# 词素批次审核\n\n格式或构建校验未通过。{error}\n")
                        continue
                    draft = validated
                    write_text(run_dir / "review.md",
                               "# 词素批次审核\n\n通过 TSV、候选来源和 SQLite 构建校验。"
                               f"暂存拆分 {len(draft[1])} 条、单纯词 {len(draft[2])} 条。"
                               f"{len(draft[3])} 条待复核。词源内容待抽样人工复核。\n")
                    write_text(batch_path, response.rstrip("\n") + "\n")
                    print(f"批次 {start // args.batch_size + 1} 已保存，暂存拆分 {len(draft[1])} 条、"
                          f"单纯词 {len(draft[2])} 条，待复核 {len(draft[3])} 条", flush=True)
                    break
                if draft is None:
                    print(error, flush=True)
                    review.update(dict.fromkeys(batch, error))
                    if stopped:
                        break
                    continue
            parts.extend(draft[0])
            words.extend(draft[1])
            simplex.update(draft[2])
            review.update(draft[3])

    failures = "word\treason\n" + "".join(f"{word}\t{' '.join(reason.split())}\n" for word, reason in sorted(review.items()))
    write_text(output / "draft_failures.tsv", failures)
    write_text(output / "morphemes.tsv", append_rows(args.morphemes, MORPHEME_HEADER, parts[base_parts:]))
    write_text(output / "wordparts.tsv", append_rows(args.words, WORDPARTS_HEADER, words[base_words:]))
    seed = args.simplex.read_text(encoding="utf-8").rstrip("\n")
    additions = "".join(f"{word}\n" for word in sorted(simplex - base_simplex))
    write_text(output / "simplex.txt", (seed + "\n" if seed else "") + additions)

    missing = targets - simplex - {row["word"] for row in words}
    print(f"已请求 {fetched} 批；新增拆分 {len(words)-base_words}；新增单纯词 {len(simplex-base_simplex)}；"
          f"需复核 {len(review)}；未覆盖 {len(missing)}")
    if missing:
        raise SystemExit("词表仍不完整，保留分批结果，暂不生成发布词库")
    coverage = {"tags": " ".join(DEFAULT_TAGS), "target": len(targets), "simplex": len(simplex & targets)}
    build(parts, words, output / "wordparts.sqlite", coverage=coverage, manual_bindings=manual_bindings)


if __name__ == "__main__":
    main()
