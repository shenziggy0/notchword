import json
import sys
import tempfile
import unittest
from decimal import Decimal
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from draft_morphology import write_text
from morphology_budget import Budget, BudgetStop, ATTEMPT_RESERVE


class MorphologyBudgetTests(unittest.TestCase):
    def test_meter_failed_and_successful_work_across_restarts(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            ledger = root / "budget.json"
            previous = Decimal("0.021174")
            budget = Budget(ledger, Decimal("1"), previous, write_text)
            entry = budget.reserve(1)
            run = root / "run.json"
            budget.attach(entry, run)
            (root / "sessions").mkdir()
            session = root / "sessions" / "session.jsonl"
            message = {
                "role": "assistant", "usage": {"input": 3900, "output": 16670, "cost": {"total": 0.01}},
            }
            session.write_text(json.dumps({"message": message}) + "\n", encoding="utf-8")
            run.write_text(json.dumps({"session_file": str(session), "exit_code": 0,
                                      "status": "process_succeeded"}), encoding="utf-8")
            budget.settle(entry, run)
            restarted = Budget(ledger, previous * 2 + ATTEMPT_RESERVE - Decimal("0.00001"), previous, write_text)
            self.assertEqual(restarted.spent, previous * 2)
            with self.assertRaises(BudgetStop):
                restarted.reserve(2)

            unlimited = Budget(ledger, None, previous, write_text)
            entry = unlimited.reserve(2)
            unlimited.settle(entry, run)
            self.assertEqual(unlimited.spent, previous * 3)

            restarted = Budget(ledger, Decimal("10"), previous, write_text)
            entry = restarted.reserve(2)
            run.write_text(json.dumps({"session_file": None, "exit_code": 124,
                                      "status": "timed_out"}), encoding="utf-8")
            with self.assertRaises(BudgetStop):
                restarted.settle(entry, run)
            with self.assertRaises(BudgetStop):
                Budget(ledger, Decimal("10"), previous, write_text).reserve(3)
