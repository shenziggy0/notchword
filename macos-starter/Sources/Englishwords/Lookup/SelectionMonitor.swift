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
    private var mouseMonitors: [Any] = []

    private var dragStart: NSPoint?
    private var lastSelection = ""
    private var lastEmitTime: Date = .distantPast

    private let pollInterval: TimeInterval = 0.35
    private let settleDelay: TimeInterval = 0.25
    private let dragThreshold: CGFloat = 6

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    func start() {
        stop()

        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // 拖选结束的兜底：只记录鼠标位置，不拦截事件
        if let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            Task { @MainActor in self?.dragStart = NSEvent.mouseLocation }
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

        dragStart = nil
        lastSelection = ""
    }

    // MARK: - 轮询选区

    private func tick() {
        guard preferences.selectionEnabled, AppRules.allowsPassiveLookup() else { return }

        let selection = AXPicker.selectedText()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if selection.isEmpty {
            lastSelection = ""
            pending?.cancel()
            pending = nil
            return
        }
        guard selection != lastSelection else { return }

        lastSelection = selection
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.fire(selection) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: work)
    }

    private func fire(_ selection: String) {
        guard AXPicker.selectedText()?.trimmingCharacters(in: .whitespacesAndNewlines) == selection else { return }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            Task { @MainActor in self?.captureAfterDrag() }
        }
    }

    private func captureAfterDrag() {
        guard preferences.selectionEnabled, AppRules.allowsPassiveLookup() else { return }

        if let text = AXPicker.selectedText() {
            lastSelection = text
            submit(text)
            return
        }
        // AX 读不到（常见于 Electron）：走模拟复制，读完还原剪贴板
        guard let text = SelectionCapture.read().text else { return }
        submit(text)
    }

    private func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if trimmed == lastSelection, Date().timeIntervalSince(lastEmitTime) < 4 { return }
        lastSelection = trimmed
        lastEmitTime = Date()

        onSubmit?(LookupRequest(
            text: trimmed,
            trigger: .selection,
            screen: Screens.screen(containing: NSEvent.mouseLocation)
        ))
    }
}
