# 词素抽查清单

固定随机种子 20261115。拆分 135 条，单纯词 65 条（共 200 条）。

- **终审结论（2026-11-17）**：已通过本机 `pi-cli`（`deepseek-flash`、`--thinking high --access read`）3 分片并行复核与主控逐条词源裁决。200 条样本 **确认 ERROR 0 条**（远低于 RFC 0006 规定的 `< 10` 条门槛）；其中 22 条 `REVIEW` 均为冻结词源数组缺失主链、合理表层构词层次或显示义轻微偏移，无词素归属错误，并已将 `prodigal`、`corroborate`、`impassive` 等 3 处显示义同步修正落盘。
- **二次核验（2026-11-22）**：基于清洗后的 `macos-starter/data/{morphemes.tsv,wordparts.tsv,simplex.txt}` 重新核对这 200 条样本，中文/语言码/下划线类脏 `label` 已清零；第 2 列判定内容与当前源数据逐字一致（拆分片段 key 在去重合并后无变动），第 5 列审核判定与第 6 列参考证据已全部补齐。

| 词 | 判定内容 | 来源 | 起草词源 | 审核判定 | 参考证据 |
|---|---|---|---|---|---|
| abduct | ab@ab duct@duct | ai | ab-（离开）+ duct（引导）→ 带走；诱拐 | PASS | ab-（离开） + duct（引导；拉） |
| accident | ac@ad cid@cad ent@ent | ai | ac-（朝向）+ cid（落；发生）+ -ent（名词/形容词后缀）→ 意外；事故 | PASS | ad-（朝向） + cad（落；发生） + -ent（形容词/名词后缀：处于……状态的） |
| advanced | advanc@advance ed@ed | wiktionary | advance（去 e）+ -ed | PASS | advance（前进；推进） + -ed（形容词后缀：已……的） |
| affect | af@af fect@fact | ai | af-（ad- 同化）+ 拉丁 facere（做） | PASS | af-（朝向（ad- 的同化形式）） + fact（做；制造） |
| alliteration | al@p01_al_toward liter@liter ation@ion | ai | 拉丁 ad-（朝向，al-）+ litera（字母）+ -ation（行为） | PASS | al- (ad-)（朝向（ad- 在 l 前的同化形式）） + liter（文字） + -ion（名词后缀：行为或结果） |
| anchor | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| anesthesia | an@an esthesia@esthesia | ai | an-（无）+ -esthesia（感觉）：麻醉；感觉缺失。 | PASS | an-（无；不） + -esthesia（感觉） |
| anomaly | an@an omal@omal y@y | ai | an-（不）+ omal（平坦、均匀）+ -y（名词后缀） | PASS | an-（无；不） + omal（平坦；均匀） + -y（名词后缀：状态或结果） |
| april | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| apt | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| artillery | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| as | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| avocational | a@audit21_ab_from voc@audit22_voc ation@ion al@al | ai | 英语 avocation 加 -al，基础词上溯拉丁 āvocātiō，词根 vocāre 意为呼唤。 | PASS | ab-（离开；转离） + vocāre（叫；召唤） + -ion（名词后缀：行为或结果） + -al（形容词或名词后缀） |
| because | be@by cause@cause | ai | by（由；因为）+ cause（原因） | PASS | by（由；因为） + cause（原因；事由） |
| bed | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| bibliography | biblio@biblio graph@graph y@y | ai | biblio（书）+ graph（写）+ -y（名词后缀） | PASS | biblio（书） + graph（写；画） + -y（名词后缀：状态或结果） |
| bicycle | bi@bi cycle@cycle | ai | bi（二）+ cycle（轮） | PASS | bi-（二） + cycle（轮；循环） |
| biographer | bio@bio graph@graph er@er | ai | bio（生命）+ graph（写）+ -er（人） | PASS | bio（生命） + graph（写；画） + -er（人；物） |
| border | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| bubble | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| butt | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| bypass | by@by_secondary pass@pass | wiktionary | 英语前缀 by-（从旁）加 pass（经过）。 | PASS | by-（次要；副；旁） + pass（通过；经过） |
| callous | call@call_skin ous@ous | ai | 拉丁语 callum（硬皮）+-ous | PASS | hard skin（硬皮） + -ous（形容词后缀：充满……的） |
| canadian | canad@p03_canada ian@audit18_ian | ai | Canada（加拿大）加 -ian，指加拿大人或与加拿大有关的；词干省去末尾 a。 | PASS | canada（加拿大） + -ian（属于某地的；某地的人） |
| carnival | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| carrot | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| carry | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| censor | cens@cens or@er | ai | cens 审查 + -or 人 | PASS | cens（评估；审查） + -er（人；物） |
| ceramic | ceram@ceram ic@ic | ai | ceram 陶土 + -ic 形容词后缀 | PASS | ceram（陶土；陶瓷） + -ic（形容词后缀） |
| chest | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| citadel | citad@audit18_citad el@audit4_el_diminutive | ai | 经法语 citadelle 借自意大利语 cittadella，为 città（城市）的指小形式，指城堡或城市要塞。 | PASS | città（城市） + -el（历史指小词尾） |
| city | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| cloud | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| coalescence | co@co alesc@alesc ence@ance | ai | co（共同）+ alesc（生长）+ -ence（名词后缀） | PASS | co-（共同） + alesc（生长） + -ance（名词后缀：状态） |
| compassion | com@co passion@passion | ai | com-（共同）+ passion（受苦） | PASS | co-（共同） + passion（受苦；激情） |
| compatriot | com@co patriot@patriot | ai | com-（共同）+ patriot（同胞） | PASS | co-（共同） + patriot（同胞；爱国者） |
| complicity | com@co plic@plic ity@ity | ai | com- + plicare（折叠）+ -ity | PASS | co-（共同） + plic（折叠） + -ity（名词后缀：性质） |
| component | com@co pon@pos ent@ent | ai | com- + ponere（放置）+ -ent | PASS | co-（共同） + pos（放置） + -ent（形容词/名词后缀：处于……状态的） |
| concerted | concert@concert ed@ed | ai | concert（协调）+ -ed | PASS | concert（音乐会；协调） + -ed（形容词后缀：已……的） |
| conditioning | condition@condition ing@ing | ai | condition（状况；条件）+ -ing | PASS | condition（状况；条件） + -ing（分词/名词后缀：进行；行为） |
| conflict | con@co flict@flict | ai | con- + flict（打击） | PASS | co-（共同） + flict（打击） |
| contemn | con@preaudit_con_complete temn@temn | ai | 拉丁 contemnere 以加强前缀 con- 加 temnere（轻视），经法语进入英语。 | PASS | con-（完全；加强） + temn（轻视） |
| continent | con@co tin@tain ent@ent | ai | 拉丁 continens，con- 共同 + tenere 握持 + -ent | PASS | co-（共同） + tain（握；持） + -ent（形容词/名词后缀：处于……状态的） |
| corroborate | cor@preaudit_con_complete robor@robor ate@ate | ai | 拉丁 corroborare，con- 加强 + robur/robor- 力量 + -ate | PASS | con-（完全；加强） + robor（力量；坚固） + -ate（使……；具有……的） |
| crease | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| creature | creat@creat ure@ure | ai | creat（创造）+ -ure（名词后缀：结果） | PASS | creat（创造；产生） + -ure（名词后缀：结果） |
| cross | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| curse | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| deduct | de@de duct@duct | ai | de-（向下；离开）+ duct（引导）→ 扣除；减去。 | PASS | de-（向下；去除） + duct（引导；拉） |
| dieter | diet@diet er@er | ai | diet + -er | PASS | diet（饮食） + -er（人；物） |
| dioxide | di@p06_di_two ox@ox_oxygen ide@ide | ai | di-（二）+ ox（氧）+ -ide（化合物）→ 二氧化物。 | PASS | di-（二） + ox（氧；酸） + ide（化学后缀：……化物） |
| disc | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| disregard | dis@dis regard@regard | wiktionary | dis-（否定）+ regard（注视/尊重） | PASS | dis-（否定；分开） + regard（注视；尊重） |
| dock | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| dominant | domin@domin ant@ant | ai | Latin dominus（主人）+ -ant（形容词后缀） | PASS | domin（主人；统治） + -ant（人；形容词后缀） |
| eke | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| empower | em@en power@power | ai | em-（使）+ power（力量）：授权 | PASS | en-（使……） + power（力量；能力） |
| encumber | en@en cumber@cumber | ai | en-（使）+ cumber（阻碍）：妨碍 | PASS | en-（使……） + cumber（阻碍；负担） |
| entertain | enter@p07_entre tain@tain | ai | enter-（在……之间）+ tain（握；持） | PASS | entre-（在……之间；着手） + tain（握；持） |
| entrap | en@en trap@trap | wiktionary | en-（使进入）+ trap（陷阱）：诱捕 | PASS | en-（使……） + trap（陷阱；捕捉） |
| evaluation | e@ex valu@p07_valu ation@ion | ai | e-（出）+ valu（价值）+ -ation（名词后缀） | PASS | ex-（出；向外） + valu（价值） + -ion（名词后缀：行为或结果） |
| evolutionary | e@ex volut@volv ion@ion ary@ary | ai | e- + volut + -ion + -ary：进化的 | PASS | ex-（出；向外） + volv（滚；转） + -ion（名词后缀：行为或结果） + -ary（与……有关的） |
| examine | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| exception | ex@ex cept@cept ion@ion | ai | ex- + cept + -ion：例外 | PASS | ex-（出；向外） + cept（拿；取） + -ion（名词后缀：行为或结果） |
| explicit | ex@ex plic@plic it@p07_it_pp | ai | ex-（出）+ plic（折叠）+ -it（已……的） | PASS | ex-（出；向外） + plic（折叠） + -it（形容词后缀：已……的） |
| exploration | ex@ex plor@plor ation@ion | ai | 上溯拉丁 explōrāre（探查）。第二成分常解释为 plōrāre（呼喊），亦有学者提出与意为流动的 pluere 有关。 | PASS | ex-（出；向外） + plor（哭喊；哀悼） + -ion（名词后缀：行为或结果） |
| extinguish | ex@ex tinguish@pr2_03_tinguish | ai | 拉丁 extinguere，ex-（出）加 stinguere（熄灭，s 在 ex- 后脱落），英语作 extinguish | PASS | ex-（出；向外） + tinguish（熄灭；扑灭） |
| fagot | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| fanaticism | fan@fan_temple atic@atic ism@ism | ai | fanatic + -ism；fan + -atic + -ism | PASS | fan（神庙） + atic（形容词后缀：与……有关的） + -ism（主义；学说） |
| fearful | fear@fear ful@ful | wiktionary | fear + -ful | PASS | fear（恐惧；危险） + -ful（充满……的） |
| feat | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| fingers | finger@finger s@s | ai | finger（手指）+ -s（复数） | PASS | finger（手指） + -s（复数后缀） |
| fixed | fix@fix ed@ed | ai | fix（固定）+ -ed（形容词后缀） | PASS | fix（固定） + -ed（形容词后缀：已……的） |
| flavoring | flavor@flavor ing@ing | ai | flavor（味道）+ -ing | PASS | flavor（味道） + -ing（分词/名词后缀：进行；行为） |
| float | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| fluctuation | fluctuat@fluctu ion@ion | wiktionary | fluctuate + -ion；拉丁 fluctuātiō，fluctuō 波动 | PASS | fluctu（波动；波浪） + -ion（名词后缀：行为或结果） |
| forms | form@form s@s | ai | form + -s；形式/形成（复数或三单） | PASS | form（形状） + -s（复数后缀） |
| freighter | freight@freight er@er | ai | 来自 freight + -er | PASS | freight（货物；运费） + -er（人；物） |
| frighten | fright@fright en@en_suffix | wiktionary | 来自 fright + -en | PASS | fright（恐惧） + -en（动词后缀：使……） |
| functional | funct@funct ion@ion al@al | ai | 来自 function + -al，拆作 funct + -ion + -al | PASS | funct（履行；功能） + -ion（名词后缀：行为或结果） + -al（形容词或名词后缀） |
| gamble | gamb@pr3_01_game le@le | ai | 与 game 同源，古英语 gamenian；game + -le（反复后缀），拼写插入 b，早期作 gamel。 | PASS | game（游戏；玩耍） + le（动词后缀：反复或指小） |
| glandular | glandul@glandul ar@al | wiktionary | 拉丁语 glandula（小腺体，词干 glandul-）+ -ar/-al（形容词后缀） | PASS | glandul（腺） + -al（形容词或名词后缀） |
| grate | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| heave | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| hometown | home@home town@town | wiktionary | home + town | PASS | home（家） + town（城镇） |
| hurricane | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| impassive | im@review_lexical_neg passive@passive | wiktionary | im-（不）+ passive（易感的）：冷漠的；无动于衷的 | PASS | in-（不；非） + passive（被动的；易感的） |
| inference | infer@infer ence@ance | wiktionary | infer 推论 + -ence 名词后缀；推论 | PASS | infer（带入；推论） + -ance（名词后缀：状态） |
| inherit | in@review_in_into herit@herit | ai | in- 入 + herit 继承；继承 | PASS | in-（进入；朝内） + herit（继承；遗产） |
| inquiries | in@review_in_into quir@quir ies@ies | ai | in- 入 + quir 寻求 + -ies 复数；询问 | PASS | in-（进入；朝内） + quir（寻求） + -ies（复数后缀（-y 变 -ies）） |
| insulate | insul@insul ate@ate | ai | insul 岛 + -ate；使隔离 | PASS | insul（岛） + -ate（使……；具有……的） |
| intellectual | intellect@intellect ual@ual | ai | intellect + -ual；拉丁 intellectualis | PASS | intellect（智力；理解） + adjective（形容词后缀） |
| intrigue | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| irrelevant | ir@review_lexical_neg relevant@relevant | wiktionary | ir-（不）+ relevant（相关的） | PASS | in-（不；非） + relevant（相关的；涉及） |
| jaw | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| ken | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| kid | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| large | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| leisurely | leisure@leisure ly@ly_adj | ai | leisure + -ly | PASS | leisure（闲暇；空闲） + adjectival -ly（形容词后缀：具有……性质的） |
| let | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| lever | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| liver | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| loans | loan@loan s@s | ai | loan（贷款；借出）+-s（复数后缀） | PASS | loan（贷款；借出） + -s（复数后缀） |
| malaria | mal@mal aria@aria | ai | mal-（坏）+ aria（空气），意大利语“坏空气” | PASS | mal-（坏） + aria（空气） |
| manifestation | manifest@manifest ation@ion | ai | manifest（显现）+ -ation（名词后缀：行为或结果） | PASS | manifest（明显的；显现） + -ion（名词后缀：行为或结果） |
| merger | merg@merge er@er | ai | merge（合并）+ -er（人/物）：合并者；合并 | PASS | merge（合并；沉入） + -er（人；物） |
| minutes | minute@minute s@s | ai | minute + -s | PASS | minute（分钟；微小） + -s（复数后缀） |
| misfortune | mis@mis fortune@fortune | wiktionary | mis- + fortune | PASS | mis-（错误） + fortune（运气；命运） |
| mm | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| moderate | moder@moder ate@ate | ai | moder（节制；适度）+ -ate（使……；具有……的） | PASS | moder（节制；适度） + -ate（使……；具有……的） |
| momentary | moment@moment ary@ary | ai | moment（时刻）+ -ary（……的） | PASS | moment（时刻；瞬间） + -ary（与……有关的） |
| monochrome | mono@mono chrome@chrome | wiktionary | mono-（单一）+ chrome（颜色） | PASS | mono-（单一） + chrome（颜色） |
| morning | morn@morn ing@ing | ai | morn（早晨）+ -ing（名词后缀） | PASS | morn（早晨） + -ing（分词/名词后缀：进行；行为） |
| naval | nav@nav al@al | ai | nav（船）+ -al（形容词后缀） | PASS | nav（船） + -al（形容词或名词后缀） |
| nut | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| obligatory | ob@ob lig@lig_bind atory@atory | ai | ob- 朝向 + ligare 绑 + -atory 形容词后缀：强制的 | PASS | ob-（阻碍；对着） + lig（绑；约束） + atory（形容词后缀：与……有关的） |
| offshore | off@off shore@shore | wiktionary | off 离开 + shore 岸：近海的 | PASS | off（离开；向外） + shore（岸） |
| overflow | over@over flow@flow | wiktionary | over（超过）+ flow（流） | PASS | over-（过度） + flow（流；流动） |
| pardon | par@p12_par_per don@don | ai | per-（完全，经法语作 par-）+ don（给予），表示原谅、赦免。 | PASS | per- (French par-)（完全；通过（per- 的法语变体）） + don（给予） |
| particle | part@part icle@icle | ai | 部分+指小后缀 | PASS | part（部分；分开） + -icle（指小后缀） |
| pass | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| patriotism | patriot@patriot ism@audit4_ism | wiktionary | 爱国者+主义 | PASS | patriot（同胞；爱国者） + -ism（性质；状态；现象） |
| patroller | patroll@patrol er@er | ai | 巡逻+人 | PASS | patrol（巡逻） + -er（人；物） |
| perks | perk@p12_perk s@s | ai | perk（额外待遇；使振作）+ 复数/第三人称单数 -s，表示特权、额外津贴。 | PASS | perk（额外待遇；使振作） + -s（复数后缀） |
| pester | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| pickup | pick@pick up@up | wiktionary | pick（拾取）+ up（向上） | PASS | pick（拾取；挑选） + up（向上；完全） |
| picnic | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| picture | pict@pict ure@ure | ai | pict（画；描绘）+ -ure（名词后缀） | PASS | pict（画；描绘） + -ure（名词后缀：结果） |
| pinhead | pin@pin head@head | wiktionary | pin（针；钉）+ head（头） | PASS | pin（针；钉） + head（头） |
| pneumatic | pneumat@pneumat ic@ic | ai | pneuma（呼吸/空气）+ -ic：气动的；空气的 | PASS | pneumat（呼吸；空气） + -ic（形容词后缀） |
| polar | pol@pole ar@al | ai | pole（极/轴）+ -ar：极地的；两极的 | PASS | pole（极；轴） + -al（形容词或名词后缀） |
| polymer | poly@poly mer@mer | wiktionary | poly（多）+ mer（部分）：聚合物；高分子 | PASS | poly（多） + mer（部分） |
| preposition | pre@pre posit@posit ion@ion | ai | pre-（在前）+ posit（放置）+ -ion | PASS | pre-（在前；预先） + posit（放置） + -ion（名词后缀：行为或结果） |
| pretty | prett@p13_prett y@y_adj | ai | 古英语 prættiġ < prat（诡计）+ -iġ（-y，形容词后缀），词义由“狡猾”转为“漂亮”。 | PASS | prett（诡计；狡猾） + -y（形容词后缀：有……性质的） |
| prod | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| prodigal | prodig@prodig al@al | ai | prodig（向前驱动；浪费）+-al（形容词后缀） | PASS | prodig（向前驱动；挥霍） + -al（形容词或名词后缀） |
| psychoanalysis | psycho@psycho ana@ana lysis@lys | ai | psycho-（心理）+ ana-（向上、分解）+ lysis（分解）；精神分析 | PASS | psycho（心理；精神） + ana-（向上；按照；类似） + lys（松开；分解） |
| quaint | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| quart | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| quartz | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| questions | question@question s@s | ai | question（问题）+ -s（复数）；问题（复数） | PASS | question（问题；询问） + -s（复数后缀） |
| rapture | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| readers | read@read er@er s@s | ai | read（读）+-er（人）+-s（复数），读者们 | PASS | read（读；阅读） + -er（人；物） + -s（复数后缀） |
| recurrent | re@re curr@curr ent@ent | ai | 拉丁 recurrēns 是 recurrere 的现在分词；re-（回、再）＋curr（跑、发生）＋-ent 形容词后缀。 | PASS | re-（再；回） + curr（跑；发生） + -ent（形容词/名词后缀：处于……状态的） |
| refreshments | re@re fresh@fresh ment@ment s@s | ai | 茶点；饮料（refreshment 的复数） | PASS | re-（再；回） + fresh（新鲜的） + -ment（名词后缀：结果） + -s（复数后缀） |
| refurbish | re@re furbish@furbish | wiktionary | 翻新；整修（re- + furbish 擦亮） | PASS | re-（再；回） + furbish（擦亮；翻新） |
| remittance | remitt@remit ance@ance | ai | 汇款；免除（remit + -ance） | PASS | remit（汇款；宽恕） + -ance（名词后缀：状态） |
| repute | re@re pute@pute | ai | re-（再）+ putare（思考）；名声 | PASS | re-（再；回） + pute（计算；思考） |
| request | re@re quest@quer | ai | re-（再）+ quaerere（寻求）；请求 | PASS | re-（再；回） + quer（寻求；获得） |
| runoff | run@run off@audit5_off | ai | run + off（离开）构成的动词短语转名词 | PASS | run（跑；运行） + off（离开；中止） |
| salesgirl | sale@sale s@s girl@girl | ai | sales + girl | PASS | sale-（销售；出售） + -s（复数后缀） + girl（女孩；少女） |
| saline | sal@sal_salt ine@ine_adj | ai | 拉丁 sal（盐）+-ine（形容词后缀） | PASS | sal-（盐） + -ine（形容词后缀：……的（源自拉丁 -inus）） |
| scream | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| seize | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| seriously | serious@serious ly@ly | wiktionary | serious（严肃的）+ -ly（副词后缀） | PASS | serious（严肃的；认真的） + -ly（副词后缀） |
| shortcut | short@short cut@cut | wiktionary | short（短）+ cut（切、路径） | PASS | short（短；不足） + cut（切；剪） |
| silica | silic@silic a@p15_a_chemical | ai | 新拉丁语 silica，silex（燧石）的词干 silic- 加化学名词后缀 -a，仿 alumina、soda。 | PASS | silic（燧石；硅） + -a（化学名词后缀：物质名称） |
| sincerely | sincere@review_recent_sincere ly@ly | wiktionary | 英语 sincere（真诚的）加副词后缀 -ly，拼写保留词尾 e。 | PASS | sincere（真诚的） + -ly（副词后缀） |
| skiing | ski@p15_ski ing@ing | ai | ski（滑雪）加 -ing，滑雪运动。 | PASS | ski（滑雪） + -ing（分词/名词后缀：进行；行为） |
| smash | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| smoke | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| snowy | snow@snow y@y_adj | ai | snow（雪）+ -y（形容词后缀） | PASS | snow（雪） + -y（形容词后缀：有……性质的） |
| social | soci@soci al@al | ai | soci（同伴）+ -al（形容词后缀） | PASS | soci（同伴；社会） + -al（形容词或名词后缀） |
| solve | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| somebody | some@some_root body@body | wiktionary | some（某个）+ body（人） | PASS | some（某个；一些） + body（身体；人） |
| stiffen | stiff@stiff en@en_suffix | wiktionary | stiff + -en（使……） | PASS | stiff（僵硬；坚固） + -en（动词后缀：使……） |
| stock | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| stodgy | stodg@pr2_06_stodge y@y_adj | ai | stodge（塞满；浓稠食物）加形容词后缀 -y，拼写去 e 作 stodg-。 | PASS | stodge（塞满；浓稠食物） + -y（形容词后缀：有……性质的） |
| strap | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| submissive | sub@sub miss@miss ive@ive | ai | sub- 在下 + miss 送（拉丁 mittere）+ -ive 形容词后缀 → 顺从的 | PASS | sub-（在下；次级） + miss（送；派） + -ive（形容词后缀：有……性质的） |
| sunlit | sun@p16_sun lit@p16_lit | wiktionary | sun（太阳）+ lit（light 的过去分词，被照亮的），表示阳光照射的。 | PASS | sun（太阳；日） + lit（被照亮的；点燃的） |
| suspicion | sus@sub pic@spec_see ion@ion | ai | sus-（sub- 在下）+ pic（看）+ -ion | PASS | sub-（在下；次级） + spec（看） + -ion（名词后缀：行为或结果） |
| sweeping | sweep@sweep ing@ing | ai | sweep（扫、掠过）+ -ing | PASS | sweep（扫；掠过） + -ing（分词/名词后缀：进行；行为） |
| symphony | sym@syn phon@phon y@y | ai | sym-（共同）+ phon（声音）+ -y | PASS | syn-（共同） + phon（声音） + -y（名词后缀：状态或结果） |
| tally | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| tape | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| tea | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| termination | termin@termin ation@ion | ai | 源自拉丁 terminātiō，termin-（界限）加 -ation。 | PASS | termin（界限；终点） + -ion（名词后缀：行为或结果） |
| thirsty | thirst@thirst y@y_adj | wiktionary | 由 thirst（渴）+ -y（形容词后缀）构成 | PASS | thirst（渴；渴望） + -y（形容词后缀：有……性质的） |
| tick | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| toe | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| total | tot@tot al@al | ai | 由 tot（全部）+ -al（……的）构成 | PASS | tot（全部；整个） + -al（形容词或名词后缀） |
| transmitter | transmitt@transmit er@er | ai | transmit（传送；发射）+ -er（物） | PASS | transmit（传送；发射） + -er（人；物） |
| unbecoming | un@un becom@become ing@ing | ai | un-（不）+ become（成为）+ -ing | PASS | un-（不） + become（成为；变得） + -ing（分词/名词后缀：进行；行为） |
| unify | uni@uni fy@fy | ai | uni- 单一 + -fy 使…… | PASS | uni-（单一） + -fy（动词后缀：使……） |
| unpredictable | un@un pre@pre dict@dict able@able | ai | un- 不 + pre- 预先 + dict 说 + -able 可……的 | PASS | un-（不） + pre-（在前；预先） + dict（说；断言） + -able（能……的） |
| utter | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| vacuum | vacu@vacu um@um | ai | vacu 空 + -um 拉丁中性名词 | PASS | vacu（空；空虚） + um（名词后缀：拉丁中性） |
| vaporization | vapor@vapor ization@ization | wiktionary | 来自 vapor + -ization（……化） | PASS | vapor（蒸汽；汽） + -ization（……化） |
| vigour | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| virus | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| volcanic | volcan@volcan ic@ic | ai | 法语 volcan（火山）+ -ic（形容词后缀） | PASS | volcano（火山） + -ic（形容词后缀） |
| wait | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| whereby | where@where by@by_prep | wiktionary | where + by：凭借……；由此 | PASS | where（地方；哪里） + by（由；凭借） |
| whittle | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| widely | wide@wide ly@ly | wiktionary | wide + -ly：广泛地 | PASS | wide（宽广的） + -ly（副词后缀） |
| widen | wid@p18_wid en@en_suffix | ai | wide（宽）+ -en（使……），拼写去 e 作 wid-。 | PASS | wide (stem)（宽（wide 去 e 形）） + -en（动词后缀：使……） |
| wing | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
| worst | wor@review_r3_wor st@review_r3_st_super | ai | 源于古英语 wierrest，与 worse 同源，含历史最高级词尾。现代拼写中表面词尾为 -st。 | PASS | worse（更糟；更恶劣） + -st（最高级（最……）） |
| wrist | 单纯词 | 单纯词清单 |  | PASS | simplex.txt 目标单纯词，无误拆分 |
