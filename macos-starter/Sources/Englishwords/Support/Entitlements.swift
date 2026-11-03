import Foundation

/// 付费能力（M8 商业化预留）。
///
/// 收费范围见 [0002 设计方案](../../../docs/design/0002-商业化与授权实施方案.md)：
/// 只有下面三项属于 Pro，其余能力（查词、词典、Apple 本地翻译、朗读、收藏、设置）永久免费。
enum ProFeature: String, CaseIterable, Sendable {

    /// 字幕查询：浏览器字幕直读与屏幕 OCR。
    case subtitles

    /// 拆分词根词缀。
    case wordParts

    /// 接入自己的 AI 翻译（联网 provider）。
    /// Apple 本地整句翻译不属于 Pro。
    case aiTranslation
}

/// 商业能力的**唯一判断源**。
///
/// 现在（M8 之前）三项全部放开：`allows(_:)` 恒返回 `true`，
/// 与本文件引入之前的行为完全一致。M8 才改写实现去读本地许可证，
/// 调用点不需要改动。
///
/// 三条硬约束（摘自 0002 设计方案 §5.3）：
///
/// 1. 视图里不要直接判断商业状态，只调用 `allows(_:)`；
/// 2. 判断必须放在结果组装**之后**——任何 `false` 分支都不得影响查词、释义与 Apple 本地翻译；
/// 3. 判断不得抛错、不得联网、不得阻塞；失败一律按"不阻断"处理。
///
/// 用法：
///
/// ```swift
/// if Entitlements.allows(.wordParts) {
///     WordPartsDetail(segments: entry.segments)
/// } else {
///     LockedRow(title: "拆分词根词缀")
/// }
/// ```
enum Entitlements {

    /// 是否已启用收费判定。
    ///
    /// M8 之前恒为 `false`：界面不应出现任何"Pro / 升级 / 购买"入口，
    /// 也不应给三项能力加锁形标记。M8 时改为读取 `pro.enforced` 偏好。
    static var isEnforced: Bool { false }

    /// 当前是否允许使用某项能力。
    ///
    /// M8 之前恒为 `true`。M8 改为读取本地许可证的离线验签结果。
    /// 实现时保持纯函数性质：不发起网络请求、不弹窗、不阻塞调用线程。
    static func allows(_ feature: ProFeature) -> Bool {
        _ = feature
        return true
    }
}
