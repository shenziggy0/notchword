#!/usr/bin/env python3
"""Extract evidenced English segment candidates from Wiktextract JSONL (or JSONL.gz)."""
import argparse
import gzip
import json
import re
from collections import defaultdict
from pathlib import Path

from build_wordparts import DEFAULT_TAGS, WORD_PATTERN, read_word_list, target_words

TEMPLATES = {"af", "affix", "pre", "prefix", "suf", "suffix", "con", "confix", "com", "compound"}
COMPONENT = re.compile(r"-?[a-z]+(?:['-][a-z]+)*-?")


def template_parts(template):
    args = (template or {}).get("args") or {}
    name = (template or {}).get("name")
    first = 2
    second = args.get("2") or ""
    if name == "ety" and isinstance(second, str) and second.startswith(":"):
        name = second[1:]
        first = 3
    if name not in TEMPLATES or args.get("1") != "en":
        return None
    # Named glosses and sense IDs are not components.
    keys = sorted(int(key) for key in args if key.isdecimal() and int(key) >= first)
    if not keys or keys != list(range(first, keys[-1] + 1)):
        return None
    parts = tuple(str(args[str(key)] or "").strip().lower() for key in keys)
    if len(parts) < 2 or not all(COMPONENT.fullmatch(part) for part in parts):
        return None
    return parts, name


def collect_templates(source, targets=frozenset(), evidence=None):
    records = defaultdict(set)
    open_source = gzip.open if source.suffix == ".gz" else open
    with open_source(source, "rt", encoding="utf-8") as stream:
        for number, line in enumerate(stream, start=1):
            if not line.strip():
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError as error:
                raise ValueError(f"{source}:{number}: {error.msg}") from error
            word = (entry.get("word") or "").strip().lower()
            if entry.get("lang_code") != "en" or not WORD_PATTERN.fullmatch(word):
                continue
            if evidence is not None and word in targets:
                text = (entry.get("etymology_text") or "").strip()
                if text.startswith("Etymology tree\n"):
                    text = text.rsplit("\n", 1)[-1]
                text = " ".join(text.split())
                if text and not text.startswith("See ") and entry.get("word") == word:
                    evidence[word].add(text[:650])
            for template in (entry.get("etymology_templates") or []):
                candidate = template_parts(template)
                if candidate:
                    records[word].add(candidate)
    return records


def spell(word, parts, template):
    surfaces = list(parts)
    if "".join(surfaces) == word:
        return tuple(surfaces)
    # A terminal silent e can be dropped when a vowel-initial suffix is added.
    if template in {"suf", "suffix", "af", "affix"}:
        for index in range(len(surfaces) - 1):
            stem, suffix = surfaces[index:index + 2]
            if len(stem) < 3 or not stem.endswith("e") or suffix[0] not in "aeiou":
                continue
            shortened = surfaces[:index] + [stem[:-1]] + surfaces[index + 1:]
            if "".join(shortened) == word:
                return tuple(shortened)
    return ()


def candidates(word, records, ancestors=frozenset(), depth=0):
    if word in ancestors or depth >= 5:
        return set()
    results = set()
    for raw, template in sorted(records.get(word, ())):
        parts = tuple(part.strip("-") for part in raw)
        spellings = spell(word, parts, template)
        if not spellings:
            continue

        expanded = [()]
        for part, spelling in zip(parts, spellings):
            variants = {(spelling,)}
            if part == spelling:
                nested = candidates(part, records, ancestors | {word}, depth + 1)
                # Preserve alternative etymologies in a bounded, deterministic order.
                variants.update(sorted(nested)[:4])
            expanded = sorted({left + right for left in expanded for right in variants})[:32]
        results.update(expanded)
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--dictionary", default="Sources/Englishwords/Resources/dictionary.sqlite")
    parser.add_argument("--extra", default="data/wordlist-extra.txt")
    parser.add_argument("--targets", type=Path, help="只处理指定测试词表")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--evidence-output", type=Path)
    args = parser.parse_args()
    targets = (set(read_word_list(args.targets)) if args.targets
               else target_words(args.dictionary, DEFAULT_TAGS, args.extra))
    evidence = defaultdict(set) if args.evidence_output else None
    records = collect_templates(args.input, targets, evidence)
    rows = ["word\tsegments"]
    count = 0
    for word in sorted(targets):
        choices = candidates(word, records)
        if choices:
            count += 1
            rows.extend(f"{word}\t{' '.join(parts)}" for parts in sorted(choices))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(rows) + "\n", encoding="utf-8")
    print(f"目标词 {len(targets)}；有候选 {count}；候选行 {len(rows) - 1}")
    if args.evidence_output:
        args.evidence_output.parent.mkdir(parents=True, exist_ok=True)
        with args.evidence_output.open("w", encoding="utf-8") as stream:
            stream.write("word\tetymology\n")
            for word, sources in sorted(evidence.items()):
                for source in sorted(sources)[:2]:
                    stream.write(f"{word}\t{source}\n")
        print(f"有词源原文 {len(evidence)} 词")


if __name__ == "__main__":
    main()
