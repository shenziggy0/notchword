"""Core regression for Wiktionary extraction and the draft/build contract."""
import json
import sqlite3
import sys
import tempfile
import unittest
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from contextlib import closing
from build_wordparts import MORPHEME_HEADER, WORDPARTS_HEADER, build, read_manual_bindings, read_tsv
from build_dictionary import dedupe, parse_exchange
from draft_morphology import parse_draft, validate_draft
from extract_wiktionary import candidates, collect_templates


class MorphologyPipelineTests(unittest.TestCase):
    @staticmethod
    def _manual_baseline():
        """仅提取人工基线（source == manual）及其引用的语素，避免与全量生产后的词条冲突。"""
        all_parts = read_tsv(ROOT / "data/morphemes.tsv", MORPHEME_HEADER)
        all_words = read_tsv(ROOT / "data/wordparts.tsv", WORDPARTS_HEADER)
        bindings = read_manual_bindings(ROOT / "data/manual-form-bindings.tsv")
        manual_words = [row for row in all_words if row["source"] == "manual"]
        by_key = {row["key"]: row for row in all_parts}
        by_form = defaultdict(list)
        for row in all_parts:
            for form in row["forms"].split():
                by_form[form].append(row["key"])
        used_keys = set()
        for row in manual_words:
            for seg in row["segments"].split():
                if "@" in seg:
                    used_keys.add(seg.split("@", 1)[1])
                elif seg in bindings:
                    used_keys.add(bindings[seg])
                else:
                    used_keys.update(by_form.get(seg, []))
        manual_parts = [by_key[k] for k in used_keys if k in by_key]
        return manual_parts, manual_words, bindings

    def test_dictionary_alias_keeps_exam_tags_on_the_canonical_word(self):
        corrected = dedupe([
            {"word": "reservior", "tag": "cet4", "frq": 0, "translation": "贮水池"},
            {"word": "reservoir", "tag": "cet6 ky toefl ielts", "frq": 9270, "translation": "水库"},
        ])
        self.assertEqual(corrected, [
            {"word": "reservoir", "tag": "cet6 ky toefl ielts cet4", "frq": 9270, "translation": "水库"},
        ])

    def test_parse_exchange_keeps_inflections_on_own_headword(self):
        lemma, forms = parse_exchange("0:find/1:dp/d:founded/p:founded/i:founding/3:founds/s:founds", "found")
        self.assertEqual(lemma, "found")
        self.assertIn("founded", forms)
        self.assertIn("founds", forms)

    def test_evidenced_recursive_split(self):
        entries = [
            {"word": "unbelievable", "lang_code": "en",
             "etymology_text": "Etymology tree\nEnglish believable\nFrom un- + believable.",
             "etymology_templates": [
                {"name": "pre", "args": {"1": "en", "2": "un", "3": "believable", "id1": "negative"}},
            ]},
            {"word": "believable", "lang_code": "en", "etymology_templates": [
                {"name": "ety", "args": {"1": "en", "2": ":af", "3": "believe", "4": "-able"}},
            ]},
        ]
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "wiktionary.jsonl"
            path.write_text("".join(json.dumps(item) + "\n" for item in entries), encoding="utf-8")
            evidence = defaultdict(set)
            templates = collect_templates(path, {"unbelievable"}, evidence)
            self.assertIn(("un", "believ", "able"), candidates("unbelievable", templates))
            self.assertEqual(evidence, {"unbelievable": {"From un- + believable."}})

    def test_staged_draft_validates_against_existing_human_data(self):
        parts, words, _ = self._manual_baseline()
        response = ("PART\twash\troot\twash\twash\t洗\twash\t\n"
                    "WORD\twashable\twash@wash able@able\twash + -able，可清洗\twiktionary\n"
                    "REVIEW\tunknown\t证据不足\n")
        new_parts, new_words, simplex, review = parse_draft(
            response, {"washable", "unknown"}, {"washable": ["wash able"]}, parts)
        self.assertEqual(simplex, set())
        self.assertEqual(review, {"unknown": "证据不足"})
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "wordparts.sqlite"
            build(parts + new_parts, words + new_words, path)
            with closing(sqlite3.connect(path)) as db:
                self.assertEqual(db.execute("SELECT count(*) FROM words").fetchone()[0], len(words) + 1)
                self.assertTrue(db.execute("SELECT 1 FROM words WHERE word = 'washable'").fetchone())
        unsupported = response.replace("证据不足\n", "证据不足\t\n")
        _, rows, _, pending = parse_draft(unsupported, {"washable", "unknown"}, {}, parts)
        self.assertEqual(rows[0]["source"], "ai")
        self.assertEqual(pending, {"unknown": "证据不足"})

        _, _, simplex, review = parse_draft(
            "SIMPLEX\twashable\n", {"washable", "missed"}, {"washable": ["wash able"]}, parts)
        self.assertEqual(simplex, set())
        self.assertEqual(review.keys(), {"washable", "missed"})

    def test_new_homograph_forms_preserve_manual_segments(self):
        parts, words, _ = self._manual_baseline()
        response = ("PART\tabil\troot\table\table abil\t能\table\thabilis\n"
                    "PART\twash\troot\twash\twash\t洗\twash\t\n"
                    "WORD\tability\tabil@abil ity@ity\thabilis + -ity\tai\n"
                    "WORD\tabilitys\tabil@abil ity@ity\thabilis + -ity\tai\n"
                    "WORD\twashable\twash@wash able@abil\twash + -able\tai\n")
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "wordparts.sqlite"
            added, accepted, _, pending = validate_draft(
                response, ["ability", "abilitys", "washable"], {}, parts, words, path
            )
            self.assertEqual(added[0]["forms"], "abil")
            self.assertEqual([row["word"] for row in accepted], ["ability"])
            self.assertIn("abilitys", pending)
            self.assertIn("washable", pending)

    def test_manual_bindings_keep_original_meaning_with_homograph(self):
        parts, words, bindings = self._manual_baseline()
        response = ("PART\tair\troot\tair\tair\t空气\tair\tair\n"
                    "PART\tport_harbor\troot\tport\tport\t港口\tharbor\tportus\n"
                    "WORD\tairport\tair@air port@port_harbor\tair + port\twiktionary\n")
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "wordparts.sqlite"
            _, accepted, _, pending = validate_draft(
                response, ["airport"], {"airport": ["air port"]}, parts, words, path, bindings
            )
            self.assertEqual([row["word"] for row in accepted], ["airport"])
            self.assertEqual(pending, {})
            with closing(sqlite3.connect(path)) as database:
                for word, index, expected in (("portable", 0, "carry"), ("airport", 1, "harbor")):
                    segments, = database.execute("SELECT segments FROM words WHERE word = ?", (word,)).fetchone()
                    part_id = int(segments.split()[index].split(":")[1])
                    self.assertEqual(database.execute("SELECT en FROM parts WHERE id = ?", (part_id,)).fetchone(),
                                     (expected,))
