import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let preferences = Preferences.shared
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

    private var statusItem: NSStatusItem!
    private var hoverMenuItem: NSMenuItem!
    private var selectionMenuItem: NSMenuItem!
    private var permissionItem: NSMenuItem!
    private var lastLookupSummary = "尚未取词"

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupLookup()
        setupMonitors()

        preferences.onChange = { [weak self] in self?.applyPreferences() }

        // ⌥D 查词（词典优先），⌥T 直接翻译
        if case .failure(let error) = hotKeys.register(
            keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(optionKey),
            action: { [weak self] in self?.triggerLookup(.hotkey) }
        ) {
            FileLog.write(error.localizedDescription)
            showAlert(title: "⌥D 未注册", message: error.localizedDescription)
        }
        if case .failure(let error) = hotKeys.register(
            keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(optionKey),
            action: { [weak self] in self?.triggerLookup(.translate, mode: .translate) }
        ) {
            FileLog.write(error.localizedDescription)
            showAlert(title: "⌥T 未注册", message: error.localizedDescription)
        }

        // 启动时只检查、不弹窗；用户主动点菜单才提示
        _ = Permissions.ensureAccessibility(prompt: false)
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
        selection.onSubmit = { [weak self] request in self?.coordinator.submit(request) }
        self.selection = selection
    }

    private func applyPreferences() {
        permissionItem?.title = Permissions.isAccessibilityTrusted
            ? "辅助功能已授权"
            : "⚠️ 需要授权辅助功能…"
        hoverMenuItem?.state = preferences.hoverEnabled ? .on : .off
        selectionMenuItem?.state = preferences.selectionEnabled ? .on : .off

        if preferences.hoverEnabled { hover?.start() } else { hover?.stop() }
        if preferences.selectionEnabled { selection?.start() } else { selection?.stop() }
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "character.book.closed",
                                   accessibilityDescription: "Englishwords")
            button.image?.isTemplate = true
            button.toolTip = "Englishwords — ⌥D 查词"
        }

        let menu = NSMenu()

        // 顶部显示版本：一眼确认当前跑的是哪一份构建
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let versionItem = NSMenuItem(title: "Englishwords \(version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(.separator())

        let lookup = NSMenuItem(title: "查询选中的文字（⌥D）", action: #selector(menuLookup), keyEquivalent: "")
        lookup.target = self
        menu.addItem(lookup)

        let translate = NSMenuItem(title: "翻译选中的文字（⌥T）", action: #selector(menuTranslate), keyEquivalent: "")
        translate.target = self
        menu.addItem(translate)

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

        statusItem.menu = menu
    }

    @objc private func menuLookup() { triggerLookup(.menu) }
    @objc private func menuTranslate() { triggerLookup(.translate, mode: .translate) }
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
                  message: "在「隐私与安全性 → 辅助功能」里勾选 Englishwords 后，请退出并重新打开本应用，权限才会生效。")
    }

    @objc private func toggleHover() {
        preferences.hoverEnabled.toggle()
    }

    @objc private func toggleSelection() {
        preferences.selectionEnabled.toggle()
    }

    // MARK: - 取词

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
            note = "辅助功能未授权，读不到选中的文字，已改用剪贴板。"
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
