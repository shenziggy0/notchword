import AppKit

/// 盖住所有屏幕的透明框选。松开鼠标后先关掉窗口，再把矩形交出去，避免把选框截进图里。
@MainActor
final class RegionPicker {

    private var windows: [RegionWindow] = []
    private var onSelect: ((CGRect, NSScreen) -> Void)?

    var isPicking: Bool { !windows.isEmpty }

    func begin(onSelect: @escaping (CGRect, NSScreen) -> Void) {
        cancel()
        self.onSelect = onSelect
        for screen in NSScreen.screens {
            let window = RegionWindow(screen: screen)
            window.onSelect = { [weak self] rect, pickedScreen in
                self?.finish(rect, on: pickedScreen)
            }
            window.onCancel = { [weak self] in self?.cancel() }
            windows.append(window)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func cancel() {
        for window in dismissWindows() {
            window.orderOut(nil)
            window.close()
        }
    }

    private func finish(_ rect: CGRect, on screen: NSScreen) {
        let callback = onSelect
        let active = dismissWindows()
        DispatchQueue.main.async {
            for window in active {
                window.orderOut(nil)
                window.close()
            }
            callback?(rect, screen)
        }
    }

    @discardableResult
    private func dismissWindows() -> [RegionWindow] {
        let active = windows
        windows.removeAll()
        onSelect = nil
        for window in active {
            window.onSelect = nil
            window.onCancel = nil
        }
        return active
    }
}

@MainActor
private final class RegionWindow: NSWindow {
    var onSelect: ((CGRect, NSScreen) -> Void)?
    var onCancel: (() -> Void)?
    private let screenFrame: NSScreen

    init(screen: NSScreen) {
        screenFrame = screen
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        let overlay = RegionOverlay()
        contentView = overlay
        overlay.onMouseDown = { [weak self] point in self?.beginDrag(at: point) }
        overlay.onMouseDrag = { [weak self] point in self?.updateDrag(to: point) }
        overlay.onMouseUp = { [weak self] in self?.endDrag() }
        overlay.onCancel = { [weak self] in self?.onCancel?() }
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        makeFirstResponder(self)
    }

    private func beginDrag(at point: CGPoint) {
        (contentView as? RegionOverlay)?.begin(at: point)
    }

    private func updateDrag(to point: CGPoint) {
        (contentView as? RegionOverlay)?.update(to: point)
    }

    private func endDrag() {
        guard let overlay = contentView as? RegionOverlay else { return }
        guard let local = overlay.selection, local.width >= 8, local.height >= 8 else {
            onCancel?()
            return
        }
        let inWindow = overlay.convert(local, to: nil)
        onSelect?(convertToScreen(inWindow), screenFrame)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

}

private final class RegionOverlay: NSView {
    var onMouseDown: ((CGPoint) -> Void)?
    var onMouseDrag: ((CGPoint) -> Void)?
    var onMouseUp: (() -> Void)?
    var onCancel: (() -> Void)?

    private var anchor: CGPoint?
    private(set) var selection: CGRect?

    override var isFlipped: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?(convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        onMouseDrag?(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        onMouseDrag?(convert(event.locationInWindow, from: nil))
        onMouseUp?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    func begin(at point: CGPoint) {
        anchor = point
        selection = CGRect(origin: point, size: .zero)
        needsDisplay = true
    }

    func update(to point: CGPoint) {
        guard let anchor else { return }
        selection = CGRect(
            x: min(anchor.x, point.x),
            y: min(anchor.y, point.y),
            width: abs(point.x - anchor.x),
            height: abs(point.y - anchor.y)
        )
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds)
        if let selection, selection.width > 0, selection.height > 0 {
            path.append(NSBezierPath(rect: selection))
        }
        path.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.35).setFill()
        path.fill()

        guard let selection, selection.width > 1, selection.height > 1 else { return }
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }
}
