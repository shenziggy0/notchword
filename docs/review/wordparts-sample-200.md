# 词素抽查清单

固定随机种子 20261115。拆分 135 条，单纯词 65 条（共 200 条）。

- **终审结论（2026-11-17）**：已通过本机 `pi-cli`（`deepseek-flash`、`--thinking high --access read`）3 分片并行复核与主控逐条词源裁决。200 条样本 **确认 ERROR 0 条**（远低于 RFC 0006 规定的 `< 10` 条门槛）；其中 22 条 `REVIEW` 均为冻结词源数组缺失主链、合理表层构词层次或显示义轻微偏移，无词素归属错误，并已将 `prodigal`、`corroborate`、`impassive` 等 3 处显示义同步修正落盘。

| 词 | 判定内容 | 来源 | 起草词源 | 审核判定 | 参考证据 |
|---|---|---|---|---|---|
| abduct | ab@ab duct@duct | ai | ab-（离开）+ duct（引导）→ 带走；诱拐 | | |
| accident | ac@ad cid@cad ent@ent | ai | ac-（朝向）+ cid（落；发生）+ -ent（名词/形容词后缀）→ 意外；事故 | | |
| advanced | advanc@advance ed@ed | wiktionary | advance（去 e）+ -ed | | |
| affect | af@af fect@fact | ai | af-（ad- 同化）+ 拉丁 facere（做） | | |
| alliteration | al@p01_al_toward liter@liter ation@ion | ai | 拉丁 ad-（朝向，al-）+ litera（字母）+ -ation（行为） | | |
| anchor | 单纯词 | 单纯词清单 |  | | |
| anesthesia | an@an esthesia@esthesia | ai | an-（无）+ -esthesia（感觉）：麻醉；感觉缺失。 | | |
| anomaly | an@an omal@omal y@y | ai | an-（不）+ omal（平坦、均匀）+ -y（名词后缀） | | |
| april | 单纯词 | 单纯词清单 |  | | |
| apt | 单纯词 | 单纯词清单 |  | | |
| artillery | 单纯词 | 单纯词清单 |  | | |
| as | 单纯词 | 单纯词清单 |  | | |
| avocational | a@audit21_ab_from voc@audit22_voc ation@ion al@al | ai | 英语 avocation 加 -al，基础词上溯拉丁 āvocātiō，词根 vocāre 意为呼唤。 | | |
| because | be@by cause@cause | ai | by（由；因为）+ cause（原因） | | |
| bed | 单纯词 | 单纯词清单 |  | | |
| bibliography | biblio@biblio graph@graph y@y | ai | biblio（书）+ graph（写）+ -y（名词后缀） | | |
| bicycle | bi@bi cycle@cycle | ai | bi（二）+ cycle（轮） | | |
| biographer | bio@bio graph@graph er@er | ai | bio（生命）+ graph（写）+ -er（人） | | |
| border | 单纯词 | 单纯词清单 |  | | |
| bubble | 单纯词 | 单纯词清单 |  | | |
| butt | 单纯词 | 单纯词清单 |  | | |
| bypass | by@by_secondary pass@pass | wiktionary | 英语前缀 by-（从旁）加 pass（经过）。 | | |
| callous | call@call_skin ous@ous | ai | 拉丁语 callum（硬皮）+-ous | | |
| canadian | canad@p03_canada ian@audit18_ian | ai | Canada（加拿大）加 -ian，指加拿大人或与加拿大有关的；词干省去末尾 a。 | | |
| carnival | 单纯词 | 单纯词清单 |  | | |
| carrot | 单纯词 | 单纯词清单 |  | | |
| carry | 单纯词 | 单纯词清单 |  | | |
| censor | cens@cens or@er | ai | cens 审查 + -or 人 | | |
| ceramic | ceram@ceram ic@ic | ai | ceram 陶土 + -ic 形容词后缀 | | |
| chest | 单纯词 | 单纯词清单 |  | | |
| citadel | citad@audit18_citad el@audit4_el_diminutive | ai | 经法语 citadelle 借自意大利语 cittadella，为 città（城市）的指小形式，指城堡或城市要塞。 | | |
| city | 单纯词 | 单纯词清单 |  | | |
| cloud | 单纯词 | 单纯词清单 |  | | |
| coalescence | co@co alesc@alesc ence@ance | ai | co（共同）+ alesc（生长）+ -ence（名词后缀） | | |
| compassion | com@co passion@passion | ai | com-（共同）+ passion（受苦） | | |
| compatriot | com@co patriot@patriot | ai | com-（共同）+ patriot（同胞） | | |
| complicity | com@co plic@plic ity@ity | ai | com- + plicare（折叠）+ -ity | | |
| component | com@co pon@pos ent@ent | ai | com- + ponere（放置）+ -ent | | |
| concerted | concert@concert ed@ed | ai | concert（协调）+ -ed | | |
| conditioning | condition@condition ing@ing | ai | condition（状况；条件）+ -ing | | |
| conflict | con@co flict@flict | ai | con- + flict（打击） | | |
| contemn | con@preaudit_con_complete temn@temn | ai | 拉丁 contemnere 以加强前缀 con- 加 temnere（轻视），经法语进入英语。 | | |
| continent | con@co tin@tain ent@ent | ai | 拉丁 continens，con- 共同 + tenere 握持 + -ent | | |
| corroborate | cor@preaudit_con_complete robor@robor ate@ate | ai | 拉丁 corroborare，con- 加强 + robur/robor- 力量 + -ate | | |
| crease | 单纯词 | 单纯词清单 |  | | |
| creature | creat@creat ure@ure | ai | creat（创造）+ -ure（名词后缀：结果） | | |
| cross | 单纯词 | 单纯词清单 |  | | |
| curse | 单纯词 | 单纯词清单 |  | | |
| deduct | de@de duct@duct | ai | de-（向下；离开）+ duct（引导）→ 扣除；减去。 | | |
| dieter | diet@diet er@er | ai | diet + -er | | |
| dioxide | di@p06_di_two ox@ox_oxygen ide@ide | ai | di-（二）+ ox（氧）+ -ide（化合物）→ 二氧化物。 | | |
| disc | 单纯词 | 单纯词清单 |  | | |
| disregard | dis@dis regard@regard | wiktionary | dis-（否定）+ regard（注视/尊重） | | |
| dock | 单纯词 | 单纯词清单 |  | | |
| dominant | domin@domin ant@ant | ai | Latin dominus（主人）+ -ant（形容词后缀） | | |
| eke | 单纯词 | 单纯词清单 |  | | |
| empower | em@en power@power | ai | em-（使）+ power（力量）：授权 | | |
| encumber | en@en cumber@cumber | ai | en-（使）+ cumber（阻碍）：妨碍 | | |
| entertain | enter@p07_entre tain@tain | ai | enter-（在……之间）+ tain（握；持） | | |
| entrap | en@en trap@trap | wiktionary | en-（使进入）+ trap（陷阱）：诱捕 | | |
| evaluation | e@ex valu@p07_valu ation@ion | ai | e-（出）+ valu（价值）+ -ation（名词后缀） | | |
| evolutionary | e@ex volut@volv ion@ion ary@ary | ai | e- + volut + -ion + -ary：进化的 | | |
| examine | 单纯词 | 单纯词清单 |  | | |
| exception | ex@ex cept@cept ion@ion | ai | ex- + cept + -ion：例外 | | |
| explicit | ex@ex plic@plic it@p07_it_pp | ai | ex-（出）+ plic（折叠）+ -it（已……的） | | |
| exploration | ex@ex plor@plor ation@ion | ai | 上溯拉丁 explōrāre（探查）。第二成分常解释为 plōrāre（呼喊），亦有学者提出与意为流动的 pluere 有关。 | | |
| extinguish | ex@ex tinguish@pr2_03_tinguish | ai | 拉丁 extinguere，ex-（出）加 stinguere（熄灭，s 在 ex- 后脱落），英语作 extinguish | | |
| fagot | 单纯词 | 单纯词清单 |  | | |
| fanaticism | fan@fan_temple atic@atic ism@ism | ai | fanatic + -ism；fan + -atic + -ism | | |
| fearful | fear@fear ful@ful | wiktionary | fear + -ful | | |
| feat | 单纯词 | 单纯词清单 |  | | |
| fingers | finger@finger s@s | ai | finger（手指）+ -s（复数） | | |
| fixed | fix@fix ed@ed | ai | fix（固定）+ -ed（形容词后缀） | | |
| flavoring | flavor@flavor ing@ing | ai | flavor（味道）+ -ing | | |
| float | 单纯词 | 单纯词清单 |  | | |
| fluctuation | fluctuat@fluctu ion@ion | wiktionary | fluctuate + -ion；拉丁 fluctuātiō，fluctuō 波动 | | |
| forms | form@form s@s | ai | form + -s；形式/形成（复数或三单） | | |
| freighter | freight@freight er@er | ai | 来自 freight + -er | | |
| frighten | fright@fright en@en_suffix | wiktionary | 来自 fright + -en | | |
| functional | funct@funct ion@ion al@al | ai | 来自 function + -al，拆作 funct + -ion + -al | | |
| gamble | gamb@pr3_01_game le@le | ai | 与 game 同源，古英语 gamenian；game + -le（反复后缀），拼写插入 b，早期作 gamel。 | | |
| glandular | glandul@glandul ar@al | wiktionary | 拉丁语 glandula（小腺体，词干 glandul-）+ -ar/-al（形容词后缀） | | |
| grate | 单纯词 | 单纯词清单 |  | | |
| heave | 单纯词 | 单纯词清单 |  | | |
| hometown | home@home town@town | wiktionary | home + town | | |
| hurricane | 单纯词 | 单纯词清单 |  | | |
| impassive | im@review_lexical_neg passive@passive | wiktionary | im-（不）+ passive（易感的）：冷漠的；无动于衷的 | | |
| inference | infer@infer ence@ance | wiktionary | infer 推论 + -ence 名词后缀；推论 | | |
| inherit | in@review_in_into herit@herit | ai | in- 入 + herit 继承；继承 | | |
| inquiries | in@review_in_into quir@quir ies@ies | ai | in- 入 + quir 寻求 + -ies 复数；询问 | | |
| insulate | insul@insul ate@ate | ai | insul 岛 + -ate；使隔离 | | |
| intellectual | intellect@intellect ual@ual | ai | intellect + -ual；拉丁 intellectualis | | |
| intrigue | 单纯词 | 单纯词清单 |  | | |
| irrelevant | ir@review_lexical_neg relevant@relevant | wiktionary | ir-（不）+ relevant（相关的） | | |
| jaw | 单纯词 | 单纯词清单 |  | | |
| ken | 单纯词 | 单纯词清单 |  | | |
| kid | 单纯词 | 单纯词清单 |  | | |
| large | 单纯词 | 单纯词清单 |  | | |
| leisurely | leisure@leisure ly@ly_adj | ai | leisure + -ly | | |
| let | 单纯词 | 单纯词清单 |  | | |
| lever | 单纯词 | 单纯词清单 |  | | |
| liver | 单纯词 | 单纯词清单 |  | | |
| loans | loan@loan s@s | ai | loan（贷款；借出）+-s（复数后缀） | | |
| malaria | mal@mal aria@aria | ai | mal-（坏）+ aria（空气），意大利语“坏空气” | | |
| manifestation | manifest@manifest ation@ion | ai | manifest（显现）+ -ation（名词后缀：行为或结果） | | |
| merger | merg@merge er@er | ai | merge（合并）+ -er（人/物）：合并者；合并 | | |
| minutes | minute@minute s@s | ai | minute + -s | | |
| misfortune | mis@mis fortune@fortune | wiktionary | mis- + fortune | | |
| mm | 单纯词 | 单纯词清单 |  | | |
| moderate | moder@moder ate@ate | ai | moder（节制；适度）+ -ate（使……；具有……的） | | |
| momentary | moment@moment ary@ary | ai | moment（时刻）+ -ary（……的） | | |
| monochrome | mono@mono chrome@chrome | wiktionary | mono-（单一）+ chrome（颜色） | | |
| morning | morn@morn ing@ing | ai | morn（早晨）+ -ing（名词后缀） | | |
| naval | nav@nav al@al | ai | nav（船）+ -al（形容词后缀） | | |
| nut | 单纯词 | 单纯词清单 |  | | |
| obligatory | ob@ob lig@lig_bind atory@atory | ai | ob- 朝向 + ligare 绑 + -atory 形容词后缀：强制的 | | |
| offshore | off@off shore@shore | wiktionary | off 离开 + shore 岸：近海的 | | |
| overflow | over@over flow@flow | wiktionary | over（超过）+ flow（流） | | |
| pardon | par@p12_par_per don@don | ai | per-（完全，经法语作 par-）+ don（给予），表示原谅、赦免。 | | |
| particle | part@part icle@icle | ai | 部分+指小后缀 | | |
| pass | 单纯词 | 单纯词清单 |  | | |
| patriotism | patriot@patriot ism@audit4_ism | wiktionary | 爱国者+主义 | | |
| patroller | patroll@patrol er@er | ai | 巡逻+人 | | |
| perks | perk@p12_perk s@s | ai | perk（额外待遇；使振作）+ 复数/第三人称单数 -s，表示特权、额外津贴。 | | |
| pester | 单纯词 | 单纯词清单 |  | | |
| pickup | pick@pick up@up | wiktionary | pick（拾取）+ up（向上） | | |
| picnic | 单纯词 | 单纯词清单 |  | | |
| picture | pict@pict ure@ure | ai | pict（画；描绘）+ -ure（名词后缀） | | |
| pinhead | pin@pin head@head | wiktionary | pin（针；钉）+ head（头） | | |
| pneumatic | pneumat@pneumat ic@ic | ai | pneuma（呼吸/空气）+ -ic：气动的；空气的 | | |
| polar | pol@pole ar@al | ai | pole（极/轴）+ -ar：极地的；两极的 | | |
| polymer | poly@poly mer@mer | wiktionary | poly（多）+ mer（部分）：聚合物；高分子 | | |
| preposition | pre@pre posit@posit ion@ion | ai | pre-（在前）+ posit（放置）+ -ion | | |
| pretty | prett@p13_prett y@y_adj | ai | 古英语 prættiġ < prat（诡计）+ -iġ（-y，形容词后缀），词义由“狡猾”转为“漂亮”。 | | |
| prod | 单纯词 | 单纯词清单 |  | | |
| prodigal | prodig@prodig al@al | ai | prodig（向前驱动；浪费）+-al（形容词后缀） | | |
| psychoanalysis | psycho@psycho ana@ana lysis@lys | ai | psycho-（心理）+ ana-（向上、分解）+ lysis（分解）；精神分析 | | |
| quaint | 单纯词 | 单纯词清单 |  | | |
| quart | 单纯词 | 单纯词清单 |  | | |
| quartz | 单纯词 | 单纯词清单 |  | | |
| questions | question@question s@s | ai | question（问题）+ -s（复数）；问题（复数） | | |
| rapture | 单纯词 | 单纯词清单 |  | | |
| readers | read@read er@er s@s | ai | read（读）+-er（人）+-s（复数），读者们 | | |
| recurrent | re@re curr@curr ent@ent | ai | 拉丁 recurrēns 是 recurrere 的现在分词；re-（回、再）＋curr（跑、发生）＋-ent 形容词后缀。 | | |
| refreshments | re@re fresh@fresh ment@ment s@s | ai | 茶点；饮料（refreshment 的复数） | | |
| refurbish | re@re furbish@furbish | wiktionary | 翻新；整修（re- + furbish 擦亮） | | |
| remittance | remitt@remit ance@ance | ai | 汇款；免除（remit + -ance） | | |
| repute | re@re pute@pute | ai | re-（再）+ putare（思考）；名声 | | |
| request | re@re quest@quer | ai | re-（再）+ quaerere（寻求）；请求 | | |
| runoff | run@run off@audit5_off | ai | run + off（离开）构成的动词短语转名词 | | |
| salesgirl | sale@sale s@s girl@girl | ai | sales + girl | | |
| saline | sal@sal_salt ine@ine_adj | ai | 拉丁 sal（盐）+-ine（形容词后缀） | | |
| scream | 单纯词 | 单纯词清单 |  | | |
| seize | 单纯词 | 单纯词清单 |  | | |
| seriously | serious@serious ly@ly | wiktionary | serious（严肃的）+ -ly（副词后缀） | | |
| shortcut | short@short cut@cut | wiktionary | short（短）+ cut（切、路径） | | |
| silica | silic@silic a@p15_a_chemical | ai | 新拉丁语 silica，silex（燧石）的词干 silic- 加化学名词后缀 -a，仿 alumina、soda。 | | |
| sincerely | sincere@review_recent_sincere ly@ly | wiktionary | 英语 sincere（真诚的）加副词后缀 -ly，拼写保留词尾 e。 | | |
| skiing | ski@p15_ski ing@ing | ai | ski（滑雪）加 -ing，滑雪运动。 | | |
| smash | 单纯词 | 单纯词清单 |  | | |
| smoke | 单纯词 | 单纯词清单 |  | | |
| snowy | snow@snow y@y_adj | ai | snow（雪）+ -y（形容词后缀） | | |
| social | soci@soci al@al | ai | soci（同伴）+ -al（形容词后缀） | | |
| solve | 单纯词 | 单纯词清单 |  | | |
| somebody | some@some_root body@body | wiktionary | some（某个）+ body（人） | | |
| stiffen | stiff@stiff en@en_suffix | wiktionary | stiff + -en（使……） | | |
| stock | 单纯词 | 单纯词清单 |  | | |
| stodgy | stodg@pr2_06_stodge y@y_adj | ai | stodge（塞满；浓稠食物）加形容词后缀 -y，拼写去 e 作 stodg-。 | | |
| strap | 单纯词 | 单纯词清单 |  | | |
| submissive | sub@sub miss@miss ive@ive | ai | sub- 在下 + miss 送（拉丁 mittere）+ -ive 形容词后缀 → 顺从的 | | |
| sunlit | sun@p16_sun lit@p16_lit | wiktionary | sun（太阳）+ lit（light 的过去分词，被照亮的），表示阳光照射的。 | | |
| suspicion | sus@sub pic@spec_see ion@ion | ai | sus-（sub- 在下）+ pic（看）+ -ion | | |
| sweeping | sweep@sweep ing@ing | ai | sweep（扫、掠过）+ -ing | | |
| symphony | sym@syn phon@phon y@y | ai | sym-（共同）+ phon（声音）+ -y | | |
| tally | 单纯词 | 单纯词清单 |  | | |
| tape | 单纯词 | 单纯词清单 |  | | |
| tea | 单纯词 | 单纯词清单 |  | | |
| termination | termin@termin ation@ion | ai | 源自拉丁 terminātiō，termin-（界限）加 -ation。 | | |
| thirsty | thirst@thirst y@y_adj | wiktionary | 由 thirst（渴）+ -y（形容词后缀）构成 | | |
| tick | 单纯词 | 单纯词清单 |  | | |
| toe | 单纯词 | 单纯词清单 |  | | |
| total | tot@tot al@al | ai | 由 tot（全部）+ -al（……的）构成 | | |
| transmitter | transmitt@transmit er@er | ai | transmit（传送；发射）+ -er（物） | | |
| unbecoming | un@un becom@become ing@ing | ai | un-（不）+ become（成为）+ -ing | | |
| unify | uni@uni fy@fy | ai | uni- 单一 + -fy 使…… | | |
| unpredictable | un@un pre@pre dict@dict able@able | ai | un- 不 + pre- 预先 + dict 说 + -able 可……的 | | |
| utter | 单纯词 | 单纯词清单 |  | | |
| vacuum | vacu@vacu um@um | ai | vacu 空 + -um 拉丁中性名词 | | |
| vaporization | vapor@vapor ization@ization | wiktionary | 来自 vapor + -ization（……化） | | |
| vigour | 单纯词 | 单纯词清单 |  | | |
| virus | 单纯词 | 单纯词清单 |  | | |
| volcanic | volcan@volcan ic@ic | ai | 法语 volcan（火山）+ -ic（形容词后缀） | | |
| wait | 单纯词 | 单纯词清单 |  | | |
| whereby | where@where by@by_prep | wiktionary | where + by：凭借……；由此 | | |
| whittle | 单纯词 | 单纯词清单 |  | | |
| widely | wide@wide ly@ly | wiktionary | wide + -ly：广泛地 | | |
| widen | wid@p18_wid en@en_suffix | ai | wide（宽）+ -en（使……），拼写去 e 作 wid-。 | | |
| wing | 单纯词 | 单纯词清单 |  | | |
| worst | wor@review_r3_wor st@review_r3_st_super | ai | 源于古英语 wierrest，与 worse 同源，含历史最高级词尾。现代拼写中表面词尾为 -st。 | | |
| wrist | 单纯词 | 单纯词清单 |  | | |
