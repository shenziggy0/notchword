# 数据源与重建步骤

随包的两个 SQLite 全部可从固定版本的公开输入重建。生成脚本失败时非零退出，且不覆盖已有文件。

## 1. 输入版本

| 文件 | 来源 | 版本 / 校验 |
|---|---|---|
| `ecdict.csv` | <https://github.com/skywind3000/ECDICT> | 2026-11-03 获取，SHA-256 `d1ecbdf9ee2b920afb6f430ca6b6bb9f559588cf0dff86e04bd255f9390843cc` |
| `morphemes.tsv` | 本项目整理 | 见文件本身；许可 CC BY-SA 4.0 |
| `wordparts.tsv` | 本项目整理 | 见文件本身；许可 CC BY-SA 4.0 |

`ecdict.csv` 体积约 63 MB，不进入仓库，放在 `scripts/.cache/`（已 gitignore）。

## 2. 重建

```bash
cd macos-starter

# 主词库（ECDICT，MIT）
curl -L -o scripts/.cache/ecdict.csv \
  https://raw.githubusercontent.com/skywind3000/ECDICT/master/ecdict.csv
python3 scripts/build_dictionary.py \
  --input scripts/.cache/ecdict.csv \
  --output Sources/Englishwords/Resources/dictionary.sqlite

# 词根词缀
python3 scripts/build_wordparts.py \
  --morphemes data/morphemes.tsv \
  --words data/wordparts.tsv \
  --output Sources/Englishwords/Resources/wordparts.sqlite
```

## 3. 校验点

`build_dictionary.py`

- 只保留有中文释义的单词语条（`frq` 1—60000 或带考试标签）
- 词头小写去重，重复时优先带标签、词频靠前的条目
- `PRAGMA integrity_check` 必须为 `ok`
- `forms.lemma` 必须全部能回到 `words`
- 词条数低于 10000 视为输入异常

`build_wordparts.py`

- `role` 只能是 prefix / root / suffix
- 语素形态不得重复映射
- `segments` 每个片段都能解析，且拼起来正好等于 `word`
- 生成后逐条检查 `segments` 编码与语素引用
- `meta` 表写入版本、来源、许可与条目数

## 4. 覆盖率的真实情况

`wordparts.sqlite` 是**有限覆盖**：147 个词有拆分，约 4.3 万词条没有。界面在缺词素数据时只显示释义与词源缺省，不猜测、不杜撰拆分。
