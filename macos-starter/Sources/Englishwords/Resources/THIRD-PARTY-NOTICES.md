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
| 规模 | 170 个语素、147 个词 |
| 转换 | `scripts/build_wordparts.py` |

说明：

- 只收录拆分可完整拼回原词的条目。没有把握的词不生成拆分，查询时如实缺省。
- 覆盖范围有限（不是全量词根库）；扩充分片只需往两个 TSV 追加行并重跑脚本。
- `segments` 使用词内的实际拼写（如 `believ`），语素词典形态（`believe`）另存于 `parts.label`。
