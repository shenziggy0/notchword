#!/usr/bin/env python3
"""从固定版本的词素源文件生成 `wordparts.sqlite`。

输入（均在 data/ 下，随仓库固定版本）：
    morphemes.tsv   key, role, label, forms, zh, en, lemma
    wordparts.tsv   word, segments, origin

用法：
    python3 scripts/build_wordparts.py \
        --morphemes data/morphemes.tsv \
        --words data/wordparts.tsv \
        --output Sources/Englishwords/Resources/wordparts.sqlite

校验规则（任一失败非零退出，不覆盖已有输出）：
    - role 只能是 prefix / root / suffix
    - 每个 segments 片段都能解析到语素，且拼起来正好等于 word
    - 同一语素形态不允许映射到两个语素
    - word 不重复，且是单个英文小写词
    - 生成后 integrity_check、引用完整性、segments 编码格式

覆盖不足时如实缺省：没有拆分的词不会出现在 words 表里，不生成猜测。
"""
import argparse
import os
import re
import sqlite3
import sys
import tempfile

WORD_PATTERN = re.compile(r"^[a-z][a-z'\-]*$")
ROLES = {"prefix", "root", "suffix"}
MORPHEME_HEADER = ["key", "role", "label", "forms", "zh", "en", "lemma"]
WORDPARTS_HEADER = ["word", "segments", "origin"]

VERSION = "2026-11-03"
SOURCE = "本项目整理，依据维基词典词源"
LICENSE = "CC BY-SA 4.0"


def read_tsv(path, header):
    with open(path, encoding="utf-8") as handle:
        lines = [line.rstrip("\n") for line in handle if line.strip()]
    if not lines:
        raise SystemExit(f"{path} 为空")
    actual = lines[0].split("\t")
    if actual != header:
        raise SystemExit(f"{path} 表头应为 {header}，实际 {actual}")
    rows = []
    for number, line in enumerate(lines[1:], start=2):
        cells = line.split("\t")
        if len(cells) != len(header):
            raise SystemExit(f"{path}:{number} 列数不对（{len(cells)}）")
        rows.append(dict(zip(header, cells)))
    return rows


def build(morphemes, wordparts, output):
    surfaces = {}
    ids = {}

    for index, morpheme in enumerate(sorted(morphemes, key=lambda m: m["key"]), start=1):
        key = morpheme["key"].strip()
        if not key:
            raise SystemExit("存在空的语素 key")
        if morpheme["role"] not in ROLES:
            raise SystemExit(f"{key}: role 非法 {morpheme['role']}")
        for column in ("label", "zh", "en"):
            if not morpheme[column].strip():
                raise SystemExit(f"{key}: {column} 不能为空")
        ids[key] = index
        for form in morpheme["forms"].split():
            if form in surfaces:
                raise SystemExit(f"语素形态重复：{form}（{surfaces[form]} / {key}）")
            surfaces[form] = key

    rows = []
    seen = set()
    for entry in wordparts:
        word = entry["word"].strip().lower()
        if not WORD_PATTERN.match(word):
            raise SystemExit(f"非法词形：{word}")
        if word in seen:
            raise SystemExit(f"重复词条：{word}")
        seen.add(word)

        pieces = entry["segments"].split()
        if not pieces:
            raise SystemExit(f"{word}: segments 为空")
        if "".join(pieces) != word:
            raise SystemExit(f"{word}: 拆分拼回为 {''.join(pieces)}")

        encoded = []
        for piece in pieces:
            key = surfaces.get(piece)
            if key is None:
                raise SystemExit(f"{word}: 片段 {piece} 没有对应语素")
            encoded.append(f"{piece}:{ids[key]}")
        rows.append((word, " ".join(encoded), entry["origin"].strip()))

    handle, temp_path = tempfile.mkstemp(suffix=".sqlite", dir=os.path.dirname(output) or ".")
    os.close(handle)
    os.unlink(temp_path)

    connection = sqlite3.connect(temp_path)
    try:
        connection.executescript(
            """
            PRAGMA journal_mode=OFF;
            PRAGMA synchronous=OFF;
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
            CREATE TABLE parts (
                id    INTEGER PRIMARY KEY,
                role  TEXT NOT NULL,
                label TEXT NOT NULL,
                zh    TEXT NOT NULL,
                en    TEXT NOT NULL,
                lemma TEXT
            );
            CREATE TABLE words (
                word     TEXT PRIMARY KEY,
                segments TEXT NOT NULL,
                origin   TEXT
            ) WITHOUT ROWID;
            """
        )
        connection.executemany(
            "INSERT INTO parts (id, role, label, zh, en, lemma) VALUES (?, ?, ?, ?, ?, ?)",
            [
                (ids[m["key"]], m["role"], m["label"].strip(), m["zh"].strip(),
                 m["en"].strip(), m["lemma"].strip() or None)
                for m in morphemes
            ],
        )
        connection.executemany(
            "INSERT INTO words (word, segments, origin) VALUES (?, ?, ?)",
            [(word, segments, origin or None) for word, segments, origin in rows],
        )
        connection.executemany(
            "INSERT INTO meta (key, value) VALUES (?, ?)",
            [
                ("schema_version", "1"),
                ("version", VERSION),
                ("morphemes_source", SOURCE),
                ("morphemes_license", LICENSE),
                ("wordparts_source", SOURCE),
                ("wordparts_license", LICENSE),
                ("morpheme_count", str(len(morphemes))),
                ("word_count", str(len(rows))),
            ],
        )
        connection.commit()

        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
        if integrity != "ok":
            raise SystemExit(f"integrity_check 失败：{integrity}")

        known_ids = {row[0] for row in connection.execute("SELECT id FROM parts")}
        for word, segments in connection.execute("SELECT word, segments FROM words"):
            for piece in segments.split():
                label, _, number = piece.partition(":")
                if not label or not number.isdigit():
                    raise SystemExit(f"{word}: segments 编码非法 {piece}")
                if int(number) not in known_ids:
                    raise SystemExit(f"{word}: 引用了不存在的语素 {number}")
    finally:
        connection.close()

    os.replace(temp_path, output)


def main():
    parser = argparse.ArgumentParser(description="生成 wordparts.sqlite")
    parser.add_argument("--morphemes", default="data/morphemes.tsv")
    parser.add_argument("--words", default="data/wordparts.tsv")
    parser.add_argument("--output", default="Sources/Englishwords/Resources/wordparts.sqlite")
    args = parser.parse_args()

    for path in (args.morphemes, args.words):
        if not os.path.exists(path):
            raise SystemExit(f"输入不存在：{path}")

    morphemes = read_tsv(args.morphemes, MORPHEME_HEADER)
    wordparts = read_tsv(args.words, WORDPARTS_HEADER)
    build(morphemes, wordparts, args.output)
    print(f"wordparts.sqlite: {len(morphemes)} 个语素, {len(wordparts)} 个词 -> {args.output}")


if __name__ == "__main__":
    main()
