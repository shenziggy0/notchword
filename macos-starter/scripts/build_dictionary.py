#!/usr/bin/env python3
"""从 ECDICT CSV 生成随包 `dictionary.sqlite`。

输入（固定版本，MIT 许可）：
    ECDICT  https://github.com/skywind3000/ECDICT  ecdict.csv

用法：
    python3 scripts/build_dictionary.py \
        --input scripts/.cache/ecdict.csv \
        --output Sources/Englishwords/Resources/dictionary.sqlite

重建规则：
    - 只保留有中文释义、且是单个英文词的条目
    - 保留常用词（frq 1..60000）或带考试标签的词，控制随包体积
    - 词头统一小写；重复时优先保留带考试标签、词频更靠前的条目
    - forms 由 ECDICT 的 exchange 字段解析（p/i/d/3/r/t/s 等），只保留能回到词头的形式

任一校验失败时非零退出，并且不覆盖已经存在的输出文件。
"""
import argparse
import csv
import os
import re
import sqlite3
import sys
import tempfile

MAX_FRQ = 60000
WORD_PATTERN = re.compile(r"^[a-z][a-z'\-]*$")
FORM_PATTERN = re.compile(r"^[a-z][a-z'\-]*$")
HEADWORD_ALIASES = {"reservior": "reservoir"}


def exchange_forms(exchange):
    for piece in (exchange or "").split("/"):
        kind, separator, value = piece.partition(":")
        value = value.strip().lower()
        if separator and value and kind not in {"0", "1"}:
            yield kind, value


def parse_exchange(exchange, word):
    """ECDICT exchange 字段 -> (lemma, [forms])。

    词头自身的屈折形式（p/d/i/3/r/t/s）只归属于该词头本身，
    不被 `0:` 指向的上位原形覆写（避免 founded -> find 等错映射）。
    """
    return word, [value for _, value in exchange_forms(exchange)]


def load_rows(path):
    csv.field_size_limit(10 ** 9)
    rows = []
    with open(path, newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        required = {"word", "phonetic", "translation", "pos", "tag", "frq", "exchange"}
        missing = required - set(reader.fieldnames or [])
        if missing:
            raise SystemExit(f"输入缺少列：{', '.join(sorted(missing))}")

        for raw in reader:
            word = (raw.get("word") or "").strip().lower()
            translation = (raw.get("translation") or "").strip()
            if not word or not translation or not WORD_PATTERN.match(word):
                continue

            try:
                frequency = int((raw.get("frq") or "0").strip() or 0)
            except ValueError:
                frequency = 0

            tag = " ".join((raw.get("tag") or "").split())
            if not tag and not (1 <= frequency <= MAX_FRQ):
                continue

            rows.append({
                "word": word,
                "phonetic": (raw.get("phonetic") or "").strip(),
                "translation": translation.replace("\\n", "\n"),
                "pos": (raw.get("pos") or "").strip(),
                "tag": tag,
                "frq": frequency,
                "exchange": raw.get("exchange") or "",
            })
    return rows


def dedupe(rows):
    """同一个词头只留一条：优先带标签、再按词频靠前。"""
    best = {}
    for row in rows:
        current = best.get(row["word"])
        if current is None:
            best[row["word"]] = row
            continue
        candidate_rank = (0 if row["tag"] else 1, row["frq"] or 10 ** 9)
        current_rank = (0 if current["tag"] else 1, current["frq"] or 10 ** 9)
        if candidate_rank < current_rank:
            best[row["word"]] = row
    for alias, canonical in HEADWORD_ALIASES.items():
        if alias in best and canonical in best:
            tags = dict.fromkeys(best[canonical]["tag"].split() + best[alias]["tag"].split())
            best[canonical] = {**best[canonical], "tag": " ".join(tags)}
            del best[alias]
    return [best[key] for key in sorted(best)]


def build(rows, output):
    words = {row["word"] for row in rows}
    form_map = {}
    readings = set()
    for row in rows:
        lemma = row["word"]
        if lemma not in words:
            continue
        for kind, form in exchange_forms(row["exchange"]):
            if form == lemma or not FORM_PATTERN.match(form):
                continue
            if kind in {"p", "d", "i", "3", "r", "t", "s"}:
                readings.add((form, lemma, kind))
            if form not in words:
                form_map.setdefault(form, lemma)
    form_map.update({alias: canonical for alias, canonical in HEADWORD_ALIASES.items()
                     if canonical in words and alias not in words})

    handle, temp_path = tempfile.mkstemp(suffix=".sqlite", dir=os.path.dirname(output) or ".")
    os.close(handle)
    os.unlink(temp_path)

    connection = sqlite3.connect(temp_path)
    try:
        connection.executescript(
            """
            PRAGMA journal_mode=OFF;
            PRAGMA synchronous=OFF;
            CREATE TABLE words (
                word        TEXT PRIMARY KEY,
                phonetic    TEXT,
                translation TEXT NOT NULL,
                pos         TEXT,
                tag         TEXT,
                frq         INTEGER
            ) WITHOUT ROWID;
            CREATE TABLE forms (
                form  TEXT PRIMARY KEY,
                lemma TEXT NOT NULL
            ) WITHOUT ROWID;
            """
        )
        connection.executemany(
            "INSERT INTO words (word, phonetic, translation, pos, tag, frq) VALUES (?, ?, ?, ?, ?, ?)",
            [(r["word"], r["phonetic"], r["translation"], r["pos"], r["tag"], r["frq"]) for r in rows],
        )
        connection.executemany(
            "INSERT INTO forms (form, lemma) VALUES (?, ?)",
            sorted(form_map.items()),
        )
        connection.executescript("""
            CREATE TABLE form_readings (
                form TEXT NOT NULL,
                lemma TEXT NOT NULL REFERENCES words(word),
                kind TEXT NOT NULL,
                short_gloss TEXT,
                PRIMARY KEY (form, lemma, kind)
            ) WITHOUT ROWID;
            CREATE TABLE phrases (pattern TEXT PRIMARY KEY, gloss TEXT NOT NULL) WITHOUT ROWID;
        """)
        glosses = {("foiled", "foil"): "挫败、阻止"}
        connection.executemany(
            "INSERT INTO form_readings VALUES (?, ?, ?, ?)",
            [(form, lemma, kind, glosses.get((form, lemma)))
             for form, lemma, kind in sorted(readings)
             if form in words or form_map.get(form) != lemma],
        )
        phrase_path = os.path.join(os.path.dirname(__file__), "../data/phrases.tsv")
        with open(phrase_path, encoding="utf-8", newline="") as source:
            phrases = csv.DictReader(source, delimiter="\t")
            connection.executemany("INSERT INTO phrases VALUES (?, ?)",
                                   [(row["pattern"], row["gloss"]) for row in phrases])
        connection.commit()

        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
        if integrity != "ok":
            raise SystemExit(f"integrity_check 失败：{integrity}")

        dangling = connection.execute(
            "SELECT COUNT(*) FROM forms WHERE lemma NOT IN (SELECT word FROM words)"
        ).fetchone()[0]
        if dangling:
            raise SystemExit(f"forms.lemma 有 {dangling} 条无法回到词头")

        word_count = connection.execute("SELECT COUNT(*) FROM words").fetchone()[0]
        form_count = connection.execute("SELECT COUNT(*) FROM forms").fetchone()[0]
        if word_count < 10000:
            raise SystemExit(f"词条数量异常：{word_count}")
    except BaseException:
        connection.close()
        if os.path.exists(temp_path):
            os.unlink(temp_path)
        raise

    connection.close()
    os.replace(temp_path, output)
    return word_count, form_count


def main():
    parser = argparse.ArgumentParser(description="生成 dictionary.sqlite")
    parser.add_argument("--input", required=True, help="ECDICT ecdict.csv")
    parser.add_argument("--output", required=True, help="输出 dictionary.sqlite")
    args = parser.parse_args()

    if not os.path.exists(args.input):
        raise SystemExit(f"输入不存在：{args.input}")

    rows = dedupe(load_rows(args.input))
    if not rows:
        raise SystemExit("没有可用词条")

    words, forms = build(rows, args.output)
    print(f"dictionary.sqlite: {words} 词条, {forms} 屈折形式 -> {args.output}")


if __name__ == "__main__":
    main()
