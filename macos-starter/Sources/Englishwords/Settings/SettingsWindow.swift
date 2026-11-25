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

    func show(installationPermissionMessage: String? = nil) {
        model.installationPermissionMessage = installationPermissionMessage
        if window == nil {
            let view = SettingsView(preferences: preferences, model: model, translator: translator,
                                    recorder: hotkeyRecorder, onPrepareLanguage: { [weak self] in
                self?.showLanguagePack()
            }, onOnboarding: { [weak self] in self?.showOnboarding?() })
            let controller = NSHostingController(rootView: view.lexiconPage())
            let window = NSWindow(contentViewController: controller)
            window.title = "Englishwords 设置"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.tabbingMode = .disallowed
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 780, height: 600))
            window.contentMinSize = NSSize(width: 500, height: 350)
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
            let controller = NSHostingController(rootView: LanguagePackView(model: model).lexiconPage())
            let window = NSWindow(contentViewController: controller)
            window.title = "准备语言包"
            window.styleMask = [.titled, .closable]
            window.tabbingMode = .disallowed
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 440, height: 252))
            window.center()
            window.delegate = self
            self.languageWindow = window
        }
        focus(languageWindow)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        model.refreshSystemStatus()
        Task { await model.checkLocalAvailability() }
    }

    /// 设置窗失焦时结束录制，避免热键监听泄漏到其他窗口。
    func windowDidResignKey(_ notification: Notification) {
        if (notification.object as? NSWindow) === window { hotkeyRecorder.cancel() }
    }

    /// 菜单栏应用默认没有 Dock 图标，主动打开窗口时临时切成普通应用才能拿到焦点。
    private func focus(_ window: NSWindow?) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        let closesSettings = closing === window
        let closesLanguage = closing === languageWindow
        guard closesSettings || closesLanguage else { return }
        if closesSettings { hotkeyRecorder.cancel() }
        if closesLanguage { languageWindow = nil }

        if !NSApp.windows.contains(where: {
            $0 !== closing && ($0.isVisible || $0.isMiniaturized) && $0.styleMask.contains(.titled)
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
    @Published var localInstalled = false
    @Published var localCanPrepare = false
    @Published var localExample = ""
    @Published var localBusy = false
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
    @Published var installationPermissionMessage: String?
    @Published var diagnosticsMessage = ""
    @Published fileprivate var selectedTab = SettingsPane.general
    private var onlineTask: Task<Void, Never>?

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
        onlineTask?.cancel()
        let preset = preferences.translationPreset
        let address = preferences.onlineAddress
        let model = preferences.onlineModel
        serviceBusy = true
        onlineMessage = listModels ? "正在获取模型…" : "正在测试服务…"
        onlineTask = Task {
            // 被新请求取消的任务不要抢着把 UI 改回可用
            defer { if !Task.isCancelled { serviceBusy = false } }
            do {
                let unchanged = { preferences.translationPreset == preset
                    && preferences.onlineAddress == address
                    && preferences.onlineModel == model }
                if listModels {
                    let choices = try await translator.listModels()
                    guard !Task.isCancelled, unchanged() else { return }
                    modelChoices = choices
                    onlineMessage = choices.isEmpty ? "该端点没有返回模型，可手动输入。" : "已获取 \(choices.count) 个模型。"
                } else {
                    let result = try await translator.testOnlineTranslation()
                    guard !Task.isCancelled, unchanged() else { return }
                    onlineMessage = "测试通过：\(result.text)"
                }
            } catch {
                guard !Task.isCancelled, preferences.translationPreset == preset,
                      preferences.onlineAddress == address,
                      preferences.onlineModel == model else { return }
                onlineMessage = error.localizedDescription
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
        } else {
            loginMessage = ""
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
                // 先取消引用再删文件，避免查询仍然命中已删的缓存
                preferences.dictionarySources.removeAll { $0.id == source.id }
                try await StarDictLibrary.shared.remove(source)
                dictionaryMessage = "已移除 \(source.name)"
            } catch {
                dictionaryMessage = error.localizedDescription
            }
        }
    }

    func checkLocalAvailability() async {
        let source = Locale.Language(identifier: "en")
        let target = Locale.Language(identifier: "zh-Hans")
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed:
            localInstalled = true
            localCanPrepare = false
            localStatus = "语言包已安装，可离线翻译"
        case .supported:
            localInstalled = false
            localCanPrepare = true
            localStatus = "需要准备语言包"
        default:
            localInstalled = false
            localCanPrepare = false
            localStatus = "当前系统不支持英译中"
        }
    }
}

// MARK: - 设置界面

fileprivate enum SettingsPane: String, CaseIterable, Identifiable {
    case general = "通用", lookup = "取词", dictionaries = "词典", translation = "翻译"
    case subtitles = "字幕", speech = "朗读", rules = "应用规则", about = "关于"

    var id: Self { self }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .lookup: "text.cursor"
        case .dictionaries: "books.vertical"
        case .translation: "character.bubble"
        case .subtitles: "captions.bubble"
        case .speech: "speaker.wave.2"
        case .rules: "square.grid.2x2"
        case .about: "info.circle"
        }
    }
}

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 690
            HStack(alignment: .top, spacing: compact ? 0 : 16) {
                if !compact {
                    sidebar
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(model.selectedTab.rawValue)
                            .font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                        Spacer()
                        if compact {
                            Menu {
                                Picker("设置分类", selection: $model.selectedTab) {
                                    ForEach(SettingsPane.allCases) { pane in
                                        Label(pane.rawValue, systemImage: pane.symbol).tag(pane)
                                    }
                                }
                                .pickerStyle(.inline)
                            } label: {
                                Label("设置分类", systemImage: "sidebar.left")
                            }
                            .fixedSize()
                            .accessibilityLabel("选择设置分类")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    Form {
                        switch model.selectedTab {
                        case .general:
                            generalSection
                            panelSection
                        case .lookup:
                            automaticSection
                            hotkeySection
                        case .dictionaries: dictionarySection
                        case .translation: translationSection
                        case .subtitles: subtitleSection
                        case .speech: speechSection
                        case .rules: appRulesSection
                        case .about: aboutSection
                        }
                    }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
                    .toggleStyle(.switch)
                    .id(model.selectedTab)
                    .transition(.opacity)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: model.selectedTab)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(12)
        }
        .onChange(of: model.selectedTab) { _, _ in
            recorder.cancel()
        }
        .onChange(of: translationField) { previous, _ in
            if previous != nil { refreshOnlineStatus() }
        }
    }

    private var sidebar: some View {
        let selection = Binding<SettingsPane?>(get: { model.selectedTab }, set: { pane in
            if let pane { model.selectedTab = pane }
        })
        return List(SettingsPane.allCases, selection: selection) { pane in
            Label(pane.rawValue, systemImage: pane.symbol)
                .font(.system(.body, weight: .medium))
                .padding(.vertical, 5)
                .tag(pane)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .padding(5)
        .frame(width: 154)
        .lexiconGlass(in: RoundedRectangle(cornerRadius: 21, style: .continuous))
        .accessibilityLabel("设置分类")
    }

    @ViewBuilder private var generalSection: some View {
        Section("启动") {
            Toggle("登录后启动", isOn: Binding(get: { model.loginEnabled }, set: model.changeLoginItem))
            if !model.loginMessage.isEmpty {
                Text(model.loginMessage).font(.callout).foregroundStyle(Lexicon.secondary)
                Button("打开登录项设置") { SMAppService.openSystemSettingsLoginItems() }
            }
        }
        Section("系统权限") {
            if let message = model.installationPermissionMessage { Text(message).font(.callout) }
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
            Button { model.refreshSystemStatus() } label: {
                Label("刷新权限", systemImage: "arrow.clockwise")
            }
        }
    }

    private func permissionRow(_ label: String, state: String, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                Text(state).font(.callout).foregroundStyle(Lexicon.secondary)
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
        Section("快捷键") {
            Toggle("启用区域取词", isOn: binding(\.regionLookupEnabled))
            ForEach(hotkeys.indices, id: \.self) { index in
                let (label, keyPath) = hotkeys[index]
                LabeledContent(label) {
                    Button(recorder.recording == label ? "请按键…" : preferences[keyPath: keyPath].display) {
                        recorder.begin(name: label, current: {
                            hotkeys.filter { $0.1 != keyPath }.map { preferences[keyPath: $0.1] }
                        }) { preferences[keyPath: keyPath] = $0 }
                    }
                    .monospaced()
                    .accessibilityLabel("更改\(label)快捷键")
                    .accessibilityValue(recorder.recording == label ? "等待按键" : preferences[keyPath: keyPath].display)
                }
            }
            if !recorder.message.isEmpty { Text(recorder.message).font(.callout).foregroundStyle(Lexicon.secondary) }
        }
    }

    /// 英文声音列表只取一次，不与视图刷新挂钩。
    private static let englishVoices: [AVSpeechSynthesisVoice] = AVSpeechSynthesisVoice.speechVoices()
        .filter { $0.language.hasPrefix("en") }
        .sorted { $0.name < $1.name }

    private var speechSection: some View {
        let voices = Self.englishVoices
        let selected = preferences.speechVoice
        // 之前选的声音已不可用时仍保留在下拉里，避免值被静默改成默认
        let missing = !selected.isEmpty && !voices.contains { $0.identifier == selected }
        return Section("声音与语速") {
            Picker("英语声音", selection: binding(\.speechVoice)) {
                Text("系统默认").tag("")
                if missing { Text("不可用：\(selected)").tag(selected) }
                ForEach(voices, id: \.identifier) { voice in
                    Text(Self.voiceLabel(voice, among: voices)).tag(voice.identifier)
                }
            }
            Slider(value: binding(\.speechRate), in: 0.15...0.65) { Text("语速") }
            Button {
                Speaker.shared.speak("This is a test.", voiceID: preferences.speechVoice, rate: preferences.speechRate)
            } label: { Label("播放示例", systemImage: "speaker.wave.2") }
        }
    }

    /// 同名声音加上语言标签区分，比如两个 "Samantha"。
    private static func voiceLabel(_ voice: AVSpeechSynthesisVoice, among voices: [AVSpeechSynthesisVoice]) -> String {
        let duplicated = voices.contains { $0.identifier != voice.identifier && $0.name == voice.name }
        return duplicated ? "\(voice.name)（\(voice.language)）" : voice.name
    }

    private var appRulesSection: some View {
        let running = NSWorkspace.shared.runningApplications.filter {
            guard let id = $0.bundleIdentifier else { return false }
            return $0.activationPolicy == .regular && id != Bundle.main.bundleIdentifier
                && !AppRules.excludedBundleIDs.contains(id) && !preferences.userExcluded.contains(id)
        }.reduce(into: [String: String]()) { result, app in
            if let id = app.bundleIdentifier { result[id] = app.localizedName ?? id }
        }
        return Section("自动取词排除") {
            Menu("添加运行中的应用") {
                ForEach(running.keys.sorted(), id: \.self) { id in
                    Button(running[id] ?? id) { preferences.userExcluded.append(id) }
                }
            }
            .disabled(running.isEmpty)
            ForEach(preferences.userExcluded, id: \.self) { id in
                LabeledContent(id) {
                    Button("移除") { preferences.userExcluded.removeAll { $0 == id } }
                        .accessibilityLabel("移除 \(id)")
                }
            }
            DisclosureGroup("默认排除的密码管理器") {
                ForEach(AppRules.excludedBundleIDs.sorted(), id: \.self) { id in
                    Text(id).font(.callout).foregroundStyle(Lexicon.secondary)
                }
            }
        }
    }

    @ViewBuilder private var aboutSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 52, height: 52).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Englishwords").font(.title2.bold())
                    Text("版本 " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发构建"))
                        .font(.callout).foregroundStyle(Lexicon.secondary)
                }
            }
            Button("使用引导", action: onOnboarding)
            Button("第三方许可") {
                if let url = AppResources.noticesURL() { NSWorkspace.shared.open(url) }
            }
        }
        Section {
            Button("导出诊断…") { model.exportDiagnostics() }
            if !model.diagnosticsMessage.isEmpty { Text(model.diagnosticsMessage).font(.callout) }
        } footer: {
            Text("查询默认在本机处理。导出的诊断包含权限、版本和开关状态。")
        }
    }

    private var automaticSection: some View {
        Section("自动取词") {
            Toggle("悬停取词", isOn: binding(\.hoverEnabled))
            Toggle("划词取词", isOn: binding(\.selectionEnabled))
            durationSlider("悬停时长", value: binding(\.hoverDwellSeconds), seconds: preferences.hoverDwell,
                           range: 0.15...1.5, step: 0.05, digits: 2)
            Toggle("显示词根词缀", isOn: binding(\.showWordParts))
        }
    }

    private var panelSection: some View {
        Section {
            Toggle("鼠标移入时展开", isOn: binding(\.expandsOnHover))
            Toggle("展开时触觉反馈", isOn: binding(\.hapticOnExpand))
            durationSlider("自动收起", value: binding(\.autoHideSeconds), seconds: preferences.autoHideInterval,
                           range: 2...15, step: 0.5, digits: 1)
        } header: {
            Text("结果面板")
        } footer: {
            Text("指针停在面板上会暂停计时，移开后重新计时。按 Esc 可立即收起。")
        }
    }

    private func durationSlider(_ label: String, value: Binding<Double>, seconds: Double,
                                range: ClosedRange<Double>, step: Double, digits: Int) -> some View {
        let duration = seconds.formatted(.number.precision(.fractionLength(digits))) + " 秒"
        return LabeledContent(label) {
            HStack(spacing: 8) {
                Slider(value: value, in: range, step: step)
                    .accessibilityLabel(label)
                    .accessibilityValue(duration)
                Text(duration)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(Lexicon.secondary)
                    .frame(minWidth: 48, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
    }

    private var subtitleSection: some View {
        Section {
            Toggle("启用浏览器字幕查询", isOn: binding(\.videoSubtitles))
            Toggle("允许屏幕字幕识别", isOn: binding(\.screenSubtitles))
            Toggle("查看字幕时暂停视频", isOn: binding(\.pausesVideoOnPeek))
            Toggle("收起字幕时恢复视频", isOn: binding(\.resumesVideoAfterPeek))
        } header: {
            Text("字幕与播放")
        } footer: {
            Text("在浏览器中按 \(preferences.subtitleHotKey.display) 查看字幕，按 \(preferences.previousSubtitleHotKey.display) 或 \(preferences.nextSubtitleHotKey.display) 切换句子。使用屏幕识别前，请从菜单栏框选字幕区域。")
        }
    }

    private var dictionarySection: some View {
        Section {
            List {
                ForEach(preferences.dictionarySources) { source in
                    HStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(Lexicon.secondary).accessibilityHidden(true)
                        Toggle(source.name, isOn: Binding(
                            get: { preferences.dictionarySources.first { $0.id == source.id }?.enabled == true },
                            set: { enabled in
                                if let index = preferences.dictionarySources.firstIndex(where: { $0.id == source.id }) {
                                    preferences.dictionarySources[index].enabled = enabled
                                }
                            }
                        ))
                        .toggleStyle(.checkbox)
                        Spacer(minLength: 8)
                        Menu {
                            Button("上移") { moveDictionary(source, by: -1) }
                                .disabled(preferences.dictionarySources.first?.id == source.id)
                            Button("下移") { moveDictionary(source, by: 1) }
                                .disabled(preferences.dictionarySources.last?.id == source.id)
                            if source.kind == .stardict {
                                Divider()
                                Button("移除词典", role: .destructive) { model.removeDictionary(source, from: preferences) }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .fixedSize()
                        .menuStyle(.borderlessButton)
                        .accessibilityLabel("\(source.name)的操作")
                        .help("调整顺序或管理词典")
                    }
                }
                .onMove { indices, destination in
                    preferences.dictionarySources.move(fromOffsets: indices, toOffset: destination)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(height: min(210, CGFloat(preferences.dictionarySources.count * 40 + 12)))
            Button("导入 StarDict…") { model.importDictionary(into: preferences) }
            if !model.dictionaryMessage.isEmpty {
                Text(model.dictionaryMessage).font(.callout).foregroundStyle(Lexicon.secondary)
            }
        } header: {
            Text("词典来源")
        } footer: {
            Text("按列表顺序查找已启用的词典。拖动词典或打开行末菜单可调整优先级。")
        }
        .disabled(model.dictionaryBusy)
    }

    private func moveDictionary(_ source: DictionarySource, by offset: Int) {
        guard let from = preferences.dictionarySources.firstIndex(where: { $0.id == source.id }),
              preferences.dictionarySources.indices.contains(from + offset) else { return }
        preferences.dictionarySources.swapAt(from, from + offset)
    }

    @ViewBuilder private var translationSection: some View {
        Section("Apple 本地翻译") {
            HStack(spacing: 10) {
                Text(model.localStatus).frame(maxWidth: .infinity, alignment: .leading)
                if model.localInstalled {
                    Button("试译一句") {
                        model.localBusy = true
                        model.localExample = ""
                        let language = preferences.targetLanguage
                        Task {
                            defer { model.localBusy = false }
                            do {
                                let request = TranslationRequest(text: "Let me show you how it works.",
                                                                 source: "en", target: language)
                                model.localExample = try await AppleTranslate().translate(request).text
                            } catch { model.localExample = error.localizedDescription }
                        }
                    }.disabled(model.localBusy)
                } else if model.localCanPrepare {
                    Button("准备语言包", action: onPrepareLanguage)
                }
            }
            if !model.localExample.isEmpty { Text(model.localExample) }
        }
        Section {
            Toggle("本地不可用时允许联网翻译", isOn: binding(\.onlineEnabled))
                .onChange(of: preferences.onlineEnabled) { _, _ in refreshOnlineStatus() }
            if preferences.onlineEnabled {
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
                if preferences.translationPreset == .custom {
                    TextField("服务地址", text: binding(\.baseURL), prompt: Text("https://api.openai.com/v1"))
                        .focused($translationField, equals: .address)
                        .onSubmit(refreshOnlineStatus)
                } else {
                    LabeledContent("服务地址", value: preferences.onlineAddress)
                }
                TextField("模型", text: binding(\.onlineModel), prompt: Text(preferences.translationPreset.defaultModel))
                    .focused($translationField, equals: .model)
                    .onSubmit(refreshOnlineStatus)
                SecureField("API 密钥", text: $model.apiKeyInput, prompt: Text("只保存到钥匙串"))
                HStack {
                    Text("密钥" + model.keyMessage).font(.callout).foregroundStyle(Lexicon.secondary)
                    Spacer()
                    Button("保存") {
                        model.saveKey(preset: preferences.translationPreset)
                        translator.invalidateCache()
                        refreshOnlineStatus()
                    }
                    .disabled(model.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("保存 API 密钥")
                    Button("清除") {
                        model.clearKey(preset: preferences.translationPreset)
                        translator.invalidateCache()
                        refreshOnlineStatus()
                    }
                    .accessibilityLabel("清除 API 密钥")
                }
            }
        } header: {
            Text("联网翻译")
        } footer: {
            Text(model.onlineStatus)
        }
        if preferences.onlineEnabled {
            Section("连接测试") {
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
                if !model.onlineMessage.isEmpty {
                    Text(model.onlineMessage).font(.callout).foregroundStyle(Lexicon.secondary)
                }
            }
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
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "character.bubble")
                .font(.system(size: 24, weight: .medium)).foregroundStyle(Lexicon.accent)
                .accessibilityHidden(true)
            Text("英译中语言包").font(.largeTitle.bold())
            ScrollView {
                Text(model.status)
                    .font(.body).foregroundStyle(Lexicon.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 9) {
                Spacer()
                if model.isPreparing { ProgressView().controlSize(.small).accessibilityHidden(true) }
                Button(model.isPreparing ? "准备中…" : "开始准备") { model.start() }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                    .controlSize(.large).keyboardShortcut(.defaultAction)
                    .disabled(model.isPreparing)
            }
        }
        .padding(24)
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
