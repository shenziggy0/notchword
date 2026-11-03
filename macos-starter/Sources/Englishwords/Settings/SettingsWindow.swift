import AppKit
import SwiftUI
import Translation

// MARK: - 窗口

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    private let preferences: Preferences
    private let translator: TranslationCoordinator
    private let model = SettingsModel()

    private var window: NSWindow?
    private var languageWindow: NSWindow?

    init(preferences: Preferences, translator: TranslationCoordinator) {
        self.preferences = preferences
        self.translator = translator
        super.init()
    }

    func show() {
        if window == nil {
            let view = SettingsView(preferences: preferences, model: model) { [weak self] in
                self?.showLanguagePack()
            }
            let controller = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: controller)
            window.title = "Englishwords 设置"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 540, height: 580))
            window.center()
            window.delegate = self
            self.window = window
        }
        focus(window)
        model.refresh(translator: translator)
    }

    func showLanguagePack() {
        if languageWindow == nil {
            let model = LanguagePackModel()
            let controller = NSHostingController(rootView: LanguagePackView(model: model))
            let window = NSWindow(contentViewController: controller)
            window.title = "准备语言包"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 420, height: 220))
            window.center()
            window.delegate = self
            self.languageWindow = window
        }
        focus(languageWindow)
    }

    /// 菜单栏应用默认没有 Dock 图标，主动打开窗口时临时切成普通应用才能拿到焦点。
    private func focus(_ window: NSWindow?) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        let closesSettings = (notification.object as? NSWindow) === window
        let closesLanguage = (notification.object as? NSWindow) === languageWindow
        guard closesSettings || closesLanguage else { return }

        let settingsOpen = window?.isVisible ?? false
        let languageOpen = languageWindow?.isVisible ?? false
        if !settingsOpen, !languageOpen {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - 设置模型

@MainActor
final class SettingsModel: ObservableObject {

    @Published var apiKeyInput = ""
    @Published var keyMessage = ""
    @Published var localStatus = "检测中…"
    @Published var onlineStatus = ""

    func refresh(translator: TranslationCoordinator) {
        keyMessage = SecretStore.hasSecret(account: OpenAICompatProvider.account)
            ? "已保存（不回显）"
            : "尚未保存"

        switch translator.onlineAvailability() {
        case .disabled:            onlineStatus = "联网翻译已关闭"
        case .missingCredentials:  onlineStatus = "配置不完整：检查地址、模型与密钥"
        case .ready:               onlineStatus = "配置完整"
        }

        Task { await checkLocalAvailability() }
    }

    func saveKey() {
        switch SecretStore.save(apiKeyInput, account: OpenAICompatProvider.account) {
        case .success:
            apiKeyInput = ""
            keyMessage = "已保存到钥匙串"
        case .failure(let error):
            keyMessage = error.localizedDescription
        }
    }

    func clearKey() {
        switch SecretStore.delete(account: OpenAICompatProvider.account) {
        case .success:           keyMessage = "已删除"
        case .failure(let error): keyMessage = error.localizedDescription
        }
    }

    private func checkLocalAvailability() async {
        let source = Locale.Language(identifier: "en")
        let target = Locale.Language(identifier: "zh-Hans")
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed: localStatus = "语言包已安装，可离线翻译"
        case .supported: localStatus = "需要准备语言包"
        default:         localStatus = "当前系统不支持英译中"
        }
    }
}

// MARK: - 设置界面

struct SettingsView: View {

    @ObservedObject var preferences: Preferences
    @ObservedObject var model: SettingsModel
    var onPrepareLanguage: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                automaticSection
                panelSection
                translationSection
                Text("查词与翻译默认在本机完成；运行日志不包含查询内容。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .frame(width: 540)
    }

    private var automaticSection: some View {
        GroupBox("自动取词") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("悬停取词", isOn: binding(\.hoverEnabled))
                Toggle("划词取词", isOn: binding(\.selectionEnabled))

                HStack(spacing: 10) {
                    Text("停留时长")
                        .frame(width: 72, alignment: .leading)
                    Slider(value: binding(\.hoverDwellSeconds), in: 0.15...1.5, step: 0.05)
                    Text(String(format: "%.2f s", preferences.hoverDwell))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                }

                Toggle("词根词缀", isOn: binding(\.showWordParts))
            }
            .padding(8)
        }
    }

    private var panelSection: some View {
        GroupBox("结果面板") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("鼠标移入时展开", isOn: binding(\.expandsOnHover))

                HStack(spacing: 10) {
                    Text("停留时间")
                        .frame(width: 72, alignment: .leading)
                    Slider(value: binding(\.autoHideSeconds), in: 2...15, step: 0.5)
                    Text(String(format: "%.1f s", preferences.autoHideInterval))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                }

                Text("指针进入面板会暂停计时，离开后重新计时；Esc 关闭。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    private var translationSection: some View {
        GroupBox("翻译") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("本地翻译：\(model.localStatus)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("准备语言包", action: onPrepareLanguage)
                }

                Divider()

                Toggle("本地不可用时允许联网翻译", isOn: binding(\.onlineEnabled))

                HStack(spacing: 10) {
                    Text("服务地址").frame(width: 72, alignment: .leading)
                    TextField("https://api.openai.com/v1", text: binding(\.baseURL))
                        .textFieldStyle(.roundedBorder)
                }
                HStack(spacing: 10) {
                    Text("模型").frame(width: 72, alignment: .leading)
                    TextField("gpt-4o-mini", text: binding(\.model))
                        .textFieldStyle(.roundedBorder)
                }
                HStack(spacing: 10) {
                    Text("API 密钥").frame(width: 72, alignment: .leading)
                    SecureField("只保存到钥匙串", text: $model.apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                    Button("保存") { model.saveKey() }
                    Button("清除") { model.clearKey() }
                }

                Text("\(model.onlineStatus) · 密钥\(model.keyMessage)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    private func binding<T>(_ keyPath: ReferenceWritableKeyPath<Preferences, T>) -> Binding<T> {
        Binding(
            get: { preferences[keyPath: keyPath] },
            set: { preferences[keyPath: keyPath] = $0 }
        )
    }
}

// MARK: - 语言包

@MainActor
final class LanguagePackModel: ObservableObject {

    @Published var configuration: TranslationSession.Configuration?
    @Published var status = "语言包由系统下载，需要联网。"
    @Published var isPreparing = false

    func start() {
        isPreparing = true
        status = "正在准备，请在系统提示中确认…"
        configuration = TranslationSession.Configuration(
            source: Locale.Language(identifier: "en"),
            target: Locale.Language(identifier: "zh-Hans")
        )
    }

    func finish(_ error: Error?) {
        isPreparing = false
        if let error {
            status = "准备失败：\(error.localizedDescription)"
        } else {
            status = "语言包已就绪，可以离线翻译。"
        }
        configuration = nil
    }
}

struct LanguagePackView: View {

    @ObservedObject var model: LanguagePackModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("英译中语言包")
                .font(.headline)
            Text(model.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(model.isPreparing ? "准备中…" : "开始准备") { model.start() }
                    .disabled(model.isPreparing)
            }
        }
        .padding(24)
        .frame(width: 420, height: 220, alignment: .topLeading)
        .translationTask(model.configuration) { session in
            do {
                try await session.prepareTranslation()
                model.finish(nil)
            } catch {
                model.finish(error)
            }
        }
    }
}
