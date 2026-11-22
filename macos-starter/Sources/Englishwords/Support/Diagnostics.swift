import AppKit

/// 取词诊断：只报告状态，不输出选中的内容。
///
/// 用来回答「为什么选中了却没有反应」——是没授权、前台应用被排除，
/// 还是当前控件不暴露选区 / 指针下的文字。
enum Diagnostics {

    @MainActor
    static func report(lastLookup: String? = nil) -> String {
        var lines: [String] = []

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        lines.append("版本：\(version)（\(build)）")
        let permissionLine = Permissions.isAccessibilityTrusted
            ? "已授权"
            : "未授权（授权位置：\(Permissions.settingsHint)）"
        lines.append("辅助功能：\(permissionLine)")

        let frontmost = AppRules.frontmostBundleID ?? "未知"
        let passiveAllowed = AppRules.allowsPassiveLookup()
        let isSelf = frontmost == Bundle.main.bundleIdentifier
        if isSelf {
            lines.append("前台应用：\(frontmost)（本应用）")
        } else {
            lines.append("前台应用：\(frontmost)\(passiveAllowed ? "" : "（已被排除，不取词）")")
        }

        if let lastLookup {
            lines.append("上次取词：\(lastLookup)")
        }

        // 打开菜单/弹窗后前台会变成自己，此时再读焦点元素没有意义
        if passiveAllowed {
            if let role = AXPicker.focusedRole() {
                let readable = AXPicker.selectedText() != nil
                lines.append("当前焦点：\(role)；选区：\(readable ? "可读" : "空或不可读")")
            }
        } else {
            lines.append("当前焦点：本应用在前台，选区结果请看「上次取词」")
        }

        let axPoint = Screens.accessibilityPoint(from: NSEvent.mouseLocation)
        lines.append("指针处取词：\(AXPicker.word(at: axPoint) == nil ? "取不到" : "可用")")

        let preferences = Preferences.shared
        lines.append("开关：悬停 \(preferences.hoverEnabled ? "开" : "关")，划词 \(preferences.selectionEnabled ? "开" : "关")")
        lines.append("日志：\(FileLog.logPath)")
        return lines.joined(separator: "\n")
    }
}
