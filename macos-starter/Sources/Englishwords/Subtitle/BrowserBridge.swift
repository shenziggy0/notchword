import AppKit
import Foundation

struct BrowserBridge {
    static let chromium: Set<String> = [
        "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser"
    ]
    static let safari = "com.apple.Safari"
    static let firefox = "org.mozilla.firefox"

    private static let queue = DispatchQueue(label: "io.github.shenziggy0.notchword.browser")

    static func supports(_ bundleID: String) -> Bool {
        chromium.contains(bundleID) || bundleID == safari || bundleID == firefox
    }

    func run(_ javascript: String, in bundleID: String) async throws -> String {
        let escaped = javascript.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let command: String
        if Self.chromium.contains(bundleID) {
            command = "execute active tab of front window javascript \"\(escaped)\""
        } else if bundleID == Self.safari {
            command = "do JavaScript \"\(escaped)\" in current tab of front window"
        } else {
            throw BrowserBridgeError.unsupported
        }

        // NSAppleScript is main-thread only. The system interpreter keeps browser
        // timeouts and automation prompts off the app's UI thread.
        let script = """
        with timeout of 5 seconds
            tell application id "\(bundleID)"
                if (count of windows) = 0 then error "No browser window" number -1728
                \(command)
            end tell
        end timeout
        """
        return try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-l", "AppleScript", "-e", script]
                let output = Pipe()
                process.standardOutput = output
                process.standardError = output
                do {
                    try process.run()
                    let watchdog = DispatchWorkItem {
                        if process.isRunning { process.terminate() }
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
                    defer { watchdog.cancel() }
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    if process.terminationStatus == 0, !value.isEmpty {
                        continuation.resume(returning: value)
                    } else if value.contains("(-1743)") {
                        continuation.resume(throwing: BrowserBridgeError.permission)
                    } else if value.contains("(-1728)") {
                        continuation.resume(throwing: BrowserBridgeError.noWindow)
                    } else {
                        continuation.resume(throwing: BrowserBridgeError.scriptUnavailable)
                    }
                } catch {
                    continuation.resume(throwing: BrowserBridgeError.scriptUnavailable)
                }
            }
        }
    }
}

private enum BrowserBridgeError: LocalizedError {
    case unsupported, permission, noWindow, scriptUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupported: return "此浏览器使用屏幕字幕识别。"
        case .permission: return "请在系统设置的「自动化」中允许 Englishwords 控制浏览器。"
        case .noWindow: return "请先在浏览器中打开视频。"
        case .scriptUnavailable: return "无法读取网页字幕，请检查浏览器是否允许来自 Apple 事件的 JavaScript。"
        }
    }
}
