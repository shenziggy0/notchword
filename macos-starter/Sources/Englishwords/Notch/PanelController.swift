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

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
    }

    required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
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
    private var localEscapeMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var state: LookupState?
    private var targetScreen: NSScreen?
    private var mode: Mode = .compact
    private var isVisible = false
    private var pointerInside = false
    private var accessibilityFocusInside = false
    private var resultRevision = 0
    private var targetFrame = NSRect.zero
    private var layoutRevision = 0
    private var visibilityRevision = 0

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    init(preferences: Preferences, notebook: NotebookModel? = nil) {
        self.preferences = preferences
        self.notebook = notebook

        // 显示器增减或分辨率变化后重新定位，避免面板留在旧屏幕上
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.screenParametersChanged() }
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    // MARK: - 对外

    func show(_ state: LookupState, mode: Mode = .compact) {
        // Loading 已展开时，结果回来不要突然塌缩；紧凑切展开时给一次触觉反馈
        let keepExpanded = isVisible && subtitle == nil
            && (self.mode == .expanded || pointerInside) && mode == .compact
        let previousMode = self.mode
        let previousRequest = self.state?.request
        if !isVisible || previousRequest?.text != state.request.text ||
            previousRequest?.trigger != state.request.trigger || previousRequest?.mode != state.request.mode {
            resetResultFocus()
        }
        subtitle = nil
        self.state = state
        self.mode = keepExpanded ? .expanded : mode
        self.targetScreen = state.request.screen ?? NSScreen.main
        guard let screen = targetScreen else { return }

        if isVisible, previousMode == .compact, self.mode == .expanded, preferences.hapticOnExpand {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        }
        render(on: screen)
        reveal()
        installEscapeMonitor()
        startPointerTracking()
        if pointerInside, preferences.expandsOnHover { expand() }
        restartHideTimer()
    }

    func showSubtitle(_ view: SubtitleView, on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        resetResultFocus()
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
        resetResultFocus()
        panel.ignoresMouseEvents = true
        visibilityRevision &+= 1
        let revision = visibilityRevision
        onHide?()
        guard !reduceMotion else {
            panel.orderOut(nil)
            panel.alphaValue = 0
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard self?.visibilityRevision == revision else { return }
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
        mode = .expanded
        if preferences.hapticOnExpand {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        }
        render(on: screen)
        pointerInside = contains(NSEvent.mouseLocation)
        restartHideTimer()
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
            if preferences.expandsOnHover { expand() }
        } else {
            if preferences.expandsOnHover, !accessibilityFocusInside { collapse() }
        }
        restartHideTimer()
    }

    // MARK: - 渲染

    private func render(on screen: NSScreen, subtitleHeight: CGFloat? = nil) {
        guard state != nil || subtitle != nil else { return }

        let geometry = NotchGeometry.measure(screen)
        let width = min(screen.frame.width, mode == .expanded ? geometry.expandedWidth : geometry.compactWidth)
        let maxHeight = max(geometry.contentTopInset + 46, screen.visibleFrame.height - 40)
        let cap = subtitle == nil ? maxHeight : min(maxHeight, geometry.contentTopInset + 280)
        let naturalHeight: CGFloat
        if let subtitleHeight {
            naturalHeight = subtitleHeight
        } else {
            let natural = content(geometry: geometry, width: width, maxHeight: nil)
            let measure = NSHostingView(rootView: natural.frame(width: width).fixedSize(horizontal: false, vertical: true))
            naturalHeight = ceil(measure.fittingSize.height)
        }
        let height = min(cap, max(geometry.contentTopInset + 46, naturalHeight))
        layoutRevision &+= 1
        let revision = layoutRevision
        let view = content(geometry: geometry, width: width,
                           maxHeight: naturalHeight > cap ? height : nil, observeFocus: true) {
            [weak self] subtitleContentHeight in
            // 翻句和译文抵达都会改变实际高度。延后一轮，避开 SwiftUI 正在进行的布局。
            DispatchQueue.main.async {
                guard let self, self.isVisible, self.subtitle != nil, self.layoutRevision == revision else { return }
                let measured = ceil(subtitleContentHeight) + geometry.contentTopInset
                let proposed = min(cap, max(geometry.contentTopInset + 46, measured))
                if abs(proposed - self.targetFrame.height) >= 1 {
                    self.render(on: screen, subtitleHeight: measured)
                }
            }
        }

        let panel = panel ?? makePanel()
        self.panel = panel
        if let hosting {
            hosting.rootView = view
        } else {
            let host = PanelHostingView(rootView: view)
            host.sizingOptions = []
            self.hosting = host
            panel.contentView = host
        }
        let frame = geometry.frame(for: screen, width: width, height: height)
        let previous = targetFrame
        targetFrame = frame
        if isVisible, !reduceMotion, previous != frame, screen.frame.contains(NSPoint(x: previous.midX, y: previous.midY)) {
            let opening = frame.height > previous.height || frame.width > previous.width
            NSAnimationContext.runAnimationGroup { context in
                context.duration = opening ? 0.30 : 0.19
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.82, 0.22, 1)
                panel.animator().setFrame(frame, display: true)
            }
        } else if !isVisible || previous != frame {
            // 使用同一动画代理设置最终值，快速重开时会取代尚未结束的展开动画。
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                panel.animator().setFrame(frame, display: true)
            }
        }

        if ProcessInfo.processInfo.environment["EW_DEBUG_PANEL"] != nil {
            FileLog.write("panel mode=\(mode) frame=\(frame) alpha=\(panel.alphaValue) opaque=\(panel.isOpaque)")
        }
    }

    private func content(geometry: NotchGeometry, width: CGFloat, maxHeight: CGFloat?,
                         observeFocus: Bool = false,
                         onSubtitleHeight: ((CGFloat) -> Void)? = nil) -> AnyView {
        if let subtitle {
            return AnyView(SubtitleViewport(tracker: subtitle.tracker, subtitle: subtitle, width: width,
                                           topInset: geometry.contentTopInset, maxHeight: maxHeight,
                                           onHeightChanged: { onSubtitleHeight?($0) }))
        }
        guard let state else { return AnyView(EmptyView()) }
        let revision = resultRevision
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
            onExpand: { [weak self] in self?.expand() },
            onDismiss: { [weak self] in self?.hide() },
            onAccessibilityFocusChanged: observeFocus ? { [weak self] inside in
                guard let self, self.isVisible, self.resultRevision == revision else { return }
                self.accessibilityFocusInside = inside
                self.restartHideTimer()
            } : nil,
            speechVoice: preferences.speechVoice,
            speechRate: preferences.speechRate
        ).id(revision))
    }

    private func reveal() {
        guard let panel else { return }
        if !isVisible {
            visibilityRevision &+= 1
            panel.ignoresMouseEvents = false
            panel.alphaValue = reduceMotion ? 1 : 0
            panel.orderFrontRegardless()
            isVisible = true
            if !reduceMotion {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.20
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().alphaValue = 1
                }
            }
        } else {
            panel.orderFrontRegardless()
        }
    }

    private func restartHideTimer() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        // 字幕不需要自动隐藏，由用户或 Esc 收起
        guard isVisible, subtitle == nil, !pointerInside, !accessibilityFocusInside else { return }
        if case .loading? = state { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.accessibilityFocusInside, !self.contains(NSEvent.mouseLocation) else { return }
            self.hide()
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + preferences.autoHideInterval, execute: item)
    }

    private func resetResultFocus() {
        resultRevision &+= 1
        accessibilityFocusInside = false
    }

    // MARK: - Esc

    /// 全局监听不吞掉按键：Esc 同时仍会传给原应用；本地监听处理本应用获得焦点的情况。
    private func installEscapeMonitor() {
        guard escapeMonitor == nil, localEscapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            DispatchQueue.main.async { self?.hide() }
        }
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.hide() }
            return nil
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        if let localEscapeMonitor { NSEvent.removeMonitor(localEscapeMonitor) }
        localEscapeMonitor = nil
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
