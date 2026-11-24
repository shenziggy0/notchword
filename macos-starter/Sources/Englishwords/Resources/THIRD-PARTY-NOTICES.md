# 第三方数据与许可

随包的两个 SQLite 文件由公开数据构建，转换脚本在 `scripts/`，输入版本记录在 `data/SOURCES.md`。

## 1. dictionary.sqlite — ECDICT

| 项 | 值 |
|---|---|
| 项目 | ECDICT — 中文开源英文词典库 |
| 来源 | <https://github.com/skywind3000/ECDICT> |
| 输入文件 | `ecdict.csv` |
| 输入 SHA-256 | `d1ecbdf9ee2b920afb6f430ca6b6bb9f559588cf0dff86e04bd255f9390843cc` |
| 获取日期 | 2026-11-03 |
| 许可 | MIT（仓库声明） |
| 用途 | 词头、音标、中文释义、词性、考试标签、词频、屈折形式 |
| 转换 | `scripts/build_dictionary.py`，仅保留单词语条，约 4.3 万条 |

```
MIT License

Copyright (c) skywind3000 and ECDICT contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## 2. wordparts.sqlite — 词根词缀整理数据

| 项 | 值 |
|---|---|
| 来源 | 本项目整理，词源依据维基词典（Wiktionary）各词条 Etymology 段 |
| 输入文件 | `data/morphemes.tsv`、`data/wordparts.tsv` |
| 许可 | CC BY-SA 4.0 |
| 规模 | 4,550 个语素、7,757 个拆分词（另含 3,698 个单纯词，覆盖 11,444 个目标词） |
| 转换 | `scripts/build_wordparts.py` |

说明：

- 只收录拆分可完整拼回原词的条目。没有把握的词不生成拆分，查询时如实缺省。
- 覆盖七类考试标签与小学补充目标词（合计 11,444 词）：拆分词 7,757 条、单纯词 3,698 条，无未判定缺口。
- 不是全量词根库；扩充分片只需往两个 TSV 追加行并重跑脚本。
- `segments` 使用词内的实际拼写（如 `believ`），语素词典形态（`believe`）另存于 `parts.label`。
- 词源归属 Wiktionary 各词条贡献者，参见对应词条历史及 [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/)。
- 小学补充目标来自 [Wiktionary 基础英语词表固定修订](https://en.wiktionary.org/wiki/Special:PermanentLink/78256317)。

## 3. Sparkle

带更新功能的构建包含 [Sparkle 2.9.6](https://github.com/sparkle-project/Sparkle/releases/tag/2.9.6)。
原始第三方许可随 Sparkle 构建产物放在应用资源目录中。

## 4. Lucide

界面图标取自 [lucide-static 0.468.0](https://www.npmjs.com/package/lucide-static/v/0.468.0) 的官方字体，应用仅内嵌所用字形。

ISC License

Copyright (c) for portions of Lucide are held by Cole Bemis 2013-2022 as part of Feather (MIT). All other copyright (c) for Lucide are held by Lucide Contributors 2022.

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
