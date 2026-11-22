#!/usr/bin/env python3
"""从固定版本的词素源文件生成 `wordparts.sqlite`。

输入（均在 data/ 下，随仓库固定版本）：
    morphemes.tsv   key, role, label, forms, zh, en, lemma
    wordparts.tsv   word, segments, origin, source
    simplex.txt     单纯词，每行一个，只参与覆盖校验
    wordlist-extra.txt  目标词表补充，每行一个

片段语法：`拼写` 或 `拼写@语素key`。同一拼写只对应一个语素时可省略 key；
对应多个语素时必须写 key。

用法：
    python3 scripts/build_wordparts.py \
        --morphemes data/morphemes.tsv \
        --words data/wordparts.tsv \
        --output Sources/Englishwords/Resources/wordparts.sqlite

    python3 scripts/build_wordparts.py \
        --coverage-db Sources/Englishwords/Resources/dictionary.sqlite \
        --tags zk,gk,cet4,cet6,ky,ielts,toefl \
        --simplex data/simplex.txt \
        --extra data/wordlist-extra.txt

校验规则（任一失败非零退出，不覆盖已有输出）：
    - role 只能是 prefix / root / suffix
    - 每个 segments 片段都能解析到语素，且拼起来正好等于 word
    - 拼写对应多个语素时必须显式写 key
    - source 只能是 manual / wiktionary / ai
    - word 不重复，且是单个英文小写词
    - 传入覆盖参数时，目标词必须全部落在 wordparts 或 simplex 中
    - 生成后 integrity_check、引用完整性、segments 编码格式
"""
import argparse
import datetime
from collections import Counter
from pathlib import Path
import os
import re
import sqlite3
import sys
import tempfile

SCRIPT_ROOT = Path(__file__).resolve().parent.parent
WORD_PATTERN = re.compile(r"^[a-z][a-z'\-]*$")
PIECE_PATTERN = re.compile(r"^([a-z][a-z'\-]*)(?:@([a-z][a-z0-9_]*))?$")
CJK_RE = re.compile(r"[\u2e80-\u9fff]")
LANGUAGE_CODES = {"en", "la", "grc", "fr", "fro", "de", "it", "es", "nl", "ang", "enm", "gml", "non", "pie"}
ROLES = {"prefix", "root", "suffix"}
SOURCES = ("manual", "wiktionary", "ai")
MORPHEME_HEADER = ["key", "role", "label", "forms", "zh", "en", "lemma"]
WORDPARTS_HEADER = ["word", "segments", "origin", "source"]
MANUAL_BINDINGS_HEADER = ["form", "key"]
DEFAULT_TAGS = ["zk", "gk", "cet4", "cet6", "ky", "ielts", "toefl"]

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


def read_word_list(path):
    if not os.path.exists(path):
        raise SystemExit(f"词表不存在：{path}")
    words = []
    with open(path, encoding="utf-8") as handle:
        for number, line in enumerate(handle, start=1):
            word = line.split("#", 1)[0].strip().lower()
            if not word:
                continue
            if not WORD_PATTERN.match(word):
                raise SystemExit(f"{path}:{number} 非法词形：{word}")
            words.append(word)
    return words


def read_manual_bindings(path):
    bindings = {}
    if path is not None:
        for row in read_tsv(path, MANUAL_BINDINGS_HEADER):
            form = row["form"]
            if form in bindings:
                raise SystemExit(f"{path}: 重复的人工词形绑定 {form}")
            bindings[form] = row["key"]
    return bindings


def index_morphemes(morphemes):
    """返回 (key → id, 拼写 → 语素 key 列表)。id 按 key 排序，从 1 起。"""
    ids = {}
    forms = {}
    for index, morpheme in enumerate(sorted(morphemes, key=lambda item: item["key"]), start=1):
        key = morpheme["key"].strip()
        if not key or not re.fullmatch(r"[a-z][a-z0-9_]*", key):
            raise SystemExit(f"非法语素 key：{key}")
        if key in ids:
            raise SystemExit(f"重复语素 key：{key}")
        if morpheme["role"] not in ROLES:
            raise SystemExit(f"{key}: role 非法 {morpheme['role']}")
        for column in ("label", "zh", "en"):
            if not morpheme[column].strip():
                raise SystemExit(f"{key}: {column} 不能为空")
        label = morpheme["label"].strip()
        form_tokens = morpheme["forms"].split()
        if CJK_RE.search(label):
            raise SystemExit(f"{key}: label 不能包含中文：{label}")
        if "_" in label:
            raise SystemExit(f"{key}: label 不能包含下划线：{label}")
        if label.lower() in LANGUAGE_CODES and label.lower() not in form_tokens:
            raise SystemExit(f"{key}: label 不能是语言代码：{label}")
        ids[key] = index
        for form in form_tokens:
            bucket = forms.setdefault(form, [])
            if key not in bucket:
                bucket.append(key)
    return ids, forms


def resolve_piece(piece, forms, ids, word):
    match = PIECE_PATTERN.match(piece)
    if not match:
        raise SystemExit(f"{word}: 片段无法解析 {piece}")
    spelling, key = match.group(1), match.group(2)
    candidates = forms.get(spelling, [])
    if key:
        if key not in ids:
            raise SystemExit(f"{word}: 未知语素 {key}")
        if key not in candidates:
            raise SystemExit(f"{word}: {spelling} 不属于语素 {key}")
        return spelling, key
    if len(candidates) == 1:
        return spelling, candidates[0]
    if not candidates:
        raise SystemExit(f"{word}: 片段 {spelling} 没有对应语素")
    joined = " / ".join(candidates)
    raise SystemExit(f"{word}: 片段 {spelling} 对应多个语素（{joined}），必须写 key")


def source_counts(wordparts):
    counts = {name: 0 for name in SOURCES}
    for entry in wordparts:
        source = entry["source"].strip()
        if source not in counts:
            raise SystemExit(f"{entry['word']}: source 非法 {source}")
        counts[source] += 1
    return " ".join(f"{name}={counts[name]}" for name in SOURCES)


def target_words(database, tags, extra_path):
    wanted = set(tags)
    found = set()
    connection = sqlite3.connect(Path(database).resolve().as_uri() + "?mode=ro", uri=True)
    try:
        columns = {row[1] for row in connection.execute("PRAGMA table_info(words)")}
        if "word" not in columns or "tag" not in columns:
            raise SystemExit(f"{database} 的 words 表缺少 word 或 tag")
        for word, tag in connection.execute("SELECT word, tag FROM words"):
            if wanted.intersection((tag or "").split()):
                found.add(str(word).strip().lower())
    finally:
        connection.close()
    found.update(read_word_list(extra_path))
    return found


def assert_coverage(wordparts, targets, simplex):
    split_words = {entry["word"].strip().lower() for entry in wordparts}
    simplex_set = set(simplex)
    overlap = sorted(split_words & simplex_set)
    if overlap:
        raise SystemExit(f"词条同时存在于拆分表与单纯词表：{', '.join(overlap[:10])}")
    covered = split_words | simplex_set
    missing = sorted(targets - covered)
    if not missing:
        return
    listing = "\n".join(missing)
    raise SystemExit(f"覆盖不足，缺 {len(missing)} 个词：\n{listing}")


def build(morphemes, wordparts, output, coverage=None, *, manual_bindings=None, version=None):
    ids, forms = index_morphemes(morphemes)
    counts = source_counts(wordparts)
    manual_bindings = manual_bindings or {}
    for form, key in manual_bindings.items():
        if key not in forms.get(form, ()):
            raise SystemExit(f"人工绑定 {form}@{key} 不属于语素表")

    rows = []
    seen = set()
    used_keys = set()
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
        if entry["source"].strip() == "manual":
            pieces = [f"{piece}@{manual_bindings[piece]}" if piece in manual_bindings else piece
                      for piece in pieces]
        resolved = [resolve_piece(piece, forms, ids, word) for piece in pieces]
        for _, resolved_key in resolved:
            used_keys.add(resolved_key)
        joined = "".join(spelling for spelling, _key in resolved)
        if joined != word:
            raise SystemExit(f"{word}: 拆分拼回为 {joined}")
        encoded = " ".join(f"{spelling}:{ids[key]}" for spelling, key in resolved)
        rows.append((word, encoded, entry["origin"].strip()))

    if coverage is not None:
        orphans = sorted(set(ids) - used_keys)
        if orphans:
            raise SystemExit(f"存在未被引用的孤立语素（{len(orphans)} 条）：{', '.join(orphans[:10])}")
        signatures = Counter(
            (m["role"], m["label"].strip(), m["zh"].strip(), m["en"].strip()) for m in morphemes
        )
        duplicates = [sig for sig, n in signatures.items() if n > 1]
        if duplicates:
            raise SystemExit(f"存在重复语素（{len(duplicates)} 组）：{duplicates[:5]}")

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
                (ids[item["key"].strip()], item["role"], item["label"].strip(), item["zh"].strip(),
                 item["en"].strip(), item["lemma"].strip() or None)
                for item in morphemes
            ],
        )
        connection.executemany(
            "INSERT INTO words (word, segments, origin) VALUES (?, ?, ?)",
            [(word, segments, origin or None) for word, segments, origin in rows],
        )
        meta = [
            ("schema_version", "1"),
            ("version", version or datetime.date.today().isoformat()),
            ("morphemes_source", SOURCE),
            ("morphemes_license", LICENSE),
            ("wordparts_source", SOURCE),
            ("wordparts_license", LICENSE),
            ("morpheme_count", str(len(morphemes))),
            ("word_count", str(len(rows))),
            ("source_counts", counts),
        ]
        if coverage is not None:
            meta.extend([
                ("coverage_tags", coverage["tags"]),
                ("coverage_target", str(coverage["target"])),
                ("simplex_count", str(coverage["simplex"])),
            ])
        connection.executemany("INSERT INTO meta (key, value) VALUES (?, ?)", meta)
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
    except BaseException:
        connection.close()
        if os.path.exists(temp_path):
            os.unlink(temp_path)
        raise

    connection.close()
    os.replace(temp_path, output)


def main():
    parser = argparse.ArgumentParser(description="生成 wordparts.sqlite")
    parser.add_argument("--morphemes", default=str(SCRIPT_ROOT / "data/morphemes.tsv"))
    parser.add_argument("--words", default=str(SCRIPT_ROOT / "data/wordparts.tsv"))
    parser.add_argument("--manual-form-bindings", help="保留历史人工拆分的词形与语素关系")
    parser.add_argument("--output", default=str(SCRIPT_ROOT / "Sources/Englishwords/Resources/wordparts.sqlite"))
    parser.add_argument("--coverage-db")
    parser.add_argument("--tags", default=",".join(DEFAULT_TAGS))
    parser.add_argument("--simplex")
    parser.add_argument("--extra")
    parser.add_argument("--version", default=datetime.date.today().isoformat())
    args = parser.parse_args()

    for path in (args.morphemes, args.words):
        if not os.path.exists(path):
            raise SystemExit(f"输入不存在：{path}")

    coverage_flags = [args.coverage_db, args.simplex, args.extra]
    if any(coverage_flags) and not all(coverage_flags):
        raise SystemExit("覆盖校验需要同时提供 --coverage-db、--simplex、--extra")

    morphemes = read_tsv(args.morphemes, MORPHEME_HEADER)
    wordparts = read_tsv(args.words, WORDPARTS_HEADER)
    coverage = None
    if args.coverage_db:
        tags = [tag.strip() for tag in args.tags.split(",") if tag.strip()]
        if not tags:
            raise SystemExit("--tags 为空")
        simplex = list(dict.fromkeys(read_word_list(args.simplex)))
        targets = target_words(args.coverage_db, tags, args.extra)
        assert_coverage(wordparts, targets, simplex)
        coverage = {"tags": " ".join(tags), "target": len(targets), "simplex": len(simplex)}

    bindings_path = args.manual_form_bindings
    if bindings_path is None and Path(args.words).resolve() == (SCRIPT_ROOT / "data/wordparts.tsv").resolve():
        bundled_bindings = SCRIPT_ROOT / "data/manual-form-bindings.tsv"
        if bundled_bindings.is_file():
            bindings_path = bundled_bindings
    build(
        morphemes,
        wordparts,
        args.output,
        coverage,
        manual_bindings=read_manual_bindings(bindings_path),
        version=args.version,
    )
    print(f"wordparts.sqlite: {len(morphemes)} 个语素, {len(wordparts)} 个词 -> {args.output}", file=sys.stdout)


if __name__ == "__main__":
    main()
