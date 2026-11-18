import AppKit
import ApplicationServices
import CoreGraphics

enum Permissions {

    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func ensureAccessibility(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted { FileLog.write("辅助功能未授权") }
        return trusted
    }

    /// 系统设置里授权入口的名字随版本变：macOS 26 起叫「设备控制和数据访问」。
    static var settingsHint: String {
        if #available(macOS 26.0, *) {
            return "系统设置 → 隐私与安全性 → 设备控制和数据访问"
        }
        return "系统设置 → 隐私与安全性 → 辅助功能"
    }

    static func openAccessibilitySettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static var isScreenCaptureGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// 弹出系统的屏幕录制授权。不会在启动时调用。
    @discardableResult
    static func requestScreenCapture() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        if !granted { FileLog.write("屏幕录制未授权") }
        return granted
    }

    static func openScreenCaptureSettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    /// 查询对某个应用的自动化权限，不弹窗。
    static func automationStatus(bundleID: String) -> AutomationStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let descriptor = target.aeDesc else { return .unknown }
        let status = AEDeterminePermissionToAutomateTarget(descriptor, typeWildCard, typeWildCard, false)
        // errAEEvent* 在当前 SDK 里是 Int，OSStatus 是 Int32，直接匹配编不过。
        switch status {
        case noErr:
            return .allowed
        case OSStatus(errAEEventNotPermitted):
            return .denied
        case OSStatus(errAEEventWouldRequireUserConsent):
            return .notDetermined
        default:
            return .unknown
        }
    }

    private static func openSettings(_ value: String) {
        guard let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }
}

enum AutomationStatus {
    case allowed
    case denied
    case notDetermined
    case unknown
}

/// 被动取词的应用排除规则：密码管理器内不取词。
enum AppRules {

    static let excludedBundleIDs: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.dashlane.Dashlane",
        "com.lastpass.LastPass",
        "com.apple.Passwords",
        "com.apple.keychainaccess"
    ]

    static var frontmostBundleID: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// 前台是不是密码管理器（模拟复制时要避开，避免把密码写进剪贴板）。
    static var isFrontmostExcluded: Bool {
        guard let bundleID = frontmostBundleID else { return false }
        return excludedBundleIDs.contains(bundleID)
    }

    private static func isExcluded(_ bundleID: String) -> Bool {
        excludedBundleIDs.contains(bundleID)
            || UserDefaults.standard.stringArray(forKey: "apprules.userExcluded")?.contains(bundleID) == true
    }

    /// 被动入口是否应当放行。自己的应用、密码管理器都不取词。
    static func allowsPassiveLookup() -> Bool {
        guard let bundleID = frontmostBundleID else { return true }
        if bundleID == Bundle.main.bundleIdentifier { return false }
        return !isExcluded(bundleID)
    }
}

enum Screens {

    /// 指针所在的屏幕；找不到时退回主屏。
    static func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// 当前鼠标位置（AppKit 全局坐标）。
    static var mouseLocation: NSPoint { NSEvent.mouseLocation }

    /// AppKit 全局坐标（左下原点）→ Accessibility 坐标（左上原点，主屏）。
    static func accessibilityPoint(from point: NSPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: point.x, y: primaryHeight - point.y)
    }
}
