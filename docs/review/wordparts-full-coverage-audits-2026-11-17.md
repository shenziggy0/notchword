# 全覆盖后的词素质量复查

各轮均使用 RFC 0006 的固定种子 20261115，按该轮拆分和单纯词的实际比例抽取 200 条。词条基数和词表中的排列位置随修正变化。保留修正前的结论作为记录。此处按主控确认的词素问题统计，Pi 提出的基础词典释义问题不计入词素统计。

| 版本 | 已确认问题 | 需核对 |
|---|---|---|
| 全覆盖后的首轮 | 19 条。`disaster`、`distil`、`emphasis`、`energy`、`equilibrium`、`factual`、`impudent`、`inspector`、`instrumental`、`magnetism`、`mechanism`、`monstrous`、`musician`、`organism`、`parcel`、`scissors`、`slovenly`、`spherical`、`strenuous` | 8 条。`arraign`、`array`、`captain`、`entire`、`halve`、`languish`、`tract`、`vomit` |
| 同形前后缀修订后 | 16 条。`antagonism`、`complain`、`counterpart`、`define`、`endeavor`、`generalization`、`injustice`、`insistent`、`institutions`、`panel`、`soften`、`spectrum`、`subsequent`、`typist`、`upright`、`whichever` | 5 条。`apparel`、`apprentice`、`burglar`、`cover`、`hustle` |
| 构词角色修订后 | 14 条。`factious`、`finish`、`foliage`、`general`、`injury`、`insistence`、`propensity`、`reinforce`、`scholarly`、`silicate`、`specification`、`spoonful`、`visit`、`vocabulary` | 4 条。`impeach`、`meddle`、`square`、`suffrage` |
| 度量词和后缀修订前 | 13 条。`forbidding`、`humanitarian`、`injurious`、`millimetre`、`munificent`、`pendulum`、`premium`、`reimburse`、`reticent`、`scholar`、`sleepy`、`specifically`、`yearly` | 2 条。`pantry`、`passenger` |
| 历史借词和派生复核前 | 11 条。`array`、`burglar`、`calendar`、`passenger`、`profitable`、`propellant`、`reticence`、`specific`、`tunnel`、`twelve`、`upkeep` | 4 条。`apparel`、`apprentice`、`cover`、`pantry` |
| 同形词及屈折词尾复核前 | 14 条。`burnish`、`chairman`、`deputy`、`insignificant`、`instinctively`、`jewelry`、`melody`、`phobia`、`plumage`、`pupil`、`recount`、`spoken`、`theorem`、`travesty` | 3 条。`ennui`、`sturdy`、`wollongong` |
| 最终落盘版（`post-bases-review` 终审） | 0 条确认错误（`pi-cli` 3 分片复核 200 条全部处理，0 ERROR，22 条轻度义项/词源补充注记已复核并修正 `prodigal`、`corroborate`、`impassive` 3 处显示义） | 无；已正式同步至 `macos-starter/data/` 与 `wordparts.sqlite`，报告见[最终 200 条抽查清单](wordparts-sample-200.md) |

已把可确认的错例和同类绑定修正到暂存库。完整覆盖持续通过。Pi 独立复核提供了候选问题，我依据原词、词源和应用实际显示的语素释义逐条裁决。例如 Pi 报告 `periodically` 缺字，旧记录的 `ical` 实际含四个字母。调整为两段属于改善词缀层次。默认 Agy 服务返回当前位置不支持 API，未产出本轮复核结果。
