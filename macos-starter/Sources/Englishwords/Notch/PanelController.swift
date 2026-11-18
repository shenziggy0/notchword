import AppKit
import SwiftUI

/// 无边框、不激活、浮在普通窗口之上的面板。
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 允许窗口贴到屏幕最上沿（覆盖菜单栏/刘海区域），不被系统下推。
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// 宿主视图。点击第一下就生效，不需要先激活应用。
final class PanelHostingView: NSHostingView<AnyView> {

    var onClick: (() -> Void)?

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
    }

    required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

/// 刘海面板：紧凑 / 展开两种形态，一个收起计时器，Esc 关闭。
///
/// 指针是否在面板内用轮询判断，而不用 `NSTrackingArea`：重建宿主视图、改变
/// 窗口尺寸都会派发假的 enter/exit，导致紧凑/展开来回抖动。
@MainActor
final class PanelController {

    enum Mode {
        case compact
        case expanded
    }

    var isShowingSubtitle: Bool { isVisible && subtitle != nil }

    /// 面板被收起（Esc / 超时 / 新入口）时通知外层，用于丢弃在途查询。
    var onHide: (() -> Void)?
    var onBackToSubtitle: (() -> Void)?
    private var subtitle: SubtitleView?

    private let preferences: Preferences
    private let notebook: NotebookModel?
    private var panel: NotchPanel?
    private var hosting: PanelHostingView?
    private var hideWorkItem: DispatchWorkItem?
    private var pointerTimer: Timer?
    private var escapeMonitor: Any?
    private var state: LookupState?
    private var targetScreen: NSScreen?
    private var mode: Mode = .compact
    private var isVisible = false
    private var pointerInside = false

    init(preferences: Preferences, notebook: NotebookModel? = nil) {
        self.preferences = preferences
        self.notebook = notebook

        // 显示器增减或分辨率变化后重新定位，避免面板留在旧屏幕上
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.screenParametersChanged() }
        }
    }

    // MARK: - 对外

    func show(_ state: LookupState, mode: Mode = .compact) {
        subtitle = nil
        self.state = state
        self.mode = mode
        self.targetScreen = state.request.screen ?? NSScreen.main
        guard let screen = targetScreen else { return }

        render(on: screen)
        reveal()
        installEscapeMonitor()
        startPointerTracking()
        if pointerInside, preferences.expandsOnHover { expand() }
        restartHideTimer()
    }

    func showSubtitle(_ view: SubtitleView, on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        subtitle = view
        state = nil
        mode = .expanded
        targetScreen = screen
        render(on: screen)
        reveal()
        installEscapeMonitor()
        startPointerTracking()
        restartHideTimer()
    }

    func refreshPreferences() {
        guard isVisible, let screen = targetScreen else { return }
        render(on: screen)
        pointerInside = panel?.frame.contains(NSEvent.mouseLocation) ?? false
        restartHideTimer()
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        stopPointerTracking()
        removeEscapeMonitor()

        guard let panel, isVisible else { return }
        isVisible = false
        onHide?()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard self?.isVisible != true else { return }
                panel.orderOut(nil)
            }
        })
    }

    func contains(_ point: NSPoint) -> Bool {
        guard isVisible, let panel else { return false }
        return panel.frame.contains(point)
    }

    // MARK: - 形态切换

    private func expand() {
        guard mode != .expanded, let screen = targetScreen else { return }
        hideWorkItem?.cancel()
        mode = .expanded
        if preferences.hapticOnExpand {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        }
        render(on: screen)
    }

    private func collapse() {
        guard subtitle == nil, mode != .compact, let screen = targetScreen else { return }
        mode = .compact
        render(on: screen)
    }

    // MARK: - 指针

    private func startPointerTracking() {
        stopPointerTracking()
        pointerInside = panel?.frame.contains(NSEvent.mouseLocation) ?? false

        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkPointer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    private func stopPointerTracking() {
        pointerTimer?.invalidate()
        pointerTimer = nil
    }

    private func screenParametersChanged() {
        guard isVisible else { return }
        targetScreen = Screens.screen(containing: NSEvent.mouseLocation)
        if let screen = targetScreen { render(on: screen) }
    }

    private func checkPointer() {
        guard isVisible, let panel else { return }
        let inside = panel.frame.contains(NSEvent.mouseLocation)
        guard inside != pointerInside else { return }
        pointerInside = inside

        if inside {
            hideWorkItem?.cancel()
            hideWorkItem = nil
            if preferences.expandsOnHover { expand() }
        } else {
            if preferences.expandsOnHover { collapse() }
            restartHideTimer()
        }
    }

    // MARK: - 渲染

    private func render(on screen: NSScreen) {
        guard state != nil || subtitle != nil else { return }

        let geometry = NotchGeometry.measure(screen)
        let width = mode == .expanded ? geometry.expandedWidth : geometry.compactWidth
        let maxHeight = max(screen.visibleFrame.height - 60, 260)

        var view = content(geometry: geometry, width: width, maxHeight: subtitle == nil ? nil : min(260, maxHeight))
        var hosting = makeHosting(view)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 0)
        hosting.layoutSubtreeIfNeeded()
        var height = hosting.fittingSize.height

        if height > maxHeight {
            view = content(geometry: geometry, width: width, maxHeight: maxHeight)
            hosting = makeHosting(view)
            height = maxHeight
        }
        height = max(height, geometry.contentTopInset + 44)

        let panel = panel ?? makePanel()
        self.panel = panel
        self.hosting = hosting
        panel.contentView = hosting
        let frame = geometry.frame(for: screen, width: width, height: height)
        panel.setFrame(frame, display: true)
        // 重建 contentView 可能打断淡入动画，把窗口不透明度恢复到最终值
        if isVisible { panel.alphaValue = 1 }

        if ProcessInfo.processInfo.environment["EW_DEBUG_PANEL"] != nil {
            FileLog.write("panel mode=\(mode) frame=\(frame) alpha=\(panel.alphaValue) opaque=\(panel.isOpaque)")
        }
    }

    private func content(geometry: NotchGeometry, width: CGFloat, maxHeight: CGFloat?) -> AnyView {
        if let subtitle {
            let view = subtitle
                .padding(.top, geometry.contentTopInset)
                .frame(width: width)
            if let maxHeight {
                return AnyView(ScrollView { view }.frame(width: width, height: maxHeight)
                    .background(.black, in: RoundedRectangle(cornerRadius: 16)))
            }
            return AnyView(view.background(.black, in: RoundedRectangle(cornerRadius: 16)))
        }
        guard let state else { return AnyView(EmptyView()) }
        return AnyView(ResultView(
            state: state,
            mode: mode,
            topInset: geometry.contentTopInset,
            width: width,
            maxHeight: maxHeight,
            showWordParts: preferences.showWordParts,
            lookupShortcut: preferences.lookupHotKey.display,
            notebook: notebook,
            onBackToSubtitle: state.request.trigger == .subtitle ? onBackToSubtitle : nil,
            speechVoice: preferences.speechVoice,
            speechRate: preferences.speechRate
        ))
    }

    private func makeHosting(_ view: AnyView) -> PanelHostingView {
        let hosting = PanelHostingView(rootView: view)
        hosting.onClick = { [weak self] in self?.expand() }
        return hosting
    }

    private func reveal() {
        guard let panel else { return }
        if !isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
                panel.animator().alphaValue = 1
            }
            isVisible = true
        } else {
            panel.orderFrontRegardless()
        }
    }

    private func restartHideTimer() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        guard !pointerInside else { return }
        if case .loading? = state { return }
        let item = DispatchWorkItem { [weak self] in self?.hide() }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + preferences.autoHideInterval, execute: item)
    }

    // MARK: - Esc

    /// 全局监听不吞掉按键：Esc 同时仍会传给原应用。
    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            DispatchQueue.main.async { self?.hide() }
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    // MARK: - 窗口

    private func makePanel() -> NotchPanel {
        let panel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.ignoresMouseEvents = false
        panel.animationBehavior = .none
        return panel
    }
}
