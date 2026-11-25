# 更新日志

本项目的所有显著变更都记录在此文件中。

格式依据 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### Added
- 新增项目根目录 `CHANGELOG.md`
- 推送 `v主.次.修订` 版本 tag 后自动触发双端打包，保留手动按 tag 补跑的入口

### Changed
- 打包工作流若未从 tag 运行，或版本号无法解析为严格的 `x.y.z`，直接失败，不再回退到最近的 `v*` tag 继续构建
- 打包前校验 tag 提交中的版本章节，将校验通过的正文用作新建草稿说明。补跑时可更新已有草稿的同名附件

## [0.5.2] - 2026-11-22

本次为双端（macOS + Windows）全量缺陷修复版本，同时修正共享词库与词素数据，并统一双端版本号为 0.5.2。

### Fixed
- 修复屈折还原错误：不再把 806 个常用词查成错词（如 `founded → find`、`roses → rise`、`wounds → wind`）
- 清洗词素数据：修正 440 条错误标签、合并 48 组重复语素、清理 34 条孤立语素，并重建 `wordparts.sqlite`
- macOS：普通鼠标拖拽不再误发 `⌘C`；收紧隐私拦截，避免在密码管理器等应用上悬停取词
- macOS：修复多屏框选、截屏时遮挡自身窗口等问题
- macOS：修复面板 Esc / 塌缩 / 字幕高度、词素折行，以及字幕、翻译、设置持久化与 Keychain 相关问题
- Windows：剪贴板降级取词与 `build.ps1` 自检真正生效
- Windows：修复 StarDict 导入、文本过滤、翻译与笔记本等问题

### Added
- macOS 新增 `.pkg` 安装包
- 打包工作流按 tag 版本将安装包挂到 GitHub Release（已有 Release 只覆盖同名附件）

### Changed
- 清理公开前敏感追踪文件、补充 LICENSE 并更新 README

> Windows 版仍需本机安装 **.NET 8 Desktop Runtime (x64)**；区域取词需启用英语（en-US）OCR 语言包。
> macOS 首次打开若提示无法验证开发者，可在「系统设置 → 隐私与安全性」中允许打开，并重新勾选「辅助功能」等授权。

## [0.1.1] - 2026-11-18

本次发布新增 Windows 10/11 客户端（MVP 预览版），并与 macOS 版共享同一套内置词库与词素拆解数据库。

### Added
- Windows 无焦点双形态面板：支持「顶部可避让模拟刘海」（窗口最大化且鼠标移入顶栏时自动穿透避让，不遮挡浏览器标签页）与「鼠标旁轻量悬浮窗」自由切换
- Windows 多入口取词：支持全局热键（`Alt+D` 查词、`Alt+T` 翻译、`Alt+R` 区域 OCR 截图取词）与鼠标拖选划词（优先 `UIAutomation` 读取，失败时安全降级剪贴板并在 150ms 内还原，自动跳过终端与密码管理器）
- Windows 多源查词与词素拆解：复用内置词库（43,329 词条 / 29,520 屈折形式）与词根词缀库（4,626 语素 / 7,757 拆分词，考纲词 100% 覆盖），支持三色词素展示与 StarDict（`.ifo/.idx(.gz)/.dict(.dz)`）导入排序
- Windows 联网翻译与笔记本：支持 OpenAI 兼容 / Anthropic 等 9 种翻译预设（API 密钥经 Windows DPAPI 加密保存），内置查词历史、收藏与近 7 天统计

### Changed
- macOS 维持 15+ Universal（`arm64` + `x86_64`）构建，同步 `v0.1.0` 以来的词素终审资源与取词稳定性修复

> Windows 版首次打包发布，需本机已安装 **.NET 8 Desktop Runtime (x64)**；区域取词需系统已启用英语（en-US）OCR 语言包。暂不包含鼠标悬停取词与视频双语字幕，后续版本逐步补齐。
> macOS 首次打开若提示无法验证开发者，可在「系统设置 → 隐私与安全性」中允许打开，并在「辅助功能 / 设备控制和数据访问」中重新勾选授权。

## [0.1.0] - 2026-11-18

macOS 应用首次发布。

### Added
- macOS「刘海查词 + 翻译」：菜单栏常驻、全局热键（`⌥D` 查词、`⌥T` 直接翻译）、悬停/划词取词、刘海面板
- 内置词库查词与屈折还原，词根词缀拆解，未命中时回落系统词典；Apple 本地翻译优先，可选联网降级
- M5.5 及后续能力：标识迁移、热键、词素、区域取词（默认 `⌥R`），以及字幕查询、笔记本、StarDict 导入、设置与引导
- GitHub Actions 手动打包工作流与安装说明

### Fixed
- 取词链路：`⌥T` 跳过词典直接翻译、选区复制兜底、取词诊断与日志
- 修复取词、翻译取消与密钥保存缺陷
- 修正自动化权限状态码类型，消除 `AXPicker.describe` 中 bounds 命名歧义

[Unreleased]: https://github.com/shenziggy0/notchword/compare/v0.5.2...HEAD
[0.5.2]: https://github.com/shenziggy0/notchword/compare/v0.1.1...v0.5.2
[0.1.1]: https://github.com/shenziggy0/notchword/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/shenziggy0/notchword/releases/tag/v0.1.0
