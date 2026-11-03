import AppKit

/// 划词查询：轮询焦点元素的选中文字，选择稳定后提交。
///
/// 与悬停一样，不读剪贴板、不抢焦点；重复选中同一段文字不会连续弹窗。
@MainActor
final class SelectionMonitor {

    var onSubmit: ((LookupRequest) -> Void)?

    private let preferences: Preferences
    private var timer: Timer?
    private var pending: DispatchWorkItem?
    private var lastSelection: String = ""

    private let pollInterval: TimeInterval = 0.35
    private let settleDelay: TimeInterval = 0.25

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
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pending?.cancel()
        pending = nil
        lastSelection = ""
    }

    private func tick() {
        guard preferences.selectionEnabled,
              Permissions.isAccessibilityTrusted,
              AppRules.allowsPassiveLookup() else { return }

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
        // 选择已经变化或清空：放弃这次
        guard AXPicker.selectedText()?.trimmingCharacters(in: .whitespacesAndNewlines) == selection else { return }
        onSubmit?(LookupRequest(
            text: selection,
            trigger: .selection,
            screen: Screens.screen(containing: NSEvent.mouseLocation)
        ))
    }
}
