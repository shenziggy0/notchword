# Englishwords 架构文档

> 参照对象：**Dipword 0.8.3**（`com.dipword.mac`，专有软件，内测版）
> 本文档基于对分发二进制、资源包、内置数据的静态逆向，用于**自主实现同类产品**，不复用其代码与素材。

| 项 | 值 |
|---|---|
| 文档版本 | v1.1（第 14 节补全功能归属与里程碑范围） |
| 日期 | 2026-11-04 |
| 参照产物 SHA-256 | `10a41b0fd25a1a1d0ff0d64888ad774e92965f955242ffd71742b21b1532d40b` |
| 参照版本 | Dipword 0.8.3 (build 92) |
| 目标平台 | macOS 15.0+ (Sequoia)，Universal (arm64 + x86_64) |

**证据分级**（全文遵守）：

- `[观测]` — 直接来自二进制符号、字符串、数据文件或反汇编
- `[推断]` — 由观测合理推导，未 100% 证实
- `[设计]` — 本文档给出的实现选择，**不是**原程序的做法

---

## 1. 结论摘要

Dipword 是一款**常驻刘海（Notch）的查词与字幕翻译工具**。它的技术内核由四块拼成：

1. **取词引擎** — Accessibility API 拿指针下/选中的文字，配合悬停、热键、划词、区域五种入口
2. **多源词典管线** — 导入词典 → 内置 ECDICT 裁剪库 → macOS Dictionary Services → 翻译，四级降级
3. **词素拆解** — 13,515 条语素 + 23,525 条词拆分，把单词拆成「前缀 / 词根 / 后缀」并着色
4. **字幕引擎** — AppleScript 驱动浏览器执行注入的 JS，三条通路（原生字幕轨 / 站点直读 / 屏幕 OCR）

展示层用 `DynamicNotchKit`（MIT，有修改）做刘海外观，用 SwiftUI 写面板内容，AppKit 兜 NSPanel 的定位与非激活显示。

**做同款的关键取舍**：数据可合法复用（ECDICT MIT、词根数据 CC BY-SA），代码必须自己写（EULA 禁止反编译与再分发）。

---

## 2. 产品形态与交互模型

### 2.1 形态

| 维度 | 取值 |
|---|---|
| 应用类型 | 菜单栏常驻；不显示 Dock 图标（`Info.plist` **未**声明 `LSUIElement`，应为运行时切换激活策略 `[推断]`） |
| 主界面 | 屏幕顶部中央的刘海面板（外接屏 / 无刘海机型则**模拟**一个刘海） |
| 次界面 | 设置窗口、笔记本窗口、欢迎引导窗口 |
| 全局入口 | 热键、菜单栏图标、`dipword://` URL Scheme |

`[观测]` 二进制含 `app.hidesDockIcon`、`MenuBarIcon`、`DockIcon`、`NotchlessView`（"未检测到刘海屏" / "已在屏幕顶部中央模拟刘海"）。

### 2.2 核心交互：查词 → 刘海展示

```
        用户意图                     触发            展示
  ┌──────────────────┐
  │ 鼠标停在英文单词上 │──悬停取词────┐
  │ 选中文字          │──划词查询────┤
  │ 按下全局热键      │──快捷键查询──┼──▶  刘海展开  ──▶  单词 + 音标 + 释义
  │ 框选屏幕区域      │──区域取词────┤                     + 词根词缀着色
  │ 播放视频          │──字幕查询────┘                     + 收藏 / 切换词典
  └──────────────────┘
```

设计要点（原程序的做法）：

- **面板不抢焦点**：显示结果时用户仍能继续打字/操作原 App
- **紧凑态只给最小信息**：刘海两侧只显示「单词 + 第一个意思」`[观测]`
- **悬停展开**：`expandsOnNotchHover`，展开阈值 `hoverDwellSeconds`
- **自动收起**：`autoHideSeconds`，指针离开后开始计时
- **触觉反馈**：`hapticOnExpand`，展开时触控板震动
- **一键收藏**：面板右上角星标 `[观测]`
- **切换词典**：点词典名切到下一本 `[观测]`

---

## 3. 总体分层架构

```
┌──────────────────────────────────────────────────────────────────────┐
│  展示层  Presentation                                                 │
│  ┌────────────┐ ┌───────────┐ ┌──────────┐ ┌─────────┐ ┌──────────┐ │
│  │NotchPanel  │ │Settings   │ │Notebook  │ │Onboard  │ │WhatsNew  │ │
│  │(NSPanel +  │ │Window     │ │Window    │ │Window   │ │Window    │ │
│  │ SwiftUI)   │ │           │ │          │ │         │ │          │ │
│  └────────────┘ └───────────┘ └──────────┘ └─────────┘ └──────────┘ │
├──────────────────────────────────────────────────────────────────────┤
│  协调层  Coordination                                                 │
│  NotchPresenter  ·  SelectionCoordinator  ·  SubtitleTracker          │
│  AppCore(状态中枢) ·  HotKeyCenter        ·  PermissionCenter         │
├──────────────────────────────────────────────────────────────────────┤
│  领域层  Domain                                                       │
│  ┌─────────────┐ ┌──────────────┐ ┌────────────┐ ┌───────────────┐  │
│  │LookupEngine │ │DictionarySvc │ │WordParts   │ │Translation    │  │
│  │(取词→查询)   │ │(多源降级)     │ │(词素拆解)   │ │Engine(翻译)    │  │
│  └─────────────┘ └──────────────┘ └────────────┘ └───────────────┘  │
│  ┌─────────────┐ ┌──────────────┐ ┌────────────────────────────┐    │
│  │Vocabulary   │ │UsageStats    │ │Subtitle sources             │    │
│  │(笔记本)      │ │(统计)         │ │(Track/DOM/OCR)              │    │
│  └─────────────┘ └──────────────┘ └────────────────────────────┘    │
├──────────────────────────────────────────────────────────────────────┤
│  系统能力层  System                                                  │
│  Accessibility · ScreenCaptureKit · Vision · Translation ·           │
│  AVSpeechSynthesizer · DictionaryServices · AppleEvents ·            │
│  Keychain · ServiceManagement · IOKit · libsqlite3 · libcompression  │
├──────────────────────────────────────────────────────────────────────┤
│  数据层  Data                                                        │
│  dictionary.sqlite · wordparts.sqlite · 导入词典(StarDict/MDict)     │
│  · 多语种语言包(.dwdict) · 用户数据(trial.json / 日志 / 收藏)         │
└──────────────────────────────────────────────────────────────────────┘
```

`[观测]` 上述分层由 191 个内部类型与 24 个泄漏的源文件路径交叉确认。

---

## 4. 模块清单

### 4.1 展示层

| 模块 | 职责 | 关键类型 `[观测]` |
|---|---|---|
| 刘海面板 | 展开/收起、紧凑态、内容渲染 | `NotchPresenter` `NotchView` `NotchResultView` `NotchShape` `NotchCompactSide` `NotchContent` |
| 设置 | 分页设置、字典顺序、权限卡 | `SettingsWindow` `SettingsRootView` `SettingsTab` `GeneralSettingsView` `DictionarySettingsView` `TranslationServiceView` `SubtitleSettingsView` `SpeechSettingsView` `AboutView` `ExperimentalFeaturesView` `AppRulesView` |
| 笔记本 | 收藏/历史/统计 | `Vocabulary` `VocabularyView` `VocabularyWindow` `NotebookDetailView` |
| 引导 | 首次运行、权限申请 | `OnboardingView` `OnboardingWindow` `PermissionPrompt` `BrowserSetup` |
| 版本更新 | 更新日志 | `WhatsNewView` `WhatsNewWindow` |
| 演示 | 设置页里的交互演示 | `SettingsDemo` `FeatureDemo` `DemoNotch` `WordPartsDemo` `DictionaryDemoView` `TranslationSwitchDemo` |

### 4.2 领域层

| 模块 | 职责 | 关键类型 |
|---|---|---|
| 取词引擎 | 指针/选区/区域 → 候选词 | `LookupEngine` `HoverMonitor` `PointerDwellMonitor` `SelectionMonitor` `PointerWordCapture` `PointerLanguages` `RejectReason` |
| 选区解析 | 从 AX 富文本里抠出英文词 | `RegionText` `AXSelectionCapture` `TextFilter` `TextReflow` |
| 词典服务 | 多源降级、格式解析 | `DictionaryLookup` `EntryChoice` `StarDictReader` `MDictReader` `PackedDictionaryFile` `OpenDictionary` `SystemDictionaryBridge` |
| 词素拆解 | 拆分 + 中文释义 | `WordParts` `WordPartsDetail` `WordPartsHeadword` `WordPartsStyle` |
| 翻译 | 本地/联网、限流、密钥 | `TranslationEngine` `TranslationService` `TranslationProvider` `TranslationTransport` `TranslationLimit` `TranslationServiceError` |
| 字幕 | 三通路采集 + 对齐 | `VideoSubtitles` `SubtitleTracker` `SubtitlePeek` `ScreenSubtitles` `PlaybackMonitor` `SubtitleWindow` |
| 语音 | 朗读 | `Pronouncer` `SpeechVoices` |

### 4.3 基础设施

| 模块 | 职责 |
|---|---|
| `AppCore` / `AppRules` / `Preferences` / `TriggerSettings` | 状态中枢与设置模型 |
| `PermissionCenter` / `AccessibilityAuthorization` | TCC 状态机 |
| `HotKeyCenter` / `HotKeySpec` / `KeyRecorderView` | 全局热键注册与录制 |
| `SystemActivityMonitor` | 全屏/屏保/锁屏感知 |
| `MainThreadWatchdog` | 主线程卡顿检测 |
| `EventLog` / `DiagnosticExport` | 运行日志与诊断导出 |
| `License` / `TrialAnchor` / `SecretStore` | 授权、试用、钥匙串 |
| `Updater` | Sparkle 封装 |
| `AppDataLocation` / `RenameMigration` | 应用数据路径与迁移 |
| `GzipHeader` / `Inflate` / `LZO1X` / `RIPEMD128` | 为 MDict 自实现的压缩摘要设施 |
| `ChineseEntryParser` / `JapaneseEntryParser` / `HTMLText` | 词典条目解析与排版 |

---

## 5. 数据层设计

### 5.1 内置词库 `dictionary.sqlite` `[观测]`

```sql
CREATE TABLE words (
    word        TEXT PRIMARY KEY,
    phonetic    TEXT,              -- 音标（ECDICT 风格，如 ә'biliti）
    translation TEXT NOT NULL,     -- 中文释义（含 [医] / a. 等标记）
    pos         TEXT,              -- 词性（多数为空）
    tag         TEXT,              -- 考试标签，空格分隔
    frq         INTEGER            -- 词频排名，1 = 最常用
) WITHOUT ROWID;

CREATE TABLE forms (
    form TEXT PRIMARY KEY,         -- 屈折形式
    lemma TEXT NOT NULL            -- 原形
) WITHOUT ROWID;
```

**规模**：`words` 57,426 行；`forms` 32,629 行。

`tag` 取值集合：`zk gk cet4 cet6 ky toefl ielts gre`，可组合（如 `cet6 ky toefl ielts gre`）。

`frq` 分布：1 – 50,000，56,992 行有值（占 99.2%）。

> **建议** `[设计]`：给 `words(frq)` 和 `forms(lemma)` 建索引，支持"按词频排序"和"反查原形下所有变体"。

### 5.2 词素库 `wordparts.sqlite` `[观测]`

```sql
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
CREATE TABLE parts (
    id    INTEGER PRIMARY KEY,
    role  TEXT NOT NULL,       -- prefix / root / suffix
    label TEXT NOT NULL,       -- 展示形态，如 "ab-" / "dicate"
    zh    TEXT NOT NULL,       -- 中文释义
    en    TEXT NOT NULL,       -- 英文释义
    lemma TEXT                 -- 词源原形（如 dicō），可空
);
CREATE TABLE words (
    word     TEXT PRIMARY KEY,
    segments TEXT NOT NULL,    -- "ab:10 dicate:11"
    origin   TEXT              -- 词源，如 "拉丁语 abdicatus"
) WITHOUT ROWID;
```

**规模**：`parts` 13,515（root 13,096 / suffix 274 / prefix 145）；`words` 23,525；`meta` 5 行。

**关键设计：`segments` 的紧凑编码**

```text
"ab:10 dicate:11"       空格分隔 → 每段 "label:id"
        │     │
        │     └── parts.id 外键
        └──────── 展示用标签（**单词内的实际拼写**，不是语素的词典形态）
```

> ⚠️ **这里有个容易踩的坑**：`words.segments` 里的 label 是**该词里的拼写**，
> 而 `parts.label` 是语素的**词典形态**，两者常常不同。实测样本：
>
> ```
> unbelievable  →  un:9774  believ:1658  able:71
>                   │        │            │
>   单词内拼写        un       believ       able
>   parts.label       un-      believe      -able
>   parts.zh          不       相信          可…的
> ```
>
> 所以**不能拿 `parts.label` 直接拼回单词**，渲染时必须用 segments 里的 label。

好处：同一语素全库只存一份，23,525 个词仅占 1.5 MB。
代价：渲染时需 N 次 `parts` 查询，**必须加缓存**。

`[设计]` 优化方案：

```swift
// 一次性把 13,515 条语素读进内存字典（约 1.5 MB），彻底避免 N+1
final class MorphologyStore {
    private var parts: [Int32: Morpheme] = [:]   // id -> 语素
    private var words: [String: (segs: [Segment], origin: String?)] = [:]

    func load(db: OpaquePointer) { /* 两条全表查询 */ }
}
```

### 5.3 查询流程 `[观测]`

从二进制提取到的真实 SQL：

```sql
SELECT lemma FROM forms WHERE form = ? LIMIT 1
SELECT word, phonetic, translation, pos FROM words WHERE word = ? LIMIT 1
SELECT segments, origin FROM words WHERE word = ?
SELECT role, label, zh, en FROM parts WHERE id = ?
```

对应的调用顺序 `[推断]`（SQL 字符串只能证明语句存在于二进制里，**不能**证明先后顺序与命中后的分支；要确认需看控制流或运行验证）：

```
原始 token
   │ 规范化：小写、去标点、去所有格
   ▼
[1] forms 查屈折 → 命中则取 lemma 继续（如 abandons → abandon，此行直接观测到）
   ▼
[2] words 查词条 → 命中则出「音标 + 释义」
   ▼
[3] words(词素表) 查拆分 → 命中则出「词根词缀」+ 词源
   ▼
[4] 全都未命中 → 交翻译引擎（单词级）
```

> 注意 `[2]` 和 `[3]` 是**两张不同的表、两个不同的库**，可以只命中其一。

### 5.4 用户数据

| 路径 | 内容 | 出处 |
|---|---|---|
| `~/Library/Application Support/Dipword/` | 应用数据根 | `[观测]` |
| `~/Library/Application Support/Dipword/Dictionaries/` | 导入的多语种语言包 | `[观测]` |
| `~/Library/Application Support/Dipword/trial.json` | 试用状态 | `[观测]` |
| `~/Library/Logs/Dipword/` | 运行日志（**不含查询内容**） | `[观测]` |
| `~/Library/Preferences/com.dipword.mac.plist` | 设置 | `[推断]` |
| 钥匙串 | 翻译服务 API Key | `[观测]` + `SecretStore` 类型 |

---

## 6. 取词链路

### 6.1 五条入口

| 入口 | 机制 | 权限 | 关键参数 |
|---|---|---|---|
| 悬停取词 | `AXUIElementCopyElementAtPosition` + 轮询/事件 | 辅助功能 | `hoverDwellSeconds` `pointerKey` |
| 快捷键查询 | 全局热键 → 同上 | 辅助功能 | `pointerHotKey` |
| 划词查询 | 焦点元素的 `kAXSelectedTextAttribute` | 辅助功能 | `selectionEnabled` |
| 区域取词 | ScreenCaptureKit 截图 → Vision OCR | 屏幕录制 | `regionHotKey` |
| 字幕查询 | 见第 10 节 | 辅助功能 + 屏幕录制 + Apple Events | `screenSubtitles` |

### 6.2 悬停取词的时序 `[推断]` + `[设计]`

```
指针移动
   │
   ├─▶ 节流（~50ms）──▶ 命中缓存？──是──▶ 直接显示
   │                        │否
   │                        ▼
   ├─▶ AXUIElementCopyElementAtPosition(x, y)
   │        │
   │        ├─ 元素为空 → 记 PointerWordMiss，不显示（避免闪烁）
   │        │
   │        ▼
   │   读 kAXValue / kAXTitle / kAXSelectedText
   │        │
   │        ▼
   │   TextFilter：只保留英文词，剔除 URL / 邮箱 / 纯数字 / 代码
   │        │
   │        ▼
   │   停留计时器 hoverDwellSeconds
   │        │  指针移出 → 取消
   │        ▼
   └─▶ 触发查询 → NotchPresenter.show(result)
```

**`RejectReason` 枚举** `[观测]` 说明原程序明确区分了拒绝原因：指针下没词、词不合法、指针已移开、查询被新查询取代等。**这对体验很关键**——不能因为一次没查到就弹错误。

### 6.3 文本过滤规则 `[观测]`

从二进制提取到的正则（可直接参考思路）：

```
^[a-z][a-z0-9+.\-]*://          → 是 URL，拒绝
^[^\s@]+@[^\s@]+\.[a-z]{2,}$    → 是邮箱，拒绝
^[a-z0-9\-]+(\.[a-z0-9\-]+)*\.(com|org|net|io|dev|app|co|cn|edu|gov|me|ai|xyz|info)(/\S*)?$  → 域名，拒绝
/[\u3100-\u312F\u31A0-\u31BF...]/ → 注音符号，拒绝
```

英文字符集：`/[A-Za-z][A-Za-z'’\-]*/`（允许撇号和连字符）。

### 6.4 隐私护栏 `[观测]`

密码管理器白名单——在以下 App 内**不取词**：

```
com.1password.1password      com.agilebits.onepassword7
com.bitwarden.desktop        com.dashlane.Dashlane
com.lastpass.LastPass        com.apple.Passwords
com.apple.keychainaccess
```

`[设计]` 这个名单应做成用户可编辑的 App Rules（原程序有 `AppRulesView`）。

---

## 7. 刘海面板

### 7.1 状态机 `[观测]` + `[设计]`

```
        ┌──────────┐   hover/click    ┌───────────┐
        │ Collapsed│ ───────────────▶ │  Expanded │
        │ (紧凑)    │ ◀─────────────── │  (展开)    │
        └──────────┘   autoHide 计时    └───────────┘
             │                              │
             │ 无结果                        │ 点词典名
             ▼                              ▼
        ┌──────────┐                  ┌───────────┐
        │  Miss    │                  │ Next Dict │
        │ (不打扰)  │                  └───────────┘
        └──────────┘
```

### 7.2 几何 `[推断]`

真实 MacBook 刘海的物理尺寸约为 **宽 200pt × 高 32pt**（因机型略异）。面板宽度通常取：

```
面板宽 = max(刘海宽, 内容最小宽) + 水平内边距 × 2
面板高 = 刘海高 + 内容高度
圆角   = 底部两角 16~20pt，顶部贴合屏幕边缘
```

`[设计]` 实现时用 `NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea` 判断刘海宽度：

```swift
// macOS 12+ 提供刘海区域信息
let notchWidth = screen.frame.width
    - (screen.auxiliaryTopLeftArea?.width ?? 0)
    - (screen.auxiliaryTopRightArea?.width ?? 0)
```

若无这两个区域（外接屏/无刘海机型），则按 `[观测]` 的行为**模拟**一个居中的黑块。

### 7.3 窗口配置 `[推断]`

```swift
let panel = NSPanel(
    contentRect: rect,
    styleMask: [.borderless, .nonactivatingPanel],
    backing: .buffered,
    defer: false
)
panel.isFloatingPanel        = true
panel.level                  = .statusBar          // 盖住普通窗口，不盖系统弹窗
panel.collectionBehavior     = [.canJoinAllSpaces, .stationary, .ignoresCycle]
panel.hidesOnDeactivate      = false               // 关键：不随失焦消失
panel.isOpaque               = false
panel.backgroundColor        = .clear
panel.hasShadow              = false               // 阴影由 SwiftUI 画
```

`[观测]` 原程序有 `FirstMouseHostingView`——说明它重写了 `acceptsFirstMouse`，**点击面板不需要先激活窗口**。这是原生 App 体验的关键细节。

### 7.4 动画参数 `[设计]`

| 项 | 建议值 | 理由 |
|---|---|---|
| 展开时长 | 240 ms | 短于 300ms，感觉跟手 |
| 收起时长 | 180 ms | 退出快于进入 |
| 缓动 | `.spring(response: 0.32, dampingFraction: 0.78)` | 轻微过冲，像原生 |
| 紧凑态淡入 | 120 ms | 不抢注意力 |

`[观测]` 原程序用 `Curve25519`? 否——那是加密。动画侧有 `Motion`、`DemoTiming`、`AnyTransition`、`MoveTransition`、`OffsetTransition`，说明自建了过渡体系。

---

## 8. 词典管线

### 8.1 优先级 `[观测]` + `[推断]`

> 下面的顺序主要来自设置项文案与类型名（`DictionaryOrderList` / `ImportedDictionaries` /
> `SystemDictionaryBridge` / `EntryChoice`），**尚未**由控制流验证；把它当作设计参考而非事实。

```
用户排序的词典列表（可在设置里拖动）
  ├─ 导入的 StarDict (.ifo + .dict/.dict.dz)
  ├─ 导入的 MDict  (.mdx)
  ├─ 导入的 Apple 词典 (.dictionary)
  └─ 导入的多语种语言包 (.dwdict)
        ↓ 全未命中
  内置 dictionary.sqlite
        ↓ 未命中
  macOS Dictionary Services（用户自装词典，如《新牛津》）
        ↓ 未命中
  翻译引擎（单词级）
```

`[观测]` 相关文案：「启用的词典中没有这个词」「已停用的词典 Dipword 查词时不使用」「当前系统仅支持显示排在最前的词典」「StarDict 词典排在词典顺序的最前面」。

> 最后一条说明 **StarDict 有特殊待遇**（可能因为解析最快或兼容性最好）。

### 8.2 自研语言包 `DWDICT1` `[部分观测]`

从 ARM64 反汇编 `PackedDictionaryFile.init(url:)` 还原的头部：

```
偏移 0              : "DWDICT1\n"     ← 8 字节魔数（含换行，立即数 0x0a31 确认）
偏移 8              : u32              ← section 数量
每个 section:
    u16  nameLen
    u8[nameLen]  name                 ← UTF-8，如语言代码
    u32  blockCount
    每个 block:
        u64  fileOffset               ← 指向本文件
        u32  A
        u32  B
        u16  keyLen
        u8[keyLen]  key               ← UTF-8
```

- 块内为 **zlib 裸 deflate**（官方文档明示，且链接 `libcompression`）
- 有 `cache: [(section, index, text)]` + `NSLock` 的块缓存，按需解压
- `lookup(_:in:)` 在解压后的块内做查找

**不确定**：`A` / `B` 哪个是「压缩后长度」、哪个是「解压后长度」。需要样本文件实测。

`[设计]` **建议不兼容此格式**。理由：

- 你的语言包自己生成，格式自定更简单
- 直接用 SQLite（`WITHOUT ROWID` + 前缀索引）在 10 万词量级下查询 < 1ms
- 真要压缩，用 SQLite 的 `zstd` 扩展或每 section 一个 `.xz` 文件

### 8.3 导入格式的解析难点 `[观测]`

原程序自实现了 `LZO1X`（MDict 的压缩方法）和 `RIPEMD128`（`.ifo`/`.idx` 的校验和），说明：

- `.mdx` 需要解析 Header（XML） + KeyBlock（压缩 + 偏移表）
- StarDict 的 `.idx` 是 `word\0 offset(4B) size(4B)` 的序列

`[设计]` 建议**第一期只做 StarDict**（格式最简单、词典资源最多），MDict 放二期。

---

## 9. 翻译管线

### 9.1 抽象 `[观测]` + `[设计]`

```swift
protocol TranslationProvider {
    var id: String { get }
    var displayName: String { get }
    var requiresKey: Bool { get }
    var supportsStreaming: Bool { get }

    func translate(_ req: TranslationRequest) async throws -> String
}

struct TranslationRequest {
    let text: String
    let source: String?      // nil = 自动检测
    let target: String       // 如 "zh-Hans"
    let context: Context     // .word / .sentence / .subtitle
}
```

### 9.2 支持的 provider `[观测]`（从二进制 URL 常量提取）

| 类别 | 服务 | 端点 |
|---|---|---|
| 本地 | Apple Translation framework | 系统 |
| 兼容 OpenAI | OpenAI | `api.openai.com/v1` |
| | DeepSeek | `api.deepseek.com` |
| | Moonshot | `api.moonshot.cn/v1` |
| | SiliconFlow | `api.siliconflow.cn/v1` |
| | 阿里 DashScope | `dashscope.aliyuncs.com/compatible-mode/v1` |
| | MiniMax | `api.minimaxi.com/v1` |
| | Gemini (OpenAI 兼容层) | `generativelanguage.googleapis.com/v1beta/openai` |
| 专有协议 | Anthropic | `api.anthropic.com/v1` |
| | Azure Translator | `api.cognitive.microsofttranslator.com` |
| | DeepL | `api.deepl.com/v2` / `api-free.deepl.com/v2` |
| | 百度 | `fanyi-api.baidu.com/api/trans/vip/translate` |
| | 有道 | `openapi.youdao.com/api` |
| | 彩云 | `api.interpreter.caiyunai.com/v1/translator` |
| | Google Cloud Translation | `translation.googleapis.com/language/translate/v2` |

`[观测]` 还发现 `claude-(opus|sonnet|haiku|fable|mythos)-(\d+)` 正则与 `models?limit=100` — **说明它能自动拉模型列表让用户选**。

### 9.3 限流与降级 `[观测]`

`TranslationLimit` 类型存在，`[推断]` 负责：

- 单次请求字数上限（长字幕切句）
- 并发上限
- 失败重试与退避
- 超时（`submit(_:pair:prepareOnly:timeoutSeconds:)` 签名里带 `timeoutSeconds`）

`[观测]` `prepareOnly` 参数暗示有「预热/预连接」路径。

### 9.4 提示词与思考链 `[观测]`

二进制里有 `(?s)<think>.*?</think>` 正则——**说明会剥离推理模型的 `<think>` 段**，只保留译文。这是个实用的工程细节。

---

## 10. 字幕引擎（最复杂的子系统）

### 10.1 三通路决策树 `[观测]`

注入给浏览器的 JS 最终返回：

```js
if (v.mediaKeys) return 'drm';                                   // 加密视频，放弃
if (inAd())      return 'ad';                                    // 广告中，暂停采集
if (nativeTrack(v) || (S.yt && S.yt.cues) || S.hist.length || S.live.length)
                 return 'dom';                                   // 走 DOM/接口
return 'screen';                                                 // 只能 OCR
```

### 10.2 通路一：原生字幕轨 `[观测]`

```js
S.nativeTrack = function(v){
  for (var i = 0; i < v.textTracks.length; i++) {
    var t = v.textTracks[i];
    if ((t.kind === 'subtitles' || t.kind === 'captions')
        && t.mode === 'showing' && t.cues && t.cues.length) return t;
  }
  return null;
};
```

最可靠，但只有极少数站点把字幕灌进 `textTracks`。

### 10.3 通路二：站点直读 `[观测]`

**YouTube** 是特例，做法很硬核：

1. `PerformanceObserver` 监听 resource，抓播放器**自己发出的** `/api/timedtext?...&pot=...` 请求 URL
2. 把 `fmt` 改成 `json3`，用 `credentials: 'include'` 直接 fetch
3. 解析 `events[].segs[].tOffsetMs` 得到**逐词时间戳**
4. 拿不到 URL 时，让播放器 `setOption('captions','reload',true)` 重载后重试；6 秒后仍失败才放弃
5. 广告期 / 直播 / 视频 ID 不匹配都会跳过

```js
S.ytFind = function(vid, key){
  for (var i = list.length - 1; i >= 0; i--) {
    var u = list[i];
    if (u.indexOf('/api/timedtext') === -1 || !S.qs(u,'pot')) continue;
    if (S.qs(u,'v') !== vid) continue;
    if (S.ytUrlKey(u) === key) return u;
  }
  return null;
};
```

**其他站点**用固定选择器表 `[观测]`：

| 站点 | 选择器 |
|---|---|
| YouTube | `.ytp-caption-window-container .caption-visual-line` / `.ytp-caption-segment` |
| Netflix | `.player-timedtext-text-container` |
| Bilibili | `.bpx-player-subtitle-panel-text` / `.bili-subtitle-x-subtitle-panel-text` |
| Disney+ | `.dss-subtitle-renderer-line` |
| Prime Video | `.atvwebplayersdk-captions-text` |
| Vimeo | `.vp-captions` |
| Udemy | `[data-purpose=captions-cue-text]` |

**通用兜底**：从 `<video>` 往上找 5 层容器，扫描其内文本节点，按 y 坐标合并成行 `[观测]`。

### 10.4 通路三：屏幕 OCR `[观测]`

```
ScreenCaptureKit 截「视频区域」
        │  （区域来自 JS 计算的归一化矩形）
        ▼
Vision VNRecognizeTextRequest
        │  recognitionLevel: .fast / .accurate
        │  recognitionLanguages: ["en-US"]
        ▼
按 y 坐标聚行 → 累积到 hist[] → 变化才推送
```

`[观测]` 相关文案：「先用快速识别」「已改用快速识别」「快速识别也出错」「准确识别不可用」「识别期间指针已移开」——说明它做了**快慢两级 OCR 的降级策略**。

### 10.5 双语对齐算法 `[观测]`（值得抄）

英文 cue 碎片化，中文轨是整句，长度对不上。原程序的解法：

**第一步：把英文碎片并成句子**

```js
// 断句条件：句末标点 / 间隔 >1s / 说话人标记 / 已满 3 条
if (ytEnd.test(prev.t) || E[i].s - prev.e > 1
    || ytSpeaker.test(E[i].t) || cur.length >= 3) { push(cur); cur = []; }
```

**第二步：用区间重叠 + 并查集做对齐**

```js
// 中文条 z 与哪些英文句组时间重叠？
for (q = ...; q < G.length && span[q][0] < z.e; q++) {
  var o = Math.min(z.e, span[q][1]) - Math.max(z.s, span[q][0]);
  if (o > 0) ov.push([o, q]);
}
ov.sort((a,b) => b[0] - a[0]);            // 取重叠最大的做主组
hang.push([j, ov[0][1]]);
for (q = 1; q < ov.length; q++) {
  if (ov[q][0] >= 0.3 * (z.e - z.s))      // 次重叠 ≥ 中文条时长 30% 才合并
    owner[root(ov[q][1])] = root(ov[0][1]);
}
```

**第三步：算覆盖率，不够就放弃**

```js
cover = 被覆盖的英文 cue 数 / 英文 cue 总数
if (best && best.cover >= 0.2) → 采用
```

**第四步：多轨择优** —— zh-Hans / zh-CN / zh-SG / zh 全试，取 `cover` 最高的；还要求候选轨里中文字符占比 ≥ 50%。

> **宁缺毋滥**：覆盖率不足 20% 就不显示中文，而不是错位显示。这是准确度的来源。

### 10.6 状态协议 `[观测]`

JS 侧维护 `window.__notchTranslateSubtitles`，向 Swift 返回 JSON：

```jsonc
{
  "hist":  ["上一句英文", "..."],      // 最多 80 条
  "times": [12.4, 15.1, "..."],        // 对应起始时间
  "live":  ["当前正在播的片段"],         // 逐词刷新
  "zh":    ["上一句中文", null, "..."],
  "source":"track | site | generic | youtube",
  "paused": true,
  "justPaused": false,                 // 5 秒内刚暂停
  "now":   18.3,                       // 当前播放位置
  "meta":  { "title":"...", "episode":"...", "site":"youtube" },
  "note":  "ok | ad | drm | live | nourl | fetchfail",
  "zhNote":"ok:zh-Hans:87"             // 中文对齐状态 + 覆盖率
}
```

`[观测]` `justPaused`（5 秒窗口）用于实现「暂停就弹字幕」这个交互。

### 10.7 与浏览器的桥 `[观测]`

```applescript
tell application id "com.google.Chrome"
  if (count of windows) is 0 then return "nowindow"
  ...
  execute front window's active tab javascript "..."
end tell
```

- 受 `NSAppleEventsUsageDescription` 与 TCC 自动化授权双重管控
- 支持的浏览器：Safari、Safari TP、Chrome、Chrome Beta、Edge、Brave、Vivaldi、Opera、Arc、Dia、Firefox

---

## 11. 权限与隐私

### 11.1 权限矩阵

| 功能 | 辅助功能 | 屏幕录制 | Apple Events | 本地网络 |
|---|:---:|:---:|:---:|:---:|
| 悬停/快捷键/划词取词 | ✅ | | | |
| 区域取词 | | ✅ | | |
| 字幕：原生轨/站点 | ✅ | | ✅ | |
| 字幕：OCR | | ✅ | | |
| 联网翻译 | | | | ✅ |

### 11.2 隐私声明 `[观测]`

`Info.plist`：

- `NSAppleEventsUsageDescription`：用于读取浏览器中正在播放的视频字幕，并在查看字幕时暂停视频
- `NSLocalNetworkUsageDescription`：用于连接局域网中运行的翻译模型
- `PrivacyInfo.xcprivacy`：只声明 `UserDefaults`（CA92.1），**无任何数据采集**，`NSPrivacyTracking: false`

EULA 明确：「查词和翻译默认在本机完成，本软件不采集任何数据」「运行日志不含您查询的文字」。

`[设计]` 同款应保持同样的边界，这是这类工具建立信任的基础。

---

## 12. 设置模型 `[观测]`

从二进制提取的完整偏好键（28 个 `trigger.*` / `panel.*` / `firstRun.*`）：

```swift
enum PrefKey {
    // 触发方式
    static let pointerLookupEnabled   = "trigger.pointerLookupEnabled"
    static let selectionEnabled       = "trigger.selectionEnabled"
    static let regionLookupEnabled    = "trigger.regionLookupEnabled"
    static let pointerTrigger         = "trigger.pointerTrigger"      // hover / hotkey
    static let pointerKey             = "trigger.pointerKey"
    static let pointerHotKey          = "trigger.pointerHotKey"
    static let regionHotKey           = "trigger.regionHotKey"

    // 字幕
    static let videoSubtitles         = "trigger.videoSubtitles"
    static let screenSubtitles        = "trigger.screenSubtitles"
    static let translatesSubtitles    = "trigger.translatesSubtitles"
    static let showsSubtitlesOnPause  = "trigger.showsSubtitlesOnPause"
    static let pausesVideoOnPeek      = "trigger.pausesVideoOnPeek"
    static let resumesVideoAfterPeek  = "trigger.resumesVideoAfterPeek"
    static let previousSubtitleHotKey = "trigger.previousSubtitleHotKey"
    static let nextSubtitleHotKey     = "trigger.nextSubtitleHotKey"

    // 面板
    static let expandsOnNotchHover    = "trigger.expandsOnNotchHover"
    static let hapticOnExpand         = "panel.hapticOnExpand"
    static let summaryStyle           = "panel.summaryStyle"
    static let wordParts              = "trigger.wordParts"

    // 首次运行
    static let sawOnboarding          = "firstRun.sawOnboarding"
    static let sawFirstResult         = "firstRun.sawFirstResult"
    static let whatsNewVersion        = "firstRun.whatsNewVersion"
    static let installedAt            = "firstRun.installedAt"
    static let lastSeen               = "firstRun.lastSeen"
    static let hoverExpandCount       = "firstRun.hoverExpandCount"
    static let freshDefaultsApplied   = "firstRun.freshDefaultsApplied"

    // 其他
    static let showsDemos             = "settings.showsDemos"
    static let onlineTranslation      = "translation.online"
    static let deviceSeed             = "license.deviceSeed"
}
```

`[不确定]` 各键的**默认数值**未从二进制确认（在 `Preferences` 初始化闭包里，需要反编译）。

`[设计]` 建议默认值：

| 键 | 建议默认 | 说明 |
|---|---|---|
| `pointerLookupEnabled` | `true` | 核心功能默认开 |
| `pointerTrigger` | `hover` | 最自然的入口 |
| `hoverDwellSeconds` | `0.35` | 太短误触，太长迟钝 |
| `autoHideSeconds` | `2.5` | 来得及看完一句 |
| `expandsOnNotchHover` | `true` | 刘海的核心交互 |
| `hapticOnExpand` | `true` | 增强反馈 |
| `showsSubtitlesOnPause` | `true` | 看剧时的最佳时机 |
| `resultRetentionSeconds` | `8` | 结果保留时长 |

---

## 13. 工程结构建议 `[设计]`

```
Englishwords/
├── Package.swift 或 Englishwords.xcodeproj
├── Sources/Englishwords/
│   ├── App/
│   │   ├── EnglishwordsApp.swift       @main
│   │   ├── AppDelegate.swift           状态栏、启动流程
│   │   ├── AppCore.swift               状态中枢 (ObservableObject)
│   │   └── AppDataLocation.swift       路径与迁移
│   ├── Notch/
│   │   ├── NotchGeometry.swift         刘海尺寸探测/模拟
│   │   ├── NotchShape.swift            自定义 Shape
│   │   ├── NotchPanel.swift            NSPanel 子类
│   │   ├── NotchPresenter.swift        展开/收起/自动隐藏
│   │   └── NotchResultView.swift       结果渲染
│   ├── Lookup/
│   │   ├── LookupEngine.swift          入口编排
│   │   ├── AXPicker.swift              AX 取词
│   │   ├── HoverMonitor.swift          悬停与停留
│   │   ├── SelectionMonitor.swift      划词
│   │   ├── RegionPicker.swift          框选 + OCR
│   │   └── TextFilter.swift            候选词过滤
│   ├── Dictionary/
│   │   ├── DictionaryLookup.swift      多源降级
│   │   ├── BuiltinDictionary.swift     SQLite
│   │   ├── MorphologyStore.swift       词素拆解
│   │   ├── StarDictReader.swift
│   │   └── SystemDictionaryBridge.swift
│   ├── Translate/
│   │   ├── TranslationProvider.swift   协议
│   │   ├── AppleTranslate.swift        本地
│   │   ├── OpenAICompatProvider.swift  兼容层（覆盖 8 家）
│   │   ├── AnthropicProvider.swift
│   │   └── TranslationCoordinator.swift 限流/缓存/超时
│   ├── Subtitle/
│   │   ├── BrowserBridge.swift         AppleScript + JS 注入
│   │   ├── SiteScripts.swift           站点选择器表
│   │   ├── SubtitleTracker.swift       轮询与状态
│   │   ├── SentenceAligner.swift       断句 + 并查集对齐
│   │   └── ScreenOCR.swift             ScreenCaptureKit + Vision
│   ├── Settings/
│   │   ├── Preferences.swift
│   │   ├── SettingsWindow.swift
│   │   └── PermissionCenter.swift
│   └── Support/
│       ├── HotKeyCenter.swift
│       ├── SecretStore.swift           钥匙串
│       └── EventLog.swift
├── Resources/
│   ├── dictionary.sqlite               ← 由 ECDICT 生成（MIT）
│   └── wordparts.sqlite                ← 由公开词源数据生成（CC BY-SA）
└── Tests/
```

---

## 14. 里程碑

| 阶段 | 交付物 | 验收标准 | 估时 | 状态（2026-11-22） |
|---|---|---|---|---|
| **M0** | 数据准备 | `dictionary.sqlite` 可从 ECDICT 一键生成；词根表可构建 | 1 天 | 代码完成 |
| **M1** | 取词 + 弹窗 | 热键 → 选中词 → 显示释义 | 2 天 | 代码完成 |
| **M2** | 多源词典 | 内置 + Apple 词典 + 词根拆解 | 2 天 | 代码完成 |
| **M3** | 刘海面板 | 形状、悬停展开、自动收起、不抢焦点 | 3 天 | 代码完成 |
| **M4** | 悬停/划词 | AX 取词 + 过滤 + 节流 | 2 天 | 代码完成 |
| **M5** | 翻译 | Apple 本地 + 1 个联网 provider | 2 天 | 代码完成 |
| **M5.5** | 内置词根词缀词典 | 中考—托福约 1.1 万词全部判定为拆分或单纯词；见 [0003](design/0003-内置词根词缀词典.md) | 3–4 天 | 代码完成（待实机补验项见 0007） |
| **M6** | 字幕 + 区域取词 | 字幕：原生轨 → 站点 → OCR 三级降级 + 双语对齐；区域取词：框选 → OCR → 查词 | 7 天 | 代码完成（真实站点与多屏待实机补验） |
| **M7** | 设置/引导/笔记本/扩展 + 首个公开版本 | 见 14.2 的 M7 清单，全部完整可用；零付费方式对外发布（[0004](design/0004-M5.5至M7-macOS实施方案.md)） | 9 天 | 代码完成（正式签名与双版本升级待补验） |
| **M1—M7 统一验收** | 全部功能实机验收后对外发布 | 合并 0001 §6、[0003](design/0003-内置词根词缀词典.md) §6、[0004](design/0004-M5.5至M7-macOS实施方案.md) §6 逐条通过或记录问题 | 2 天 | 部分（自动化项已过，GUI/外部条件项待补验） |
| **M8** | **商业化与授权（最后做）** | 三项 Pro：字幕 / 词根词缀 / 接入自己的 AI 翻译；无试用期；卡密兑换 + 一次性核销；免费用户只给演示预览 | 1–2 周（服务端只做核销） | ⬜ |

**M1 + M2 约一周就能有能用的东西**，字幕留到最后。

> 「代码完成」指功能已实现、单元测试通过，**不等于实机验收通过**。
> 2026-11-04 决定：不做分阶段验收，M1—M7 全部实现后**统一验收**；实施任务拆分见
> [0005 实施任务书](design/0005-M5.5至M7实施任务书.md)。代价是底座问题会晚暴露，统一验收时需按模块分别定位。
> 2026-11-22 起：自动化可验证项（Python/Swift 单测、双架构构建、随包自检、签名验证）已通过；
> 需 GUI 交互或外部条件的项在 [0006](design/0006-完整功能收尾与缺陷修复方案.md) §6 与
> [0007](design/0007-词素终审落盘与实机验收收尾方案.md) §6 中如实标注为待补验。

**规则：M8 不新增任何用户功能**，只给已有功能加授权判断、付费墙和兑换流程。
因此 M8 要锁定或预览的每一项能力，必须在 M7 结束前已经存在（见 14.1 「Pro」列）。

### 14.1 功能清单与归属

本表是**功能范围的唯一定义**：每项都有归属里程碑和免费 / Pro 归类，与
[0002](design/0002-商业化与授权实施方案.md) 第 1.2 节的能力矩阵一致。新增功能先改本表。

| 分组 | 功能 | 里程碑 | 免费 / Pro | 状态 |
|---|---|---|---|---|
| **取词入口** | 快捷键查词 `⌥D`（词典优先） | M1 | 免费 | ✅ 代码完成 |
| | 快捷键翻译 `⌥T`（直接翻译选中内容） | M5 | 免费 | ✅ 代码完成 |
| | 悬停取词（停留约 0.35s 出结果） | M4 | 免费 | ✅ 代码完成 |
| | 划词取词（被动只读 AX；读不到时用 `⌥D`/`⌥T` 安全模拟 ⌘C 并还原剪贴板） | M4 | 免费 | ✅ 代码完成 |
| | 区域取词（框选屏幕区域 → Vision OCR → 查词/翻译） | **M6** | 免费 | ✅ 代码完成（多屏待实机补验） |
| | 字幕查询（浏览器视频字幕取词） | M6 | **Pro** | ✅ 代码完成（真实站点待补验） |
| | 候选过滤（URL/邮箱/代码不触发）、去重、节流、按应用排除 | M4（应用排除规则 UI 在 M7） | 免费 | ✅ 代码完成 |
| **词典** | 内置词库（ECDICT 裁剪，约 4.3 万词）+ 屈折还原 | M0—M2 | 免费 | ✅ 代码完成 |
| | macOS 系统词典回落 | M2 | 免费 | ✅ 代码完成 |
| | 导入 StarDict 词典 | **M7** | 免费 | ✅ 代码完成 |
| | 词典启用 / 停用与排序 | **M7** | 免费 | ✅ 代码完成 |
| **词根词缀** | 词素拆解 + 词源 + 三色渲染 | M2 | **Pro** | ✅ 代码完成（7,757 词拆分，11,444 目标全覆盖） |
| | 词素数据覆盖中考—托福约 1.1 万词（[0003](design/0003-内置词根词缀词典.md)） | **M5.5** | **Pro** | ✅ 代码完成 |
| **翻译** | Apple 本地翻译（含语言包准备入口） | M5 | 免费 | ✅ 代码完成 |
| | 联网翻译：单个 OpenAI 兼容端点（手填 URL / 模型 / 密钥） | M5 | **Pro** | ✅ 代码完成 |
| | 联网翻译：服务预设列表（OpenAI、DeepSeek、Moonshot、SiliconFlow、DashScope、MiniMax、Gemini 兼容层）+ 拉取模型列表（剥离 `<think>` 已在 M5 实现） | **M7** | **Pro** | ✅ 代码完成 |
| | 联网翻译：Anthropic 原生协议 | **M7** | **Pro** | ✅ 代码完成 |
| | 翻译缓存、取消过期请求、超时 | M5 | 免费 | ✅ 代码完成 |
| **刘海面板** | 紧凑态、悬停展开、离开收起、Esc 关闭、不抢焦点 | M3 | 免费 | ✅ 代码完成 |
| | 无刘海屏 / 外接屏模拟刘海 | M3 | 免费 | ✅ 代码完成（待实机） |
| | 朗读（AVSpeech） | M2 | 免费 | ✅ 代码完成 |
| | 面板收藏星标 | **M7** | 免费 | ⬜（面板未提供星标，收藏在笔记本窗口内完成） |
| | 展开触觉反馈 | **M7** | 免费 | ✅ 代码完成 |
| **笔记本** | 收藏单词 | M7 | 免费 | ✅ 代码完成 |
| | 查询历史 | M7 | 免费 | ✅ 代码完成 |
| | 使用统计 | M7 | 免费 | ✅ 代码完成 |
| **设置与系统** | 菜单栏常驻、无 Dock 图标 | M1 | 免费 | ✅ 代码完成 |
| | 设置窗口（开关、时长、翻译与密钥） | M5 | 免费 | ✅ 代码完成（最小版） |
| | 完整分页设置（通用 / 词典 / 翻译 / 字幕 / 朗读 / 应用规则 / 关于） | **M7** | 免费 | ✅ 代码完成 |
| | 热键自定义录制 | **M7** | 免费 | ✅ 代码完成 |
| | 开机启动 | **M7** | 免费 | ✅ 代码完成（`SMAppService`） |
| | 首次运行引导 + 权限中心（辅助功能 / 屏幕录制 / Apple Events） | **M7** | 免费 | ✅ 代码完成 |
| | 诊断导出（日志不含查询正文） | **M7** | 免费 | ✅ 代码完成 |
| **发布** | 自签名证书（稳定签名身份）+ DMG + GitHub Releases；不做 Developer ID / 公证（[0004](design/0004-M5.5至M7-macOS实施方案.md)） | **M7** | — | ✅ 代码完成（本机为 ad-hoc，正式证书待补验） |
| | Sparkle 自动更新 | **M7** | — | ✅ 代码完成（双版本升级链待实机验证） |
| | 关于页预告「目前免费、正式版将收费」 | **M7** | — | 本期不做（0006 决定商业化暂缓，不做收费预告） |
| **商业化** | 授权判断缝 `Entitlements.allows(_:)` | M8 | — | ✅ 已落地，调用点未接 |
| | 卡密兑换、核销服务端、付费墙与三项预览 | M8 | — | ⬜ |

### 14.2 各里程碑范围补充

**M6 字幕 + 区域取词**（区域取词从原 M7 前移）

- 区域取词与字幕 OCR 共用 ScreenCaptureKit + Vision 管线、共用屏幕录制权限，放在同一里程碑只建一次。
- 字幕范围按第 10 节：原生字幕轨 → 七站点 DOM 直读 → 屏幕 OCR，双语断句对齐，上/下一句热键，查看时暂停视频。
- 开工前先出设计文档 0004（第 10 节是参考产品分析，不是实施方案）。
- 字幕入口预留 `allows(.subtitles)` 调用位置，但 M8 前恒为放行。

**M7 设置 / 引导 / 笔记本 / 扩展 + 首个公开版本**（估时 4 天 → 9 天；词素数据已移至 M5.5；实施方案见 [0004](design/0004-M5.5至M7-macOS实施方案.md)）

| 子项 | 估时 |
|---|---|
| 笔记本：收藏、历史、统计 + 用户数据存储（第 5.4 节） | 2 天 |
| 完整设置分页、热键录制、应用排除规则、开机启动、触觉反馈 | 2 天 |
| 首次运行引导 + 权限中心 | 1 天 |
| StarDict 导入 + 词典启用 / 排序 | 1.5 天 |
| 翻译服务预设列表 + 模型列表 + Anthropic 协议 | 1 天 |
| 自签名、Sparkle、关于页收费预告 → 发布首个公开版本（零付费，见 0004） | 1.5 天 |

**M8**：只做 [0002](design/0002-商业化与授权实施方案.md) 第 5.1 节列出的内容，不再承接功能缺口。

### 14.3 明确不做（全部里程碑）

| 功能 | 原因 |
|---|---|
| MDict（`.mdx`）导入 | 需自实现 LZO1X / RIPEMD128，成本高；StarDict 覆盖主要需求。如有需求另立里程碑 |
| 多语种语言包 `DWDICT1` | 参考产品的私有格式，头部语义未确认（15.3 第 1 条） |
| 传统机翻 API（DeepL、Azure、百度、有道、彩云、Google） | 各家专有协议，每家单独适配；AI 翻译已覆盖需求 |
| `dipword://` 式 URL Scheme、更新日志窗口 | 非核心，首版不需要 |
| Mac App Store 版本 | 见 [0002](design/0002-商业化与授权实施方案.md) 7.3 |

商业授权排在 **M8**，等 M6/M7 全部完成后再接；详细设计见
[0002 商业化与授权实施方案](design/0002-商业化与授权实施方案.md)。

> 与参考产品的差异：Dipword 的 Pro 只有两项（词根词缀、自己的 AI 翻译），**字幕是免费的**；
> 本项目把**字幕也划入 Pro**，并**取消试用期**（免费用户只得到演示预览）。
> 售卖用**卡密**：发卡平台收款并自动发货，自建服务端只负责「一次性核销 + 绑定设备 + 签激活凭证」，
> 不处理支付。「只能激活一次」本身要求一份全局记录，纯离线的卡密做不到，所以服务端不可省。
> 分发方式只走官网 DMG，**不上架 Mac App Store**（审核指南 3.1.1 不允许引导站外购买/兑换，
> 上架就必须改用 StoreKit，等于重做授权层）。
> 首个公开版本**不预锁**这三项，收费开关到 M8 才生效；需在关于页与官网预告「目前免费、正式版将收费」。

---

## 15. 风险、合规与未知

### 15.1 合规

| 对象 | 许可 | 能否复用 |
|---|---|---|
| ECDICT 词库 | MIT | ✅ 可以，保留版权声明 |
| 词根/语素数据 | CC BY-SA 4.0 | ✅ 可以，署名 + 同许可分发 |
| DynamicNotchKit | MIT | ✅ 可以 |
| Sparkle | MIT | ✅ 可以 |
| **Dipword 本体** | 专有，EULA 禁止反编译/再分发 | ❌ 代码、UI、素材、图标都不可复制 |
| 多语种语言包 | CC BY-SA 4.0 | ✅ 数据可用，但格式自定 |

> 结论：**用同样的公开数据源 + 自己的实现**。这正是原程序自己做的事。

### 15.2 技术风险

| 风险 | 影响 | 缓解 |
|---|---|---|
| AX API 在部分 App 里取不到文字 | 悬停取词失效 | 多属性回退（value/title/selectedText/AXStringForRange） |
| 站点 DOM 结构变更 | 字幕直读失效 | 选择器表可热更新 + 通用兜底 + OCR 保底 |
| 浏览器自动化授权被用户拒绝 | 字幕功能不可用 | 降级到 OCR；引导页说明 |
| Vision OCR 对深色字幕识别率低 | 字幕错字 | 先做快速识别，失败降级准确模式；支持区域微调 |
| 无刘海的 Mac / 外接屏 | 面板无处安放 | 模拟刘海 + 顶部中央备用位置 |
| `NSPanel` 抢焦点 | 打断用户输入 | `.nonactivatingPanel` + `acceptsFirstMouse` |

### 15.3 尚未确认（诚实标注）

1. `DWDICT1` block 头两个 u32 的确切语义（压缩长度 vs 原始长度）
2. `hoverDwellSeconds` / `autoHideSeconds` / `resultRetentionSeconds` 的默认值
3. Pro 的具体功能边界（文案只写"Pro 多了两样"）与试用期长度
4. 刘海面板的精确尺寸 / 圆角常量
5. 词根词缀的**配色方案**（未发现颜色常量，可能是 SwiftUI 语义色）

---

## 附录 A：逆向取证清单

| 产物 | SHA-256 / 位置 |
|---|---|
| DMG | `10a41b0fd25a1a1d0ff0d64888ad774e92965f955242ffd71742b21b1532d40b` |
| 主程序 (universal) | `3828597190832144e7e185bc8ddef17a97e2989a479ded2fb402d82fd0472a5c` |
| `dictionary.sqlite` | `21ec53f5b0e6c9c4ddf801d8a7d518d10e079a504af6dd5bc9c69377a35f0a70` |
| `wordparts.sqlite` | `f4bd75984a83f43a3cc875f345571c09b551e7c5809aff00bce0ff38c6219d99` |
| 内嵌脚本（13 段） | 由二进制偏移 3.79 MB / 15.65 MB 两处提取 |

## 附录 B：关键符号

```
PackedDictionaryFile.init(url:)           0x10012f970
PackedDictionaryFile.lookup(_:in:)        0x10012f668
PackedDictionaryFile.block(_:of:section:) 0x10013079c
```

（符号地址基于 arm64 slice，基址 `0x100000000`）

## 附录 C：独立交叉核对

工作区里另有一份由**独立会话**产出的调查：`docs/dipword-analysis/REPORT.md`（含 `evidence/` 目录）。
它用另一套 REA 记录、同样的 DMG 做了第二次静态分析。核对结果：

**一致（互相印证）**

- 两个 SQLite 的 schema、行数（57,426 / 32,629 / 23,525 / 13,515）、`integrity_check = ok`
- `wordparts` 的 `segments` 编码方式与 `parts` 关联关系
- 字幕脚本机制：按面积选 video、`nativeTrack`、七站点选择器、3,000 节点扫描上限、
  150 ms MutationObserver 合并、150 条历史 / 返回 80 条、`na|drm|ad|dom|screen` 分流
- 依赖框架：SwiftUI / AppKit / ScreenCaptureKit / Vision / Translation / AVSpeech / Sparkle
- 词库与构词数据的许可归属

**该报告补充的证据（本文已采纳）**

- `missing_lemmas = 0`：`forms.lemma` 全部能在 `words` 找到
- `invalid_segments = []`：全量 segment 无格式错误、无悬空 `parts` 引用
- 实测样本 `unbelievable → un:9774 believ:1658 able:71`，据此补上了 §5.2 的「拼写 vs 词典形态」提醒

**本文据此更正的三处**

| 位置 | 原写法 | 更正 |
|---|---|---|
| §2.1 | 断言用 `LSUIElement` 隐藏 Dock | `Info.plist` 里**没有**该键，改为「运行时切换激活策略 `[推断]`」 |
| §5.3 | 用 `abandoned → abandon` 举例 forms | 换成直接观测到的 `abandons → abandon` |
| §5.3 / §8.1 | 查询链路与词典优先级标 `[观测]` | 降级为 `[推断]`，因为 SQL 存在 ≠ 调用先后 |

**仍然存疑（两份报告都没解决）**

- 面板是否真的不抢焦点（`FirstMouseHostingView` 只是强线索）
- 动画几何、默认时长、`DWDICT1` 两个 u32 的语义
- 各站点字幕当前是否仍然可用（需要运行验证）
