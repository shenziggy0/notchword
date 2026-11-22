import AppKit
import SwiftUI

@MainActor
final class OnboardingWindow: NSObject, NSWindowDelegate, ObservableObject {
    @Published private(set) var step = 0
    private let preferences: Preferences
    private var window: NSWindow?

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    func show() {
        if window == nil {
            let view = OnboardingView(controller: self, preferences: preferences)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "开始使用 Englishwords"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 440, height: 238))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        step = 0
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func next() {
        if step < 2 { step += 1 }
        else { finish() }
    }

    func finish() {
        preferences.sawOnboarding = true
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        preferences.sawOnboarding = true
        let closing = notification.object as? NSWindow
        // 断开 controller ↔ window ↔ hosting view 的引用环
        if closing === window { window = nil }
        if !NSApp.windows.contains(where: {
            $0 !== closing && ($0.isVisible || $0.isMiniaturized) && $0.styleMask.contains(.titled)
        }) {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

private struct OnboardingView: View {
    @ObservedObject var controller: OnboardingWindow
    @ObservedObject var preferences: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(["从选中文字开始", "允许辅助功能", "识别图片与字幕"][controller.step])
                .font(.title2.bold())
            Group {
                switch controller.step {
                case 0:
                    Text("选中英文后，按 \(preferences.lookupHotKey.display) 查词，或按 \(preferences.translateHotKey.display) 翻译。你也可以从菜单栏查剪贴板。")
                case 1:
                    Text("辅助功能权限用于悬停、划词和读取选区。你也可以稍后从设置授予。")
                    Button("打开辅助功能设置") {
                        _ = Permissions.ensureAccessibility(prompt: true)
                        Permissions.openAccessibilitySettings()
                    }
                default:
                    Text("按 \(preferences.regionHotKey.display) 可以框选屏幕。要从浏览器查字幕，请在设置中启用字幕并允许浏览器接收 Apple 事件。")
                    Text("屏幕录制和浏览器自动化将在使用时申请。").foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack {
                Button("稍后") { controller.finish() }
                Spacer()
                Button(controller.step == 2 ? "完成" : "继续") { controller.next() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}
