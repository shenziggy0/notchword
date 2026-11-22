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
  --coverage-db Sources/Englishwords/Resources/dictionary.sqlite \
  --simplex data/simplex.txt \
  --extra data/wordlist-extra.txt \
  --output Sources/Englishwords/Resources/wordparts.sqlite
```

`--coverage-db`、`--simplex`、`--extra` 缺一不可：没有它们脚本不会校验 11,444 目标词的覆盖，也不会写入 `coverage_target` / `simplex_count`。

## 3. 校验点

`build_dictionary.py`

- 只保留有中文释义的单词语条（`frq` 1—60000 或带考试标签）
- 词头小写去重，重复时优先带标签、词频靠前的条目
- `PRAGMA integrity_check` 必须为 `ok`
- `forms.lemma` 必须全部能回到 `words`
- 词条数低于 10000 视为输入异常

`build_wordparts.py`

- `role` 只能是 prefix / root / suffix
- 同一拼写可对应多个语素（通过 `拼写@语素key` 消歧，无歧义且符合 `manual-form-bindings.tsv` 的原有 147 条人工条目保持兼容）
- `segments` 每个片段都能解析，且拼起来正好等于 `word`
- 生成后逐条检查 `segments` 编码与语素引用
- `meta` 表写入版本、来源、许可与条目数

## 4. 覆盖率的真实情况

`wordparts.sqlite` 当前已实现七类考试标签与小学补充目标词（合计 **11,444** 词）**100% 覆盖**，无未判定缺口：
- 语素库共 **4,550** 个语素；
- 拆分词库共 **7,757** 词（其中 `manual=147`、`wiktionary=1,832`、`ai=5,778`）；
- 单纯词清单 `simplex.txt` 共 **3,698** 词（单纯词不写入空拆分 SQLite 行，界面只展示释义而不杜撰拆分）。

语素与拆分在入库前统一清洗：`parts.label` 必须是词典形态（`-able` 而非中文注释、纯语言码或下划线 key），
同形同义语素合并成一条 key 并保留显式绑定；无法拼回原词或只出现一次的孤立语素不保留。
入库后由 `build_wordparts.py` 重算 `source_counts` 与 `coverage_target`，不使用缓存数字。

## 5. M5.5 数据生产

考纲目标词为随包词库中七类考试标签的并集。小学补充采用 Wiktionary
[基础英语词表固定修订](https://en.wiktionary.org/wiki/Special:PermanentLink/78256317)（贡献者按 CC BY-SA 4.0 授权）。
从该页抽出 996 个符合词库格式的去重单词，与考试目标词相减后得到 4 个新增词。
2026-11-15 获取的 HTML SHA-256 为 `6b9888bd6efe1bca0efd7f076a8757fe332bbe60f53473533b7e0b518875d1d8`。
新增词仅作为目标进入 `wordlist-extra.txt`，覆盖以实际词素判定为准。
重建 ECDICT 时会把来源里重复的误拼 `reservior` 的 CET-4 标签合入 `reservoir`，
并保留误拼作为查词别名。覆盖按纠正后的词头统计。

词源输入使用 [Kaikki 的 Wiktextract JSONL](https://kaikki.org/dictionary/rawdata.html)。
试验使用 2026-10-01 的英文 Wiktionary 转储所衍生的 5 个词条 JSONL，
按 `unbelievable, believable, playable, washable, readable` 顺序拼接所得 SHA-256 为
`7ec44f2243986fe865817965b3fda38ee8c9e2bc25dfbd40344436010473fc69`。
抽取已从该样本得到 `un believ able`、`play able` 和 `wash able` 等候选。
全量输入为 2026-11-16 取得的 [Kaikki 英语词条快照](https://kaikki.org/dictionary/English/index.html)，
源自 2026-10-01 英文 Wiktionary 转储，2026-10-30 抽取及后处理。
gzip 文件共 534,186,395 字节，完整性校验通过，SHA-256 为
`4d03b6cba283744756c57ff661c2c6cbfe34fcf8ff513a966576cf7d97e91a99`。

在 `macos-starter/` 下执行：

```bash
python3 scripts/extract_wiktionary.py \
  --input scripts/.cache/enwiktionary-english-20261001.jsonl.gz \
  --output scripts/.cache/wiktionary_candidates.tsv \
  --evidence-output scripts/.cache/wiktionary_etymologies.tsv

python3 scripts/draft_morphology.py \
  --candidates scripts/.cache/wiktionary_candidates.tsv \
  --evidence scripts/.cache/wiktionary_etymologies.tsv \
  --run-dir scripts/.cache/morphology-run \
  --budget-usd 10 --previous-spend-usd 0.021174 \
  --budget-ledger scripts/.cache/morphology-budget-20261116.json
```

起草脚本通过本机 Pi CLI 调用 deepseek-flash，使用 high 思考强度。单批试跑可加 `--max-batches 1`。
同一批工作跨暂存目录时共用费用账本，续跑保留相同的前序费用。脚本按峰值费率核算 Pi 会话用量，
每次调用或重试前预留该模型单次调用上限。余额不足或上一笔用量无法核实时停止发起新请求。
取消支出上限时，可在已结束当前批次后将 `--budget-usd` 替换为 `--no-budget-limit`，
保持原账本、前序费用和运行目录。
脚本将有效批次保存在运行目录内，同一输入和配置可以续跑，待人工确认的词会写入
`draft_failures.tsv`。小批试跑和未覆盖完成均保留暂存数据；覆盖完整才在运行目录生成数据库。
处理同形语素造成的缺项时，可用上一轮暂存的三个词表作为输入，并加
`--manual-form-bindings data/manual-form-bindings.tsv`。绑定表从原 147 条人工拆分中生成，
保留其未标 key 的词形所指语素。新拆分用显式 key 消歧，原 TSV 行无需改写。
使用默认 `data/wordparts.tsv` 构建时会自动读取绑定表，使用暂存词表可显式传入同一参数。

```bash
python3 scripts/sample_wordparts.py \
  --words scripts/.cache/morphology-run/wordparts.tsv \
  --simplex scripts/.cache/morphology-run/simplex.txt \
  --output ../docs/review/wordparts-sample-200.md
```

抽查合格后，成套更新通过验收的 TSV、单纯词清单及数据库，
并补充全量快照、模型版本、批次大小、失败统计和署名。
