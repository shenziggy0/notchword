import AppKit
import SwiftUI

@MainActor
final class OnboardingWindow: NSObject, NSWindowDelegate, ObservableObject {
    @Published private(set) var step = 0
    @Published private(set) var exampleFeedback = ""
    private let preferences: Preferences
    private var window: NSWindow?
    var lookupExample: (() -> Void)?

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    func show() {
        if window == nil {
            let view = OnboardingView(controller: self, preferences: preferences)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view.lexiconPage()))
            window.title = "开始使用 Englishwords"
            window.styleMask = [.titled, .closable]
            window.tabbingMode = .disallowed
            window.setContentSize(NSSize(width: 474, height: 376))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        step = 0
        exampleFeedback = ""
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func showExampleResult(_ state: LookupState) {
        switch state {
        case .loading:
            exampleFeedback = "正在查词…"
        case .result(_, let result):
            exampleFeedback = result.body.components(separatedBy: "\n").first ?? result.body
        case .miss:
            exampleFeedback = "随包词库缺少示例词。"
        case .failure(_, let detail):
            exampleFeedback = detail
        }
    }

    func next() {
        if step < 2 { step += 1 }
        else { finish() }
    }

    func previous() {
        if step > 0 { step -= 1 }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                HStack(spacing: 5) {
                    ForEach(0..<3) { index in
                        Capsule()
                            .fill(index <= controller.step ? Lexicon.accent : Lexicon.hairline)
                            .frame(width: index == controller.step ? 25 : 10, height: 5)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("使用引导")
                .accessibilityValue("第 \(controller.step + 1) 步，共 3 步")
                Spacer()
                Button("稍后") { controller.finish() }
                    .buttonStyle(.borderless).keyboardShortcut(.cancelAction)
            }
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: ["text.cursor", "hand.raised", "viewfinder"][controller.step])
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Lexicon.accent)
                    .frame(width: 50, height: 50)
                    .background(Lexicon.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 15))
                    .accessibilityHidden(true)
                Text(["查第一个单词", "允许辅助功能", "识别图片与字幕"][controller.step])
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                switch controller.step {
                case 0:
                    (Text("The villagers foiled an attempt to ") +
                     Text("abduct").foregroundColor(Lexicon.accent).bold() +
                     Text(" the young prince."))
                    Button("查 abduct") { controller.lookupExample?() }
                        .buttonStyle(.borderedProminent)
                    if !controller.exampleFeedback.isEmpty {
                        Text(controller.exampleFeedback).font(.callout)
                            .accessibilityLabel("查词结果，\(controller.exampleFeedback)")
                    }
                    Text("在其他应用里选中英文，再按快捷键。")
                        .foregroundStyle(Lexicon.secondary)
                    HStack(spacing: 10) {
                        shortcut("查词", keys: preferences.lookupHotKey.display)
                        shortcut("翻译", keys: preferences.translateHotKey.display)
                    }
                case 1:
                    Text("授权后，鼠标停在单词上或划选英文即可取词。也可以稍后从设置授予。")
                        .foregroundStyle(Lexicon.secondary)
                    Button("打开辅助功能设置") {
                        _ = Permissions.ensureAccessibility(prompt: true)
                        Permissions.openAccessibilitySettings()
                    }
                    .controlSize(.large)
                default:
                    Text("按 \(preferences.regionHotKey.display) 框选屏幕取词。查看浏览器字幕前，请在设置中启用字幕并允许浏览器自动化。")
                        .foregroundStyle(Lexicon.secondary)
                    Text("首次使用时，系统会申请屏幕录制或自动化权限。")
                        .font(.callout).foregroundStyle(Lexicon.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(controller.step)
            .transition(reduceMotion ? .identity : .opacity)
            Spacer(minLength: 0)
            HStack {
                if controller.step > 0 {
                    Button { advance(controller.previous) } label: {
                        Label("上一步", systemImage: "chevron.backward")
                    }
                    .buttonStyle(.borderless)
                }
                Spacer()
                Button(controller.step == 2 ? "完成" : "继续") { advance(controller.next) }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
    }

    private func advance(_ action: () -> Void) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.24)) { action() }
    }

    private func shortcut(_ label: String, keys: String) -> some View {
        HStack {
            Text(label).font(.callout)
            Spacer()
            Text(keys).font(.system(.body, design: .monospaced, weight: .semibold))
        }
        .padding(.horizontal, 13).frame(minHeight: 38)
        .background(Lexicon.surface, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}
