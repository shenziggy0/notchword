import AppKit
import SwiftUI
import Translation
import UniformTypeIdentifiers
import AVFoundation
import ServiceManagement

// MARK: - 窗口

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    private let preferences: Preferences
    private let translator: TranslationCoordinator
    private let model = SettingsModel()
    private let hotkeyRecorder = HotKeyRecorder()
    var showOnboarding: (() -> Void)?

    private var window: NSWindow?
    private var languageWindow: NSWindow?

    init(preferences: Preferences, translator: TranslationCoordinator) {
        self.preferences = preferences
        self.translator = translator
        super.init()
    }

    func show() {
        if window == nil {
            let view = SettingsView(preferences: preferences, model: model, translator: translator,
                                    recorder: hotkeyRecorder, onPrepareLanguage: { [weak self] in
                self?.showLanguagePack()
            }, onOnboarding: { [weak self] in self?.showOnboarding?() })
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
        model.refresh(translator: translator, preset: preferences.translationPreset)
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

    func windowDidBecomeKey(_ notification: Notification) {
        if (notification.object as? NSWindow) === window { model.refreshSystemStatus() }
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
        if closesSettings { hotkeyRecorder.cancel() }

        if !NSApp.windows.contains(where: {
            $0 !== (notification.object as? NSWindow) && $0.isVisible && $0.styleMask.contains(.titled)
        }) {
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
    @Published var dictionaryMessage = ""
    @Published var dictionaryBusy = false
    @Published var onlineMessage = ""
    @Published var modelChoices: [String] = []
    @Published var serviceBusy = false
    @Published var accessibility = false
    @Published var screenCapture = false
    @Published var automation = "尚无运行中的支持浏览器"
    @Published var loginEnabled = false
    @Published var loginMessage = ""
    @Published var diagnosticsMessage = ""

    func refresh(translator: TranslationCoordinator, preset: ProviderPreset) {
        refreshKey(preset: preset)
        refreshOnlineStatus(translator: translator)
        Task { await checkLocalAvailability() }
    }

    func refreshKey(preset: ProviderPreset) {
        keyMessage = SecretStore.hasSecret(account: preset.rawValue)
            ? "已保存（不回显）"
            : "尚未保存"
    }

    func refreshOnlineStatus(translator: TranslationCoordinator) {
        switch translator.onlineAvailability() {
        case .disabled:            onlineStatus = "联网翻译已关闭"
        case .missingCredentials:  onlineStatus = "配置不完整：检查地址、模型与密钥"
        case .ready:               onlineStatus = "配置完整"
        }
    }

    func saveKey(preset: ProviderPreset) {
        switch SecretStore.save(apiKeyInput, account: preset.rawValue) {
        case .success:
            apiKeyInput = ""
            keyMessage = "已保存到钥匙串"
        case .failure(let error):
            keyMessage = error.localizedDescription
        }
    }

    func clearKey(preset: ProviderPreset) {
        switch SecretStore.delete(account: preset.rawValue) {
        case .success:           keyMessage = "已删除"
        case .failure(let error): keyMessage = error.localizedDescription
        }
    }

    func checkOnline(translator: TranslationCoordinator, preferences: Preferences, listModels: Bool) {
        let preset = preferences.translationPreset
        let address = preferences.onlineAddress
        serviceBusy = true
        onlineMessage = listModels ? "正在获取模型…" : "正在测试服务…"
        Task {
            defer { serviceBusy = false }
            do {
                if listModels {
                    let choices = try await translator.listModels()
                    guard preferences.translationPreset == preset, preferences.onlineAddress == address else { return }
                    modelChoices = choices
                    onlineMessage = choices.isEmpty ? "该端点没有返回模型，可手动输入。" : "已获取 \(choices.count) 个模型。"
                } else {
                    let result = try await translator.testOnlineTranslation()
                    guard preferences.translationPreset == preset else { return }
                    onlineMessage = "测试通过：\(result.text)"
                }
            } catch {
                if preferences.translationPreset == preset { onlineMessage = error.localizedDescription }
            }
        }
    }

    func refreshSystemStatus() {
        accessibility = Permissions.isAccessibilityTrusted
        screenCapture = Permissions.isScreenCaptureGranted
        let browsers = NSWorkspace.shared.runningApplications.filter {
            guard let id = $0.bundleIdentifier else { return false }
            return BrowserBridge.chromium.contains(id) || id == BrowserBridge.safari
        }
        automation = browsers.compactMap { browser in
            guard let id = browser.bundleIdentifier else { return nil }
            let label: String
            switch Permissions.automationStatus(bundleID: id) {
            case .allowed: label = "已允许"
            case .denied: label = "未允许"
            case .notDetermined: label = "尚未申请"
            case .unknown: label = "状态未知"
            }
            return "\(browser.localizedName ?? id) \(label)"
        }.joined(separator: "、")
        if automation.isEmpty { automation = "尚无运行中的支持浏览器" }
        loginEnabled = SMAppService.mainApp.status == .enabled
        if SMAppService.mainApp.status == .requiresApproval {
            loginMessage = "请在系统设置的登录项中允许 Englishwords。"
        }
    }

    func changeLoginItem(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginMessage = ""
        } catch {
            loginMessage = error.localizedDescription
        }
        refreshSystemStatus()
    }

    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Englishwords-诊断.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let report = Diagnostics.report()
            try "\(report)\n屏幕录制：\(screenCapture ? "已允许" : "未允许")\n自动化：\(automation)\n"
                .write(to: url, atomically: true, encoding: .utf8)
            diagnosticsMessage = "已导出诊断。"
        } catch {
            diagnosticsMessage = error.localizedDescription
        }
    }

    func importDictionary(into preferences: Preferences) {
        let picker = NSOpenPanel()
        picker.title = "导入 StarDict"
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        picker.allowedContentTypes = [UTType(filenameExtension: "ifo") ?? .data]
        guard picker.runModal() == .OK, let url = picker.url else { return }
        dictionaryBusy = true
        dictionaryMessage = "正在导入…"
        Task {
            defer { dictionaryBusy = false }
            do {
                let source = try await StarDictLibrary.shared.importDictionary(from: url)
                preferences.dictionarySources.append(source)
                dictionaryMessage = "已导入 \(source.name)"
            } catch {
                dictionaryMessage = error.localizedDescription
            }
        }
    }

    func removeDictionary(_ source: DictionarySource, from preferences: Preferences) {
        dictionaryBusy = true
        Task {
            defer { dictionaryBusy = false }
            do {
                try await StarDictLibrary.shared.remove(source)
                preferences.dictionarySources.removeAll { $0.id == source.id }
                dictionaryMessage = "已移除 \(source.name)"
            } catch {
                dictionaryMessage = error.localizedDescription
            }
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
    let translator: TranslationCoordinator
    @ObservedObject var recorder: HotKeyRecorder
    var onPrepareLanguage: () -> Void
    var onOnboarding: () -> Void

    private func refreshOnlineStatus() {
        model.refreshOnlineStatus(translator: translator)
    }

    private enum TranslationField: Hashable { case address, model }
    @FocusState private var translationField: TranslationField?

    var body: some View {
        TabView {
            page { generalSection; panelSection }.tabItem { Text("通用") }
            page { automaticSection; hotkeySection }.tabItem { Text("取词") }
            page { dictionarySection }.tabItem { Text("词典") }
            page { translationSection }.tabItem { Text("翻译") }
            page { subtitleSection }.tabItem { Text("字幕") }
            page { speechSection }.tabItem { Text("朗读") }
            page { appRulesSection }.tabItem { Text("应用规则") }
            page { aboutSection }.tabItem { Text("关于") }
        }
        .frame(width: 540)
        .onChange(of: translationField) { previous, _ in
            if previous != nil { refreshOnlineStatus() }
        }
    }

    private func page<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14, content: content)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var generalSection: some View {
        GroupBox("系统与权限") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("登录后启动", isOn: Binding(get: { model.loginEnabled }, set: model.changeLoginItem))
                if !model.loginMessage.isEmpty {
                    Text(model.loginMessage).font(.caption).foregroundStyle(.secondary)
                    Button("打开登录项设置") { SMAppService.openSystemSettingsLoginItems() }
                }
                Divider()
                permissionRow("辅助功能", state: model.accessibility ? "已允许" : "未允许") {
                    _ = Permissions.ensureAccessibility(prompt: true)
                    Permissions.openAccessibilitySettings()
                }
                permissionRow("屏幕录制", state: model.screenCapture ? "已允许" : "未允许") {
                    _ = Permissions.requestScreenCapture()
                    Permissions.openScreenCaptureSettings()
                }
                permissionRow("自动化", state: model.automation) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("刷新权限") { model.refreshSystemStatus() }
            }
            .padding(8)
        }
    }

    private func permissionRow(_ label: String, state: String, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                Text(state).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("打开设置", action: action).accessibilityLabel("打开\(label)设置")
        }
    }

    private var hotkeys: [(String, ReferenceWritableKeyPath<Preferences, HotKeySpec>)] {
        [("查词", \.lookupHotKey), ("翻译", \.translateHotKey), ("区域取词", \.regionHotKey),
         ("查看字幕", \.subtitleHotKey), ("上一句", \.previousSubtitleHotKey), ("下一句", \.nextSubtitleHotKey)]
    }

    private var hotkeySection: some View {
        GroupBox("快捷键") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("启用区域取词", isOn: binding(\.regionLookupEnabled))
                ForEach(hotkeys.indices, id: \.self) { index in
                    let (label, keyPath) = hotkeys[index]
                    LabeledContent(label) {
                        Button(recorder.recording == label ? "请按键…" : preferences[keyPath: keyPath].display) {
                            recorder.begin(name: label, current: {
                                hotkeys.filter { $0.1 != keyPath }.map { preferences[keyPath: $0.1] }
                            }) { preferences[keyPath: keyPath] = $0 }
                        }
                    }
                }
                if !recorder.message.isEmpty {
                    Text(recorder.message).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(8)
        }
    }

    private var speechSection: some View {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
            .sorted { $0.name < $1.name }
        return GroupBox("朗读") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("英语声音", selection: binding(\.speechVoice)) {
                    Text("系统默认").tag("")
                    ForEach(voices, id: \.identifier) { voice in Text(voice.name).tag(voice.identifier) }
                }
                Slider(value: binding(\.speechRate), in: 0.15...0.65) { Text("语速") }
                Button("播放示例") {
                    Speaker.shared.speak("This is a test.", voiceID: preferences.speechVoice, rate: preferences.speechRate)
                }
            }
            .padding(8)
        }
    }

    private var appRulesSection: some View {
        let running = NSWorkspace.shared.runningApplications.filter {
            guard let id = $0.bundleIdentifier else { return false }
            return $0.activationPolicy == .regular && id != Bundle.main.bundleIdentifier
                && !AppRules.excludedBundleIDs.contains(id) && !preferences.userExcluded.contains(id)
        }.reduce(into: [String: String]()) { result, app in
            if let id = app.bundleIdentifier { result[id] = app.localizedName ?? id }
        }
        return GroupBox("自动取词排除") {
            VStack(alignment: .leading, spacing: 10) {
                Menu("添加运行中的应用") {
                    ForEach(running.keys.sorted(), id: \.self) { id in
                        Button(running[id] ?? id) { preferences.userExcluded.append(id) }
                    }
                }
                .disabled(running.isEmpty)
                ForEach(preferences.userExcluded, id: \.self) { id in
                    LabeledContent(id) {
                        Button("移除") { preferences.userExcluded.removeAll { $0 == id } }
                    }
                }
                DisclosureGroup("默认排除的密码管理器") {
                    ForEach(AppRules.excludedBundleIDs.sorted(), id: \.self) { id in
                        Text(id).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(8)
        }
    }

    private var aboutSection: some View {
        GroupBox("Englishwords") {
            VStack(alignment: .leading, spacing: 10) {
                Text("版本 " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发构建"))
                Button("使用引导", action: onOnboarding)
                Button("第三方许可") {
                    if let url = AppResources.noticesURL() { NSWorkspace.shared.open(url) }
                }
                Button("导出诊断…") { model.exportDiagnostics() }
                if !model.diagnosticsMessage.isEmpty { Text(model.diagnosticsMessage).font(.caption) }
                Text("查询默认在本机处理。导出的诊断包含权限、版本和开关状态。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(8)
        }
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
                Toggle("展开时触觉反馈", isOn: binding(\.hapticOnExpand))

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

    private var subtitleSection: some View {
        GroupBox("字幕") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("启用浏览器字幕查询", isOn: binding(\.videoSubtitles))
                Toggle("允许屏幕字幕识别", isOn: binding(\.screenSubtitles))
                Toggle("查看字幕时暂停视频", isOn: binding(\.pausesVideoOnPeek))
                Toggle("收起字幕时恢复视频", isOn: binding(\.resumesVideoAfterPeek))
                Text("在浏览器中按 \(preferences.subtitleHotKey.display) 查看字幕，按 \(preferences.previousSubtitleHotKey.display) 或 \(preferences.nextSubtitleHotKey.display) 切换句子。屏幕识别前，请从菜单栏框选字幕区域。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    private var dictionarySection: some View {
        GroupBox("词典来源") {
            VStack(alignment: .leading, spacing: 8) {
                List {
                    ForEach(preferences.dictionarySources) { source in
                        HStack {
                            Toggle(source.name, isOn: Binding(
                                get: { preferences.dictionarySources.first { $0.id == source.id }?.enabled == true },
                                set: { enabled in
                                    if let index = preferences.dictionarySources.firstIndex(where: { $0.id == source.id }) {
                                        preferences.dictionarySources[index].enabled = enabled
                                    }
                                }
                            ))
                            Spacer()
                            if source.kind == .stardict {
                                Button(role: .destructive) {
                                    model.removeDictionary(source, from: preferences)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("移除 \(source.name)")
                            }
                        }
                    }
                    .onMove { indices, destination in
                        preferences.dictionarySources.move(fromOffsets: indices, toOffset: destination)
                    }
                }
                .frame(height: min(180, CGFloat(preferences.dictionarySources.count * 29 + 12)))

                Text("按列表顺序查找已启用的词典。拖动可改变顺序。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("导入 StarDict…") { model.importDictionary(into: preferences) }
                if !model.dictionaryMessage.isEmpty {
                    Text(model.dictionaryMessage).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .disabled(model.dictionaryBusy)
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

                Picker("翻译服务", selection: binding(\.translationPreset)) {
                    ForEach(ProviderPreset.allCases) { preset in
                        Text(preset.name).tag(preset)
                    }
                }
                .onChange(of: preferences.translationPreset) { _, preset in
                    model.apiKeyInput = ""
                    model.modelChoices = []
                    model.onlineMessage = ""
                    model.refreshKey(preset: preset)
                    refreshOnlineStatus()
                }

                Toggle("本地不可用时允许联网翻译", isOn: binding(\.onlineEnabled))
                    .onChange(of: preferences.onlineEnabled) { _, _ in refreshOnlineStatus() }

                HStack(spacing: 10) {
                    Text("服务地址").frame(width: 72, alignment: .leading)
                    if preferences.translationPreset == .custom {
                        TextField("https://api.openai.com/v1", text: binding(\.baseURL))
                            .focused($translationField, equals: .address)
                            .onSubmit(refreshOnlineStatus)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        Text(preferences.onlineAddress)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 10) {
                    Text("模型").frame(width: 72, alignment: .leading)
                    TextField(preferences.translationPreset.defaultModel, text: binding(\.onlineModel))
                        .focused($translationField, equals: .model)
                        .onSubmit(refreshOnlineStatus)
                        .textFieldStyle(.roundedBorder)
                }
                HStack(spacing: 10) {
                    Text("API 密钥").frame(width: 72, alignment: .leading)
                    SecureField("只保存到钥匙串", text: $model.apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                    Button("保存") {
                        model.saveKey(preset: preferences.translationPreset)
                        translator.invalidateCache()
                        refreshOnlineStatus()
                    }
                    .disabled(model.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("清除") {
                        model.clearKey(preset: preferences.translationPreset)
                        translator.invalidateCache()
                        refreshOnlineStatus()
                    }
                }

                HStack {
                    if preferences.translationPreset.supportsOpenAIModelList {
                        Button("刷新模型列表") {
                            model.checkOnline(translator: translator, preferences: preferences, listModels: true)
                        }
                        .disabled(model.serviceBusy)
                        if !model.modelChoices.isEmpty {
                            Menu("选择模型") {
                                ForEach(model.modelChoices, id: \.self) { choice in
                                    Button(choice) {
                                        preferences.onlineModel = choice
                                        refreshOnlineStatus()
                                    }
                                }
                            }
                        }
                    }
                    Button("测试当前服务") {
                        model.checkOnline(translator: translator, preferences: preferences, listModels: false)
                    }
                    .disabled(model.serviceBusy || !preferences.onlineEnabled)
                }
                if !model.onlineMessage.isEmpty {
                    Text(model.onlineMessage)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
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
