import AppKit
import CoreText
import SwiftUI
#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let preferences: Preferences
    private let store = DictionaryStore()
    private let notebookStore = NotebookStore()
    private lazy var notebookModel = NotebookModel(store: notebookStore)
    private lazy var notebookWindow = NotebookWindow(model: notebookModel) { [weak self] word in
        self?.submitLookup(LookupRequest(text: word, trigger: .notebook, screen: Screens.screen(containing: NSEvent.mouseLocation)))
    }
    private lazy var panels = PanelController(preferences: preferences, notebook: notebookModel)
    private let hotKeys = HotKeyCenter.shared

    private lazy var translator = TranslationCoordinator(preferences: preferences)
    private lazy var coordinator = LookupCoordinator(
        store: store,
        systemDictionary: SystemDictionaryBridge(),
        translator: translator,
        preferences: preferences
    )

    private var hover: HoverMonitor?
    private var selection: SelectionMonitor?
    private var settings: SettingsWindowController?
    private var installationPermissionMessage: String?
    private lazy var onboarding = OnboardingWindow(preferences: preferences)
    private let regionPicker = RegionPicker()
    private let subtitlePicker = RegionPicker()
    private lazy var subtitles = SubtitleTracker(preferences: preferences, translator: translator)

    private var regionTask: Task<Void, Never>?
    private var regionGeneration = 0

    #if canImport(Sparkle)
    private lazy var updater = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )
    #endif

    private var statusItem: NSStatusItem!
    private var hoverMenuItem: NSMenuItem!
    private var selectionMenuItem: NSMenuItem!
    private var permissionItem: NSMenuItem!
    private var lastLookupSummary = "尚未取词"
    private var lookupMenuItem: NSMenuItem!
    private var translateMenuItem: NSMenuItem!
    private var regionMenuItem: NSMenuItem!
    private struct HotKeyRegistration {
        let spec: HotKeySpec
        let id: UInt32
    }
    private var activeHotKeys: [ReferenceWritableKeyPath<Preferences, HotKeySpec>: HotKeyRegistration] = [:]
    private var rejectedHotKeys: [ReferenceWritableKeyPath<Preferences, HotKeySpec>: HotKeySpec] = [:]

    /// 迁移必须先于 `Preferences.shared`：属性默认值会在 `init` 之前读 UserDefaults。
    override init() {
        SecretStore.migrateBundleIdentityIfNeeded()
        preferences = .shared
        super.init()
    }

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            installationPermissionMessage = await Permissions.resetAfterManualInstallation()
            finishLaunching()
        }
    }

    private func finishLaunching() {
        setupStatusItem()
        setupLookup()
        Task { await notebookModel.loadFavorites() }
        setupMonitors()

        preferences.onChange = { [weak self] in self?.applyPreferences() }

        if !preferences.sawOnboarding {
            onboarding.show()
        } else if installationPermissionMessage != nil {
            openSettings()
        }
        FileLog.write("辅助功能授权：\(Permissions.isAccessibilityTrusted)")
        applyPreferences()

        // 开发自检：直接打开设置窗口，便于核对布局
        if CommandLine.arguments.contains("--demo-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.openSettings()
            }
        }

        // 开发自检：启动后直接展示一次查询，便于截图核对面板布局
        if let index = CommandLine.arguments.firstIndex(of: "--demo-lookup"),
           index + 1 < CommandLine.arguments.count {
            let text = CommandLine.arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.submitLookup(LookupRequest(
                    text: text,
                    trigger: .menu,
                    screen: Screens.screen(containing: NSEvent.mouseLocation)
                ))
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        cancelActiveLookup()
        subtitles.dismissed()
        hover?.stop()
        selection?.stop()
        hotKeys.unregisterAll()
    }

    // MARK: - 装配

    private func setupLookup() {
        coordinator.onState = { [weak self] state in
            guard let self else { return }
            self.panels.show(state)
            guard case .result(let request, let result) = state, let word = result.notebookWord else { return }
            Task { [weak self, store = self.notebookStore] in
                do {
                    try await store.recordLookup(word: word, source: result.source, trigger: request.trigger)
                    self?.notebookWindow.refreshIfVisible()
                } catch {
                    FileLog.write("记录查词历史失败")
                }
            }
        }
        // 收起后不再让过期结果重新弹出
        panels.onHide = { [weak self] in
            self?.cancelActiveLookup()
            self?.subtitles.dismissed()
        }
        panels.onBackToSubtitle = { [weak self] in self?.showSubtitle(peek: false) }
    }

    private func setupMonitors() {
        let hover = HoverMonitor(preferences: preferences)
        hover.isInsidePanel = { [weak self] point in self?.panels.contains(point) ?? false }
        hover.onSubmit = { [weak self] request in self?.submitLookup(request) }
        self.hover = hover

        let selection = SelectionMonitor(preferences: preferences)
        selection.isInsidePanel = { [weak self] point in self?.panels.contains(point) ?? false }
        selection.onSubmit = { [weak self] request in self?.submitLookup(request) }
        self.selection = selection
    }

    private func applyPreferences() {
        permissionItem?.title = Permissions.isAccessibilityTrusted
            ? "辅助功能已授权"
            : "需要授权辅助功能…"
        hoverMenuItem?.state = preferences.hoverEnabled ? .on : .off
        selectionMenuItem?.state = preferences.selectionEnabled ? .on : .off
        lookupMenuItem?.title = "查询选中的文字（\(preferences.lookupHotKey.display)）"
        translateMenuItem?.title = "翻译选中的文字（\(preferences.translateHotKey.display)）"
        regionMenuItem?.title = "区域取词（\(preferences.regionHotKey.display)）"
        regionMenuItem?.isEnabled = preferences.regionLookupEnabled
        statusItem?.button?.toolTip = "Englishwords — \(preferences.lookupHotKey.display) 查词"

        if preferences.hoverEnabled { hover?.start() } else { hover?.stop() }
        if preferences.selectionEnabled { selection?.start() } else { selection?.stop() }
        bindHotKeys()
        if !preferences.regionLookupEnabled, regionPicker.isPicking || regionTask != nil {
            cancelRegionLookup()
            panels.hide()
        }
        if !preferences.videoSubtitles || !preferences.screenSubtitles {
            subtitlePicker.cancel()
        }
        subtitles.applyPreferences()
        panels.refreshPreferences()
    }

    private func bindHotKeys() {
        let commands: [(ReferenceWritableKeyPath<Preferences, HotKeySpec>, String, Bool, () -> Void)] = [
            (\.lookupHotKey, "查词", true, { [weak self] in self?.triggerLookup(.hotkey) }),
            (\.translateHotKey, "翻译", true, { [weak self] in self?.triggerLookup(.translate, mode: .translate) }),
            (\.regionHotKey, "区域取词", preferences.regionLookupEnabled, { [weak self] in self?.startRegionLookup() }),
            (\.subtitleHotKey, "字幕", preferences.videoSubtitles, { [weak self] in self?.showSubtitle() }),
            (\.previousSubtitleHotKey, "上一句", preferences.videoSubtitles, { [weak self] in self?.showSubtitle(offset: -1) }),
            (\.nextSubtitleHotKey, "下一句", preferences.videoSubtitles, { [weak self] in self?.showSubtitle(offset: 1) })
        ]

        for (key, name, enabled, action) in commands {
            let active = activeHotKeys[key]
            guard enabled else {
                if let active { hotKeys.unregister(id: active.id) }
                activeHotKeys.removeValue(forKey: key)
                rejectedHotKeys.removeValue(forKey: key)
                continue
            }
            let wanted = preferences[keyPath: key]
            if active?.spec == wanted {
                rejectedHotKeys.removeValue(forKey: key)
                continue
            }
            guard rejectedHotKeys[key] != wanted else { continue }
            switch hotKeys.register(keyCode: wanted.keyCode, modifiers: wanted.modifiers, action: action) {
            case .success(let id):
                if let active { hotKeys.unregister(id: active.id) }
                activeHotKeys[key] = HotKeyRegistration(spec: wanted, id: id)
                rejectedHotKeys.removeValue(forKey: key)
            case .failure(let error):
                rejectedHotKeys[key] = wanted
                FileLog.write("\(name)热键注册失败")
                let detail = error.localizedDescription
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.preferences[keyPath: key] == wanted else { return }
                    if let active { self.preferences[keyPath: key] = active.spec }
                    self.showAlert(title: "\(wanted.display) 未注册", message: detail)
                }
            }
        }
    }

    // MARK: - 菜单栏

    /// 生成 18×18pt 单色菜单栏模板图标：圆角方框 + 顶部刘海 + 衬线 E。
    private static func makeStatusBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let s = rect.width / 18.0
            ctx.scaleBy(x: s, y: s)

            let inkColor = CGColor(gray: 0, alpha: 1)
            let box = CGRect(x: 1.8, y: 1.8, width: 14.4, height: 14.4)
            let boxPath = CGPath(roundedRect: box, cornerWidth: 3.2, cornerHeight: 3.2, transform: nil)
            ctx.addPath(boxPath)
            ctx.setStrokeColor(inkColor)
            ctx.setLineWidth(1.3)
            ctx.strokePath()

            // 顶部刘海（裁剪到圆角框内）
            ctx.saveGState()
            ctx.addPath(boxPath)
            ctx.clip()
            let notch = CGRect(x: 6.2, y: box.maxY - 1.6, width: 5.6, height: 2.2)
            let notchPath = CGPath(roundedRect: notch, cornerWidth: 1.0, cornerHeight: 1.0, transform: nil)
            ctx.addPath(notchPath)
            ctx.setFillColor(inkColor)
            ctx.fillPath()
            ctx.restoreGState()

            // 居中衬线 E（按字形实际边界对齐）
            let base = NSFont.systemFont(ofSize: 9.5, weight: .bold)
            let desc = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
            let font = (NSFont(descriptor: desc, size: 9.5) ?? base) as CTFont
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): inkColor,
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "E", attributes: attrs))
            let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            ctx.textPosition = CGPoint(x: 9.0 - ink.midX, y: 8.1 - ink.midY)
            CTLineDraw(line, ctx)
            return true
        }
        image.isTemplate = true
        return image
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Self.makeStatusBarIcon()
            button.image?.accessibilityDescription = "Englishwords"
        }

        let menu = NSMenu()

        // 顶部显示版本：一眼确认当前跑的是哪一份构建
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let versionItem = NSMenuItem(title: "Englishwords \(version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(.separator())

        lookupMenuItem = NSMenuItem(title: "查询选中的文字", action: #selector(menuLookup), keyEquivalent: "")
        lookupMenuItem.target = self
        menu.addItem(lookupMenuItem)

        translateMenuItem = NSMenuItem(title: "翻译选中的文字", action: #selector(menuTranslate), keyEquivalent: "")
        translateMenuItem.target = self
        menu.addItem(translateMenuItem)

        regionMenuItem = NSMenuItem(title: "区域取词", action: #selector(menuRegion), keyEquivalent: "")
        regionMenuItem.target = self
        menu.addItem(regionMenuItem)

        let subtitle = NSMenuItem(title: "查看视频字幕", action: #selector(menuSubtitle), keyEquivalent: "")
        subtitle.target = self
        menu.addItem(subtitle)
        let subtitleArea = NSMenuItem(title: "框选字幕区域…", action: #selector(menuSubtitleArea), keyEquivalent: "")
        subtitleArea.target = self
        menu.addItem(subtitleArea)

        let clipboard = NSMenuItem(title: "查询剪贴板", action: #selector(menuClipboard), keyEquivalent: "")
        clipboard.target = self
        menu.addItem(clipboard)

        menu.addItem(.separator())

        let autoItem = NSMenuItem(title: "自动取词", action: nil, keyEquivalent: "")
        let autoMenu = NSMenu()
        hoverMenuItem = NSMenuItem(title: "悬停取词", action: #selector(toggleHover), keyEquivalent: "")
        hoverMenuItem.target = self
        autoMenu.addItem(hoverMenuItem)
        selectionMenuItem = NSMenuItem(title: "划词取词", action: #selector(toggleSelection), keyEquivalent: "")
        selectionMenuItem.target = self
        autoMenu.addItem(selectionMenuItem)
        autoItem.submenu = autoMenu
        menu.addItem(autoItem)

        menu.addItem(.separator())

        let notebook = NSMenuItem(title: "笔记本…", action: #selector(menuNotebook), keyEquivalent: "")
        notebook.target = self
        menu.addItem(notebook)

        let settings = NSMenuItem(title: "设置…", action: #selector(menuSettings), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = [.command]
        settings.target = self
        menu.addItem(settings)

        permissionItem = NSMenuItem(title: "授权辅助功能…", action: #selector(menuPermission), keyEquivalent: "")
        permissionItem.target = self
        menu.addItem(permissionItem)

        let diagnose = NSMenuItem(title: "取词诊断…", action: #selector(menuDiagnose), keyEquivalent: "")
        diagnose.target = self
        menu.addItem(diagnose)

        menu.addItem(.separator())

        #if canImport(Sparkle)
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
           Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil {
            let updates = NSMenuItem(title: "检查更新…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
            updates.target = updater
            menu.addItem(updates)
        }
        #endif

        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        let symbols: [(NSMenuItem, String)] = [
            (lookupMenuItem, "text.magnifyingglass"), (translateMenuItem, "translate"),
            (regionMenuItem, "viewfinder"), (subtitle, "captions.bubble"), (subtitleArea, "rectangle.dashed"),
            (clipboard, "clipboard"), (autoItem, "cursorarrow"), (notebook, "book.closed"),
            (settings, "gearshape"), (permissionItem, "hand.raised"), (diagnose, "stethoscope")
        ]
        for (item, symbol) in symbols {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }

        menu.delegate = self
        statusItem.menu = menu
    }

    @objc private func menuLookup() { triggerLookup(.menu) }
    @objc private func menuTranslate() { triggerLookup(.translate, mode: .translate) }
    @objc private func menuRegion() { startRegionLookup() }
    @objc private func menuClipboard() { triggerLookup(.clipboard, preferClipboard: true) }
    @objc private func menuSubtitle() { showSubtitle() }

    @objc private func menuSubtitleArea() {
        guard preferences.videoSubtitles, preferences.screenSubtitles else {
            showAlert(title: "请先开启屏幕字幕", message: "打开设置，在字幕区启用浏览器字幕查询和屏幕字幕识别。")
            return
        }
        guard let browser = AppRules.frontmostBundleID, BrowserBridge.supports(browser) else {
            showAlert(title: "请先打开视频", message: "在支持的浏览器中播放视频后，再框选字幕位置。")
            return
        }
        guard Permissions.isScreenCaptureGranted else {
            _ = Permissions.requestScreenCapture()
            Permissions.openScreenCaptureSettings()
            return
        }
        cancelActiveLookup()
        regionPicker.cancel()
        panels.hide()
        subtitlePicker.begin { [weak self] rect, screen in
            self?.subtitles.configureOCR(rect: rect, screen: screen, browser: browser)
            self?.showSubtitle()
        }
    }

    private func showSubtitle(offset: Int? = nil, peek: Bool = true) {
        guard preferences.videoSubtitles else {
            showAlert(title: "字幕查询已关闭", message: "请在设置的字幕区启用浏览器字幕查询。")
            return
        }
        cancelActiveLookup()
        if let offset { subtitles.move(by: offset) }
        else if peek { subtitles.peek() }
        let screen = Screens.screen(containing: NSEvent.mouseLocation)
        panels.showSubtitle(SubtitleView(tracker: subtitles, onDismiss: { [weak self] in self?.panels.hide() }) { [weak self] word in
            self?.submitLookup(LookupRequest(text: word, trigger: .subtitle, screen: screen))
        }, on: screen)
    }

    @objc private func menuNotebook() { notebookWindow.show() }
    @objc private func menuSettings() { openSettings() }

    @objc private func menuDiagnose() {
        let alert = NSAlert()
        alert.messageText = "取词诊断"
        alert.informativeText = Diagnostics.report(lastLookup: lastLookupSummary)
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "打开辅助功能设置")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            Permissions.openAccessibilitySettings()
        }
    }

    @objc private func menuPermission() {
        if Permissions.isAccessibilityTrusted {
            Permissions.openAccessibilitySettings()
            return
        }
        _ = Permissions.ensureAccessibility(prompt: true)
        Permissions.openAccessibilitySettings()
        showAlert(title: "授权后请重新打开应用",
                  message: "在 \(Permissions.settingsHint) 里把 Englishwords 的开关打开，然后退出并重新打开本应用。")
    }

    @objc private func toggleHover() {
        preferences.hoverEnabled.toggle()
    }

    @objc private func toggleSelection() {
        preferences.selectionEnabled.toggle()
    }

    // MARK: - 取词

    private func startRegionLookup() {
        subtitlePicker.cancel()
        guard preferences.regionLookupEnabled else { return }
        guard !regionPicker.isPicking else { return }
        guard Permissions.isScreenCaptureGranted else {
            showAlert(title: "需要屏幕录制权限",
                      message: "区域取词要截取你框选的屏幕文字。请在系统设置里允许 Englishwords 录制屏幕。允许后如仍不可用，退出并重新打开本应用。")
            _ = Permissions.requestScreenCapture()
            Permissions.openScreenCaptureSettings()
            return
        }
        panels.hide()
        cancelActiveLookup()
        let generation = regionGeneration
        regionPicker.begin { [weak self] rect, screen in
            guard let self, generation == self.regionGeneration else { return }
            self.recognizeRegion(rect, on: screen, generation: generation)
        }
    }

    private func recognizeRegion(_ rect: CGRect, on screen: NSScreen, generation: Int) {
        let loading = LookupRequest(text: "", trigger: .region, screen: screen)
        regionTask = Task { [weak self] in
            do {
                // 先截图识别，完成前不上遮罩，避免面板挡住目标区域
                let text = try await withTimeout(20) {
                    try await ScreenText.recognize(rect: rect, on: screen)
                }
                guard let self, !Task.isCancelled, generation == self.regionGeneration else { return }
                self.regionTask = nil
                self.panels.show(.loading(loading))
                self.submitLookup(LookupRequest(text: text, trigger: .region, screen: screen))
            } catch {
                guard let self, !Task.isCancelled, generation == self.regionGeneration else { return }
                self.regionTask = nil
                FileLog.write("区域取词失败")
                let message = (error as? TranslationError).map { _ in "区域识别超时，请缩小范围后重试。" }
                    ?? error.localizedDescription
                self.panels.show(.failure(loading, message))
            }
        }
    }

    private func submitLookup(_ request: LookupRequest) {
        if request.trigger.isPassive,
           regionPicker.isPicking || subtitlePicker.isPicking || panels.isShowingSubtitle {
            return
        }
        if coordinator.submit(request) {
            cancelRegionLookup()
            if request.trigger != .subtitle { subtitles.dismissed() }
        }
    }

    private func cancelActiveLookup() {
        coordinator.cancel()
        cancelRegionLookup()
    }

    private func cancelRegionLookup() {
        regionGeneration &+= 1
        regionTask?.cancel()
        regionTask = nil
        regionPicker.cancel()
        subtitlePicker.cancel()
    }

    private func triggerLookup(_ trigger: LookupTrigger,
                               preferClipboard: Bool = false,
                               mode: LookupMode = .lookup) {
        Task { [weak self] in
            await self?.performLookup(trigger, preferClipboard: preferClipboard, mode: mode)
        }
    }

    private func performLookup(_ trigger: LookupTrigger,
                               preferClipboard: Bool,
                               mode: LookupMode) async {
        let clipboard = (NSPasteboard.general.string(forType: .string) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trusted = Permissions.isAccessibilityTrusted
        let capture = preferClipboard ? nil : await SelectionCapture.read()
        let selection = capture?.text

        var note: String?
        if let selection, let capture {
            lastLookupSummary = "\(capture.source.description)（\(selection.count) 字符）"
            FileLog.write("取词来源：\(capture.source.description)")
        } else if preferClipboard {
            lastLookupSummary = "显式读取剪贴板"
        } else if !trusted {
            lastLookupSummary = "未授权辅助功能，改用剪贴板"
            note = "辅助功能未授权，读不到选中的文字，已改用剪贴板。授权位置：\(Permissions.settingsHint)。"
        } else if !clipboard.isEmpty {
            lastLookupSummary = "未读到选区，改用剪贴板"
            note = "没有读到选中文字，已改用剪贴板。"
        } else {
            lastLookupSummary = "没有取到文字"
        }

        let text = selection ?? clipboard
        submitLookup(LookupRequest(
            text: text,
            trigger: trigger,
            screen: Screens.screen(containing: NSEvent.mouseLocation),
            mode: mode,
            note: note
        ))
    }

    private func openSettings() {
        if settings == nil {
            settings = SettingsWindowController(preferences: preferences, translator: translator)
            settings?.showOnboarding = { [weak self] in self?.onboarding.show() }
        }
        settings?.show(installationPermissionMessage: installationPermissionMessage)
    }

    // MARK: - 提示

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    /// 菜单每次打开都重新读一次授权状态：授权后无需重启就能看到变化
    func menuWillOpen(_ menu: NSMenu) {
        permissionItem?.title = Permissions.isAccessibilityTrusted
            ? "辅助功能已授权"
            : "需要授权辅助功能…"
    }
}
