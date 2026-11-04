"""同形语素：写了 key 能建成且 id 不同；不写 key 则构建失败。"""
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "build_wordparts.py"

MORPHEMES = """key\trole\tlabel\tforms\tzh\ten\tlemma
act\troot\tact\tact\t做\tdo\t
in_into\tprefix\tin-\tin\t向内\tinto\t
in_not\tprefix\tin-\tin\t不\tnot\t
opt\troot\topt\topt\t选择\tchoose\t
"""

WORDS_OK = """word\tsegments\torigin\tsource
inact\tin@in_not act\t\tmanual
inopt\tin@in_into opt\t\tmanual
"""

WORDS_AMBIGUOUS = """word\tsegments\torigin\tsource
inact\tin act\t\tmanual
"""


class BuildWordpartsTests(unittest.TestCase):
    def test_homograph_keys_get_different_ids(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            morphemes = folder / "morphemes.tsv"
            words = folder / "words.tsv"
            output = folder / "wordparts.sqlite"
            morphemes.write_text(MORPHEMES, encoding="utf-8")
            words.write_text(WORDS_OK, encoding="utf-8")

            completed = subprocess.run(
                [sys.executable, str(SCRIPT),
                 "--morphemes", str(morphemes),
                 "--words", str(words),
                 "--output", str(output)],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertTrue(output.exists())

            connection = sqlite3.connect(output)
            try:
                def morpheme_id(word):
                    segments = connection.execute(
                        "SELECT segments FROM words WHERE word = ?", (word,)
                    ).fetchone()[0]
                    return int(segments.split()[0].split(":")[1])

                self.assertNotEqual(morpheme_id("inact"), morpheme_id("inopt"))
            finally:
                connection.close()

    def test_homograph_without_key_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            morphemes = folder / "morphemes.tsv"
            words = folder / "words.tsv"
            output = folder / "wordparts.sqlite"
            morphemes.write_text(MORPHEMES, encoding="utf-8")
            words.write_text(WORDS_AMBIGUOUS, encoding="utf-8")

            completed = subprocess.run(
                [sys.executable, str(SCRIPT),
                 "--morphemes", str(morphemes),
                 "--words", str(words),
                 "--output", str(output)],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("必须写 key", completed.stderr + completed.stdout)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
