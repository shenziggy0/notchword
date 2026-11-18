# RFC 0006 九个词素覆盖缺项复核

完整构建覆盖全部 11,444 个目标词。9 个缺项中，3 词有可说明的历史拆分，6 词以单纯词收录。单纯词判定同时核对常用义、公开研究的正面标注及辞书中的竞争词源。词源存疑的部分按原有不确定性记录。

| 词 | 判定与依据 |
|---|---|
| dingy | `ding + y`。暗淡、肮脏义与古英语 `dynge` 的关联仍为推测，Oxford 记录此说，SIGMORPHON 的标注亦保留该词基和形容词后缀。俚语义可另从 `ding` 分析。暂存释文保留「可能」。[Oxford](https://www.oxfordlearnersdictionaries.com/us/definition/english/dingy)，[American Heritage](https://ahdictionary.com/word/search.html?q=dingy) |
| donkey | 单纯词。MorphoLex 的名词标为一个词素。Oxford 给出毛色词 `dun`、人名 Duncan 两说，均不足以建立现代词形中的同义词基和后缀。[Oxford](https://www.oxfordlearnersdictionaries.com/us/definition/english/donkey) |
| frowzy | 单纯词。MorphoLex 的形容词和 SIGMORPHON 中派生词的词基一致。Collins 将 `frowsty` 视为变体，`frowst` 则由该变体逆构。[Collins frowzy](https://www.collinsdictionary.com/dictionary/english/frowzy)，[Collins frowst](https://www.collinsdictionary.com/dictionary/english/frowst) |
| luncheon | 单纯词。两套数据把「午餐、午宴」义的形式标作词基。历史上 `lunch`、`nuncheon` 与类比 `truncheon` 的关系有多说，尤其不能把历史上「厚片」义与现代午餐义的派生方向合并。[Oxford](https://www.oxfordlearnersdictionaries.com/definition/english/luncheon)，[Anatoly Liberman](https://blog.oup.com/2024/10/out-for-lunch/) |
| monkey | 单纯词。两套数据都标为单一词基。历史上可能整词借入；与 `monk`（修士）和英语指小后缀的分析缺少语料支撑。[American Heritage](https://ahdictionary.com/word/search.html?id=M5420600)，[Anatoly Liberman](https://blog.oup.com/2013/01/monkey-word-origin-etymology/) |
| nasty | `nast + y`。《中古英语辞典》明确认定 `nastī` 的 `-ī` 是形容词后缀，并以北日耳曼语为线索。历史丹麦语辞书也将「肮脏」义的 `nasket` 与该形容词比较。现代分词数据库按派生词基处理，本项目保留有辞书确证的历史后缀。[Middle English Dictionary](https://quod.lib.umich.edu/m/middle-english-dictionary/dictionary/MED29107)，[Ordbog over det danske Sprog](https://www.ordnet.dk/ods/ordbog/nasket) |
| shrivel | 单纯词。MorphoLex 与 SIGMORPHON 都标为一个词基。Oxford 比较瑞典方言 `skryvla`，仍只确认到可能有关的整体借源。[Oxford](https://www.oxfordlearnersdictionaries.com/us/definition/english/shrivel) |
| squander | 单纯词。MorphoLex 标为一个动词词素，SIGMORPHON 的 `squandering`、`squanders`、`squandered` 一致以整个 `squander` 为词基。混成说缺少旧词形或语料支持。[Oxford](https://www.oxfordlearnersdictionaries.com/us/definition/english/squander) |
| struggle | `strugg + le`。Oxford 明确作反复动作构词，中古英语有 `struglen` 和其他写法，早期词基仍存疑。保留可辨认的后缀与历史词基，释文不指定词基更早来源。[Oxford](https://www.oxfordlearnersdictionaries.com/us/definition/english/struggle_2)，[University of Texas Linguistics Research Center](https://lrc.la.utexas.edu/lex/master/1894) |

MorphoLex 仅用于逐词核对判断。工作簿 SHA-256 为 `5bc425fbb710f3d63cab69e77ee731fa466653ed0ace94937cac6c1fd6de52c6`。SIGMORPHON 词级训练和验证标注固定为 `6613f9475c5b541cfa51053d55790c92d650144e`。发布候选没有收录第三方工作簿、训练集或其派生导出。[MorphoLex 原论文](https://doi.org/10.3758/s13428-017-0981-8)，[SIGMORPHON 原论文](https://aclanthology.org/2022.sigmorphon-1.11/)
