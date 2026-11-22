import AppKit

/// 悬停取词：指针停留计时 + 节流 + 去重。
///
/// 只在停留达到阈值后才做 AX 查询，移动即取消；取不到词就静默。
@MainActor
final class HoverMonitor {

    var onSubmit: ((LookupRequest) -> Void)?
    var isInsidePanel: ((NSPoint) -> Bool)?

    private let preferences: Preferences
    private var timer: Timer?
    private var dwellWorkItem: DispatchWorkItem?
    private var lastPoint: NSPoint = .zero
    private var lastWord: String = ""
    private var lastWordTime: Date = .distantPast

    private let pollInterval: TimeInterval = 0.06
    private let movementThreshold: CGFloat = 2.5

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    func start() {
        guard timer == nil else { return }
        lastPoint = NSEvent.mouseLocation
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        dwellWorkItem?.cancel()
        dwellWorkItem = nil
    }

    private func tick() {
        // 鼠标按下时（拖拽/滚动）不触发悬停取词
        guard NSEvent.pressedMouseButtons == 0 else { return }
        let point = NSEvent.mouseLocation
        guard distance(point, lastPoint) > movementThreshold else { return }
        lastPoint = point

        dwellWorkItem?.cancel()
        dwellWorkItem = nil

        guard preferences.hoverEnabled,
              Permissions.isAccessibilityTrusted,
              AppRules.allowsPassiveLookup() else { return }
        if isInsidePanel?(point) == true { return }

        let work = DispatchWorkItem { [weak self] in
            self?.fire(at: point)
        }
        dwellWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + preferences.hoverDwell, execute: work)
    }

    private func fire(at point: NSPoint) {
        // 指针已经移开或按键仍按下：取消本次查询
        guard preferences.hoverEnabled, AppRules.allowsPassiveLookup(),
              NSEvent.pressedMouseButtons == 0,
              distance(NSEvent.mouseLocation, point) <= movementThreshold else { return }
        guard let candidate = AXPicker.word(at: Screens.accessibilityPoint(from: point)) else { return }

        let word = TextFilter.normalizeWord(candidate)
        guard !word.isEmpty, TextFilter.isSingleWord(candidate) else { return }

        if word == lastWord, Date().timeIntervalSince(lastWordTime) < 3 { return }
        lastWord = word
        lastWordTime = Date()

        onSubmit?(LookupRequest(
            text: candidate,
            trigger: .hover,
            screen: Screens.screen(containing: point)
        ))
    }

    private func distance(_ lhs: NSPoint, _ rhs: NSPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }
}
