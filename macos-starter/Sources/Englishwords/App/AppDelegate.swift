import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let preferences: Preferences
    private let store = DictionaryStore()
    private lazy var panels = PanelController(preferences: preferences)
    private let hotKeys = HotKeyCenter()

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
    private let regionPicker = RegionPicker()

    private var statusItem: NSStatusItem!
    private var hoverMenuItem: NSMenuItem!
    private var selectionMenuItem: NSMenuItem!
    private var permissionItem: NSMenuItem!
    private var lastLookupSummary = "尚未取词"
    private var lookupMenuItem: NSMenuItem!
    private var translateMenuItem: NSMenuItem!
    private var regionMenuItem: NSMenuItem!
    private var lookupHotKeyID: UInt32?
    private var translateHotKeyID: UInt32?
    private var regionHotKeyID: UInt32?
    private var boundLookup: HotKeySpec?
    private var boundTranslate: HotKeySpec?
    private var boundRegion: HotKeySpec?

    /// 迁移必须先于 `Preferences.shared`：属性默认值会在 `init` 之前读 UserDefaults。
    override init() {
        SecretStore.migrateBundleIdentityIfNeeded()
        preferences = .shared
        super.init()
    }

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupLookup()
        setupMonitors()

        preferences.onChange = { [weak self] in self?.applyPreferences() }

        // 首次启动且未授权时弹一次系统提示；之后只更新菜单状态，不反复打扰
        let promptedKey = "permission.prompted"
        let alreadyPrompted = UserDefaults.standard.bool(forKey: promptedKey)
        _ = Permissions.ensureAccessibility(prompt: !alreadyPrompted)
        if !alreadyPrompted { UserDefaults.standard.set(true, forKey: promptedKey) }
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
                self?.coordinator.submit(LookupRequest(
                    text: text,
                    trigger: .menu,
                    screen: Screens.screen(containing: NSEvent.mouseLocation)
                ))
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hover?.stop()
        selection?.stop()
        hotKeys.unregisterAll()
    }

    // MARK: - 装配

    private func setupLookup() {
        coordinator.onState = { [weak self] state in
            self?.panels.show(state)
        }
        // 收起后不再让过期结果重新弹出
        panels.onHide = { [weak self] in
            self?.coordinator.cancel()
        }
    }

    private func setupMonitors() {
        let hover = HoverMonitor(preferences: preferences)
        hover.isInsidePanel = { [weak self] point in self?.panels.contains(point) ?? false }
        hover.onSubmit = { [weak self] request in self?.coordinator.submit(request) }
        self.hover = hover

        let selection = SelectionMonitor(preferences: preferences)
        selection.isInsidePanel = { [weak self] point in self?.panels.contains(point) ?? false }
        selection.onSubmit = { [weak self] request in self?.coordinator.submit(request) }
        self.selection = selection
    }

    private func applyPreferences() {
        permissionItem?.title = Permissions.isAccessibilityTrusted
            ? "辅助功能已授权"
            : "⚠️ 需要授权辅助功能…"
        hoverMenuItem?.state = preferences.hoverEnabled ? .on : .off
        selectionMenuItem?.state = preferences.selectionEnabled ? .on : .off
        lookupMenuItem?.title = "查询选中的文字（\(preferences.lookupHotKey.display)）"
        translateMenuItem?.title = "翻译选中的文字（\(preferences.translateHotKey.display)）"
        regionMenuItem?.title = "区域取词（\(preferences.regionHotKey.display)）"
        statusItem?.button?.toolTip = "Englishwords — \(preferences.lookupHotKey.display) 查词"

        if preferences.hoverEnabled { hover?.start() } else { hover?.stop() }
        if preferences.selectionEnabled { selection?.start() } else { selection?.stop() }
        bindHotKeys()
    }

    /// 按偏好注册查词 / 翻译热键。失败时提示，并重新注册上一次成功的键。
    private func bindHotKeys() {
        bind(spec: preferences.lookupHotKey,
             bound: &boundLookup,
             id: &lookupHotKeyID,
             fallback: .lookup,
             name: "查词",
             writeBack: { [weak self] in self?.preferences.lookupHotKey = $0 },
             action: { [weak self] in self?.triggerLookup(.hotkey) })
        bind(spec: preferences.translateHotKey,
             bound: &boundTranslate,
             id: &translateHotKeyID,
             fallback: .translate,
             name: "翻译",
             writeBack: { [weak self] in self?.preferences.translateHotKey = $0 },
             action: { [weak self] in self?.triggerLookup(.translate, mode: .translate) })
        bind(spec: preferences.regionHotKey,
             bound: &boundRegion,
             id: &regionHotKeyID,
             fallback: .region,
             name: "区域取词",
             writeBack: { [weak self] in self?.preferences.regionHotKey = $0 },
             action: { [weak self] in self?.startRegionLookup() })
    }

    private func bind(spec: HotKeySpec,
                      bound: inout HotKeySpec?,
                      id: inout UInt32?,
                      fallback: HotKeySpec,
                      name: String,
                      writeBack: (HotKeySpec) -> Void,
                      action: @escaping () -> Void) {
        if bound == spec, id != nil { return }
        if let id { hotKeys.unregister(id: id) }
        id = nil

        switch hotKeys.register(keyCode: spec.keyCode, modifiers: spec.modifiers, action: action) {
        case .success(let newID):
            id = newID
            bound = spec
        case .failure(let error):
            FileLog.write("\(name)热键注册失败")
            showAlert(title: "\(spec.display) 未注册", message: error.localizedDescription)
            let previous = bound ?? fallback
            guard previous != spec else {
                bound = nil
                return
            }
            switch hotKeys.register(keyCode: previous.keyCode, modifiers: previous.modifiers, action: action) {
            case .success(let newID):
                id = newID
                bound = previous
                writeBack(previous)
            case .failure(let fallbackError):
                FileLog.write("\(name)热键回退失败")
                showAlert(title: "\(previous.display) 未注册", message: fallbackError.localizedDescription)
                bound = nil
            }
        }
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "character.book.closed",
                                   accessibilityDescription: "Englishwords")
            button.image?.isTemplate = true
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

        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        menu.delegate = self
        statusItem.menu = menu
    }

    @objc private func menuLookup() { triggerLookup(.menu) }
    @objc private func menuTranslate() { triggerLookup(.translate, mode: .translate) }
    @objc private func menuRegion() { startRegionLookup() }
    @objc private func menuClipboard() { triggerLookup(.clipboard, preferClipboard: true) }
    @objc private func menuSettings() { openSettings() }

    @objc private func menuDiagnose() {
        let alert = NSAlert()
        alert.messageText = "取词诊断"
        alert.informativeText = Diagnostics.report(lastLookup: lastLookupSummary)
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "打开辅助功能设置")
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
        guard preferences.regionLookupEnabled else { return }
        guard !regionPicker.isPicking else { return }
        guard Permissions.isScreenCaptureGranted else {
            showAlert(title: "需要屏幕录制权限",
                      message: "区域取词要截取你框选的屏幕文字。请在系统设置里允许 Englishwords 录制屏幕。允许后如仍不可用，退出并重新打开本应用。")
            _ = Permissions.requestScreenCapture()
            Permissions.openScreenCaptureSettings()
            return
        }
        regionPicker.begin { [weak self] rect, screen in
            self?.recognizeRegion(rect, on: screen)
        }
    }

    private func recognizeRegion(_ rect: CGRect, on screen: NSScreen) {
        Task { [weak self] in
            guard let self else { return }
            let text: String
            do {
                text = try await ScreenText.recognize(rect: rect, on: screen)
            } catch {
                FileLog.write("区域取词失败")
                self.showAlert(title: "区域取词失败", message: error.localizedDescription)
                return
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            self.coordinator.submit(LookupRequest(
                text: trimmed,
                trigger: .region,
                screen: screen
            ))
        }
    }

    private func triggerLookup(_ trigger: LookupTrigger,
                               preferClipboard: Bool = false,
                               mode: LookupMode = .lookup) {
        let clipboard = (NSPasteboard.general.string(forType: .string) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trusted = Permissions.isAccessibilityTrusted
        let capture = preferClipboard ? nil : SelectionCapture.read()
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
        coordinator.submit(LookupRequest(
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
        }
        settings?.show()
    }

    // MARK: - 提示

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    /// 菜单每次打开都重新读一次授权状态：授权后无需重启就能看到变化
    func menuWillOpen(_ menu: NSMenu) {
        permissionItem?.title = Permissions.isAccessibilityTrusted
            ? "辅助功能已授权"
            : "⚠️ 需要授权辅助功能…"
    }
}
