#!/usr/bin/env python3
"""Generate a deterministic review checklist once enough new morphology decisions exist."""
import argparse
import random
from pathlib import Path

from build_wordparts import WORDPARTS_HEADER, read_tsv, read_word_list


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--words", required=True, type=Path)
    parser.add_argument("--simplex", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    all_rows = read_tsv(args.words, WORDPARTS_HEADER)
    split = [(row["word"], row["segments"], row["source"], row["origin"])
             for row in all_rows if row["source"] != "manual"]
    simplex = [(word, "单纯词", "单纯词清单", "") for word in set(read_word_list(args.simplex))]
    all_split_words = [row["word"].strip().lower() for row in all_rows]
    if len(set(all_split_words)) + len(simplex) != len(set(all_split_words) | {row[0] for row in simplex}):
        raise SystemExit("发现重复词或同一个词同时有拆分和单纯词判定")
    if len(split) + len(simplex) < 200:
        raise SystemExit("新判定不足 200 条，暂不能生成验收抽样")
    split_count = round(200 * len(split) / (len(split) + len(simplex)))
    randomizer = random.Random(20261115)
    sample = randomizer.sample(sorted(split), split_count) + randomizer.sample(sorted(simplex), 200 - split_count)
    rows = [
        "# 词素抽查清单",
        "",
        f"固定随机种子 20261115。拆分 {split_count} 条，单纯词 {200 - split_count} 条。待人工复核。",
        "",
        "| 词 | 判定内容 | 来源 | 起草词源 | 审核判定 | 参考证据 |",
        "|---|---|---|---|---|---|",
    ]
    for row in sorted(sample):
        cells = " | ".join(value.replace("|", "&#124;") for value in row)
        rows.append(f"| {cells} | | |")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x", encoding="utf-8") as stream:
        stream.write("\n".join(rows) + "\n")


if __name__ == "__main__":
    main()
