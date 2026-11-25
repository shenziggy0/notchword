<p align="center">
  <img src="docs/images/logo.png" width="96" alt="Englishwords Logo" />
</p>

# Englishwords

一个「刘海查词 + 翻译」的 macOS 应用。参照 **Dipword 0.8.3** 的产品形态自主实现，
代码与素材均未复用；词库使用 ECDICT（MIT），词根词缀数据由本项目整理（CC BY-SA 4.0）。

当前实现覆盖设计文档 [0001-Englishwords-M0至M5实施方案](docs/design/0001-Englishwords-M0至M5实施方案.md)
的 M0—M5，以及 [0003](docs/design/0003-内置词根词缀词典.md)／[0004](docs/design/0004-M5.5至M7-macOS实施方案.md)
的 **M5.5—M7**（词素、字幕、区域取词、设置、引导、笔记本、StarDict、发布链路），
并已完成 [0008](docs/design/0008-Windows版本MVP实施方案.md) 的 **Windows MVP**。细节状态见
[ARCHITECTURE §14](docs/ARCHITECTURE.md#14-里程碑)。

双端共用同一份随包词库与词素库。取词安全策略：被动悬停与划词只做**只读 Accessibility** 读取，
不在任意鼠标拖拽时注入模拟 `⌘C`；读不到选区的应用（部分 Electron／画布）改用显式 `⌥D`／`⌥T`，
由这两条热键在备份并还原剪贴板的前提下做安全模拟复制兜底。

```
Englishwords/
├── docs/
│   ├── ARCHITECTURE.md          ← 架构说明
│   ├── design/                  ← 设计文档（M0—M7、Windows MVP 等）
│   └── images/
├── demo/                        ← 交互原型（HTML，仅演示）
├── macos-starter/               ← macOS 原生应用
│   ├── Package.swift
│   ├── build.sh                 ← Universal 打包
│   ├── test.sh                  ← 核心逻辑测试
│   ├── data/                    ← 词素源数据 + 来源说明
│   ├── scripts/                 ← 数据库生成脚本
│   └── Sources/Englishwords/
│       ├── App/                 ← 入口、菜单栏、资源定位
│       ├── Capture/             ← 区域选框与屏幕 OCR
│       ├── Lookup/              ← 分类、AX 取词、协调器、悬停/划词
│       ├── Dictionary/          ← SQLite 词库、StarDict、词素、系统词典桥
│       ├── Notch/               ← 几何、面板状态机、结果与字幕视图
│       ├── Notebook/            ← 笔记本与持久化
│       ├── Onboarding/          ← 首次引导窗口
│       ├── Subtitle/            ← 浏览器字幕桥接与对齐
│       ├── Translate/           ← Apple 本地 / 联网 / 缓存
│       ├── Settings/            ← 偏好与设置窗口
│       └── Support/             ← 热键、权限、钥匙串、日志
└── windows-starter/             ← Windows 原生应用（.NET 8 / WPF）
    ├── Englishwords.sln
    ├── build.ps1                ← 构建、测试与自检
    ├── src/                     ← Englishwords.Core / Englishwords.Win
    └── tests/                   ← 核心逻辑单元测试
```

---

## 1. 它现在能做什么

| 能力 | 状态 |
|---|---|
| 菜单栏常驻、无 Dock 图标、Carbon 全局热键 | ✅ |
| `⌥D` 查词（词典优先）、`⌥T` 直接翻译选中内容 | ✅ |
| 菜单里「自动取词」可分别开关悬停 / 划词 | ✅ |
| 内置词库查词（4.3 万词条）与屈折还原（`abandoning → abandon`） | ✅ |
| 词根词缀拆解 + 词源，三色渲染（`un / believ / able`） | ✅（4,550 语素 / 7,757 拆分词，11,444 考纲词全覆盖） |
| 未命中时回落 macOS 系统词典 | ✅ |
| 单词/短句翻译：Apple 本地优先，联网可选降级 | ✅（需准备语言包 / 配置服务） |
| 刘海面板：紧凑态、悬停展开、离开收起、Esc 关闭、不抢焦点 | ✅ |
| 悬停取词：鼠标停在单词上 0.35s 自动出结果（需辅助功能） | ✅ |
| 划词取词：拖选后自动出结果（只读取 AX 选区；读不到时用 `⌥D`/`⌥T` 走安全剪贴板兜底） | ✅ |
| 区域取词（默认 `⌥R`） | 已实现，需屏幕录制权限 |
| 字幕查询、上下句导航、字幕点词与双语显示 | 已接入，默认关闭，真实站点待验收 |
| 笔记本（收藏、历史、近七天与常查词统计） | 已实现，数据保存在本机 |
| StarDict 导入、词典启用与排序 | 已实现，支持文本释义及压缩正文 |
| 分页设置、快捷键录制、权限中心、翻译服务预设和诊断导出 | 已实现，权限与联网服务待实机验收 |

查词顺序是 **内置词库 → 系统词典 → 翻译**；词素查询独立执行，释义未命中也会显示。
数据库故障与「正常未命中」严格区分：前者在面板上标注降级原因，不会伪装成未收录。

---

## 2. 构建与运行

需要 macOS 15+ 和 Xcode Command Line Tools（本机未装完整 Xcode）。

```bash
cd macos-starter
./build.sh                 # Universal (arm64 + x86_64) + 随包词库
open build/Englishwords.app
```

`build.sh` 会做三件额外的事：检查产物同时包含两种架构、把 SwiftPM 资源包放进
`Contents/Resources`、清空 `EW_DICT/EW_PARTS` 后跑一次真实查词自检。

开发时直接跑（在 `macos-starter/` 下）：

```bash
swift build --disable-sandbox
"$(swift build --disable-sandbox --show-bin-path)/Englishwords"
```

> `--disable-sandbox` 只是绕开本机受限环境里 SwiftPM 清单沙箱的限制；普通终端可省略。
> 路径不要硬编码：Debug 产物位置随 SwiftPM 版本变化，用 `--show-bin-path` 或 `.build/debug/Englishwords` 定位。

### Windows 版构建

```powershell
cd windows-starter
.\build.ps1                     # 单元测试 + 发布 win-x64 + 随包词库自检 + 打 ZIP
.\build.ps1 -SelfContained      # 自带运行时，包体约 +60–70MB
```

默认产出框架依赖包，目标机器需安装 **.NET 8 Desktop Runtime**（Windows Desktop x64）。
两种形态都会把 `LICENSE` 与 `THIRD-PARTY-NOTICES.md` 一起打进输出目录。

### 发版

1. 在 `CHANGELOG.md` 写好对应版本章节，例如 `## [0.5.4]`，和本次改动一起提交。
2. 在仓库根目录运行下面的命令。检查通过后，给该提交打 tag 并推送。

   ```bash
   bash .github/scripts/release-notes.sh 0.5.4 HEAD &&
     git tag v0.5.4 HEAD &&
     git push origin refs/tags/v0.5.4
   ```

3. GitHub Actions 的 Package 会先校验该 tag 上的发布说明，再构建 macOS 和 Windows 安装包。构建成功后在对应 Release 草稿中核对安装包，再手动发布。

补跑时在 **Actions → Package → Run workflow → Use workflow from** 选择对应版本 tag。已有草稿会更新同名附件并保留正文。同一版本公开后，后续打包请使用新版本 tag。

### 自检命令

在 `macos-starter/` 下先定义产物路径，再逐条跑：

```bash
BIN="$(swift build --disable-sandbox --show-bin-path)"

# 取词诊断：授权状态、前台应用、选区可读性、指针取词
"$BIN/Englishwords" --diagnose

# 词库是否随包可用（退出码 0 命中 / 2 未命中 / 3 词库错误）
"$BIN/Englishwords" --check-word unbelievable

# 指针位置能否取到词（AX 坐标，左上原点）
"$BIN/Englishwords" --pick-word 240 116

# 真实 Apple 本地翻译
"$BIN/Englishwords" --translate "The quick brown fox."

# 离屏渲染面板（word / sentence / loading / miss / failure）
"$BIN/Englishwords" --render-preview /tmp/panel.png word

# 启动后立即展示一次查询 / 打开设置窗口，便于截图核对布局
"$BIN/Englishwords" --demo-lookup unbelievable
"$BIN/Englishwords" --demo-settings
```

### 测试

```bash
cd macos-starter
./test.sh
```

测试还覆盖查询取消与超时、字幕断句和中文轨对齐、笔记本持久化、StarDict 来源排序及翻译协议解析。
在同一目录可运行 `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -v`，验证词素构建和抽取。

手动安装请用 `.pkg`：先退出 Englishwords，再按安装器提示操作。每次安装后首次打开时，应用会重置自己的系统隐私授权；同一份包覆盖重装也一样。普通重启和 Sparkle 自动更新不会触发重置。

Sparkle 构建可以用 `EW_ENABLE_SPARKLE=1 ./build.sh` 在本机验证。`release.sh` 分别生成手动安装用的 PKG 和 Sparkle 更新用的 DMG、appcast 条目。发布前需先配置稳定签名身份和 EdDSA 更新密钥。见 [发布签名准备](macos-starter/scripts/make_signing_cert.md)。

---

## 3. 权限与配置

| 项 | 说明 |
|---|---|
| 辅助功能 | 悬停、划词、读取选中文字需要。入口随系统版本变化：**macOS 26 起是「隐私与安全性 → 设备控制和数据访问」**，更早是「隐私与安全性 → 辅助功能」。打开 Englishwords 开关后**退出并重开应用**。未授权时 ⌥D/⌥T 仍可用，但只能读剪贴板，面板会注明「已改用剪贴板」。 |
| 语言包 | Apple 本地翻译需要系统语言包。设置 → 翻译 → 「准备语言包」，在弹出窗口点「开始准备」，由系统下载。 |
| 屏幕录制与自动化 | 区域取词和屏幕字幕需要录屏权限。启用浏览器字幕后，浏览器直读还需要允许 Apple 事件及其 JavaScript。可在设置 → 通用查看状态。 |
| 联网翻译 | 默认关闭。开启后仅在本地不可用或失败时，才把待翻译文本发送到所配置的服务。服务地址、模型存 UserDefaults，密钥只进 Keychain。 |
| 日志 | 只写诊断信息，不包含查询正文、翻译请求内容或密钥。 |

---

## 4. 数据

两个 SQLite 随包分发，也可从公开输入重建（详见 `data/SOURCES.md`）：

| 文件 | 内容 | 来源与许可 |
|---|---|---|
| `dictionary.sqlite` | 43,329 词条 / 29,601 屈折形式 | ECDICT，MIT |
| `wordparts.sqlite` | 4,550 个语素 / 7,757 个拆分词（另含 3,698 个单纯词）的拆分与词源 | 本项目整理，CC BY-SA 4.0 |

```bash
cd macos-starter
python3 scripts/build_dictionary.py --input scripts/.cache/ecdict.csv \
  --output Sources/Englishwords/Resources/dictionary.sqlite
python3 scripts/build_wordparts.py \
  --coverage-db Sources/Englishwords/Resources/dictionary.sqlite \
  --simplex data/simplex.txt \
  --extra data/wordlist-extra.txt
```

脚本会校验完整性、`forms.lemma` 可回溯、`segments` 能拼回原词、语素引用有效；
任一失败非零退出且不覆盖已有文件。七类考试标签与小学补充目标词（合计 **11,444** 词）已由
**7,757 个拆分词 + 3,698 个单纯词** 100% 覆盖；单纯词不写空拆分行，界面只显示释义而不猜拆分。

---

## 5. 取不到词时怎么排查

菜单栏图标 → **取词诊断…**（或 `--diagnose`）会逐项告诉你卡在哪：

| 输出 | 含义与处理 |
|---|---|
| 辅助功能：未授权 | 系统设置 → 隐私与安全性 → **设备控制和数据访问**（macOS 15 及更早叫「辅助功能」），把 Englishwords 的开关打开；不在列表里就点 `+` 选 `.app`，然后**退出重开** |
| 上次取词：未读到选区 | 当前控件不暴露选区。换到可选中文本的应用，或直接用 ⌥T 读剪贴板 |
| 上次取词：未授权…改用剪贴板 | 同上，先授权 |
| 指针处取词：取不到 | 该控件不支持按字符定位（部分 Electron / 画布应用）；用划词或 ⌥T |
| 前台应用：…（被动取词已排除） | 密码管理器等应用在排除名单内，被动取词不生效 |

面板底部的橙色小字也会说明降级原因，例如「没有读到选中文字，已改用剪贴板」。

> 注意：`--diagnose` 从终端运行时，辅助功能状态会**继承终端的授权**，可能显示「已授权」但应用本身其实没有权限。
> 以菜单里的「取词诊断…」（应用自己进程）为准。运行日志在 `~/Library/Logs/Englishwords/app.log`，只记录来源与降级原因，不含查询内容。

---

## 6. 已知边界与未验证项

诚实标注，避免把「能编译」当成「验收通过」：

- **联网翻译未用真实密钥验证**：只验证了请求构造与响应解析逻辑，没有可用凭据，因此没有真实调用记录。
- 本地翻译需要系统语言包；未安装时 `--translate` 会明确提示去「设置 → 翻译 → 准备语言包」，不会伪装成功。
- **多屏 / 无刘海 / Intel 未实机覆盖**：只在当前内置刘海屏（1470×956，刘海 179×32）验证；
  多屏框选、外接屏模拟刘海与 Intel 架构已按屏修复并仅保证构建通过，仍需实机补验。
- **Esc 关闭依赖辅助功能**：全局键盘监听沿用同一授权；未授权时 Esc 不生效。
- **换位置运行或换签名可能需要重新授权**：从 `.pkg` 安装后，首次打开会统一清除本应用的旧授权。直接拖拽 `.app` 不走安装器，换了运行位置或签名后如权限失效，请在系统设置重新授权。
- **被动取词的能力边界**：被动悬停/划词只读 Accessibility，读不到选区的应用（部分 Electron / 画布）需用 `⌥D`/`⌥T` 主动取词。主动热键会在备份并还原剪贴板（带 `TransientType`）的前提下安全模拟复制。
- **词素数据边界**：11,444 考纲词已 100% 判定（7,757 拆分 + 3,698 单纯词），但覆盖范围之外的长尾词仍可能没有拆分；这些词只显示释义，不猜拆分。
- Windows 版需要 .NET 8 Desktop Runtime。可以在 macOS 上交叉编译和运行核心测试，窗口显示、读屏和动画仍需在 Windows 上验收。
- **字幕与发布验收**：真实视频站点、双版本 Sparkle 升级链及签名身份对系统权限（TCC / Keychain / 登录项）的影响待实机验证。
- 查词与字幕使用深色阅读底。macOS 26 及以上的导航和操作按钮采用系统 Liquid Glass，macOS 15 使用系统材质。打开「减少透明度」会切换为实色控件。

---

## 7. 许可

本项目代码基于 [MIT License](LICENSE) 开源。第三方数据与许可见
[THIRD-PARTY-NOTICES.md](macos-starter/Sources/Englishwords/Resources/THIRD-PARTY-NOTICES.md)。

| 数据 / 组件 | 许可 |
|---|---|
| 本项目代码 | MIT |
| ECDICT | MIT |
| 词根词缀整理数据 | CC BY-SA 4.0 |

Dipword 本体是专有软件，其代码、UI 素材、图标均**未**用于本工程。
