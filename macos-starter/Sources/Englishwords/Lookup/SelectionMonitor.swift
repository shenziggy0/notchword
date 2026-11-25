import AppKit

/// 划词查询。
///
/// 两条路：
///   1. 轮询焦点元素的选区（`AXSelectedText`）——原生文本控件最好用
///   2. 拖选结束后读不到选区时，模拟一次 ⌘C 取词并**还原剪贴板**——
///      很多 Electron / 画布类应用只支持 ⌘C，不暴露 AX 选区
///
/// 两条路都不抢焦点；同一段文字短时间内只弹一次。
@MainActor
final class SelectionMonitor {

    var onSubmit: ((LookupRequest) -> Void)?
    var isInsidePanel: ((NSPoint) -> Bool)?

    private let preferences: Preferences
    private var timer: Timer?
    private var pending: DispatchWorkItem?
    private var pendingDrag: DispatchWorkItem?
    private var mouseMonitors: [Any] = []

    private var dragStart: NSPoint?
    private var observedSelection = ""
    private var lastEmittedSelection = ""
    private var lastEmitTime: Date = .distantPast

    private let pollInterval: TimeInterval = 0.35
    private let settleDelay: TimeInterval = 0.25
    private let dragThreshold: CGFloat = 6

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    func start() {
        guard timer == nil else { return }

        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // 拖选结束的兜底：只记录鼠标位置，不拦截事件
        if let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            // 监控回调里直接采样，别等到 Task 再读（此时指针可能已移动）
            let point = NSEvent.mouseLocation
            Task { @MainActor in self?.dragStart = point }
        }) {
            mouseMonitors.append(down)
        }
        if let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in
            Task { @MainActor in self?.handleMouseUp() }
        }) {
            mouseMonitors.append(up)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pending?.cancel()
        pending = nil

        for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
        mouseMonitors.removeAll()

        pendingDrag?.cancel()
        pendingDrag = nil
        dragStart = nil
        observedSelection = ""
        lastEmittedSelection = ""
    }

    // MARK: - 轮询选区

    private func tick() {
        guard preferences.selectionEnabled, AppRules.allowsPassiveLookup() else { return }
        // 拖拽未松手时不提前查半截选区
        guard NSEvent.pressedMouseButtons == 0 else { return }

        let selection = AXPicker.selectedText()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if selection.isEmpty {
            observedSelection = ""
            pending?.cancel()
            pending = nil
            return
        }
        guard selection != observedSelection else { return }

        observedSelection = selection
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.fire(selection)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: work)
    }

    private func fire(_ selection: String) {
        guard preferences.selectionEnabled, AppRules.allowsPassiveLookup(),
              AXPicker.selectedText()?.trimmingCharacters(in: .whitespacesAndNewlines) == selection else { return }
        submit(selection)
    }

    // MARK: - 拖选兜底

    private func handleMouseUp() {
        guard preferences.selectionEnabled,
              AppRules.allowsPassiveLookup(),
              let start = dragStart else {
            dragStart = nil
            return
        }
        dragStart = nil

        let end = NSEvent.mouseLocation
        let distance = hypot(end.x - start.x, end.y - start.y)
        guard distance > dragThreshold, isInsidePanel?(end) != true else { return }

        // 等目标应用把选区状态更新完
        pendingDrag?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.captureAfterDrag() }
        pendingDrag = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func captureAfterDrag() {
        guard preferences.selectionEnabled, AppRules.allowsPassiveLookup() else { return }

        // 被动划词只走只读 AX，不模拟 ⌘C（避免污染剪贴板）
        guard let text = AXPicker.selectedText() else { return }
        observedSelection = text
        submit(text)
    }

    private func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if trimmed == lastEmittedSelection, Date().timeIntervalSince(lastEmitTime) < 4 { return }
        lastEmittedSelection = trimmed
        lastEmitTime = Date()

        onSubmit?(LookupRequest(
            text: trimmed,
            trigger: .selection,
            screen: Screens.screen(containing: NSEvent.mouseLocation),
            context: AXPicker.selectedContext(matching: trimmed)
        ))
    }
}
