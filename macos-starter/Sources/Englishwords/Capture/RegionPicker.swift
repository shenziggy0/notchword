import AppKit

/// 盖住所有屏幕的透明框选。松开鼠标后先关掉窗口，再把矩形交出去，避免把选框截进图里。
@MainActor
final class RegionPicker {

    private var windows: [RegionWindow] = []
    private var keyMonitors: [Any] = []
    private var onSelect: ((CGRect, NSScreen) -> Void)?

    var isPicking: Bool { !windows.isEmpty }

    func begin(onSelect: @escaping (CGRect, NSScreen) -> Void) {
        cancel()
        self.onSelect = onSelect
        let pointer = NSEvent.mouseLocation
        var keyboardWindow: RegionWindow?
        for screen in NSScreen.screens {
            let window = RegionWindow(screen: screen)
            window.onSelect = { [weak self] rect, pickedScreen in
                self?.finish(rect, on: pickedScreen)
            }
            window.onCancel = { [weak self] in self?.cancel() }
            windows.append(window)
            window.orderFrontRegardless()
            if screen.frame.contains(pointer) { keyboardWindow = window }
        }
        (keyboardWindow ?? windows.first)?.makeKeyAndOrderFront(nil)
        installEscapeMonitors()
    }

    func cancel() {
        for window in dismissWindows() {
            window.orderOut(nil)
            window.close()
        }
    }

    /// Esc 随时可取消：全局监听盖住未激活的情况，本地监听盖住窗口拿到焦点的情况。
    private func installEscapeMonitors() {
        removeEscapeMonitors()
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in self?.cancel() }
        }) {
            keyMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.cancel() }
            return nil
        }) {
            keyMonitors.append(local)
        }
    }

    private func removeEscapeMonitors() {
        for monitor in keyMonitors { NSEvent.removeMonitor(monitor) }
        keyMonitors.removeAll()
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
        removeEscapeMonitors()
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
private final class RegionWindow: NSPanel {
    var onSelect: ((CGRect, NSScreen) -> Void)?
    var onCancel: (() -> Void)?
    private let screenFrame: NSScreen

    init(screen: NSScreen) {
        screenFrame = screen
        // 直接用全局屏幕矩形调用指定初始化器，避免 AppKit 便利初始化再次进入子类。
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        let overlay = RegionOverlay()
        overlay.setAccessibilityElement(true)
        overlay.setAccessibilityRole(.group)
        overlay.setAccessibilityLabel("框选屏幕区域")
        overlay.setAccessibilityHelp("方向键移动，按住 Shift 加方向键调整大小。回车确认，Esc 取消。")
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
        guard let overlay = contentView as? RegionOverlay else {
            super.keyDown(with: event)
            return
        }
        let distance: CGFloat = event.modifierFlags.contains(.option) ? 1 : 8
        let resizing = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 53: onCancel?()
        case 36, 76:
            if overlay.selection != nil { endDrag() }
        case 123: overlay.adjust(dx: -distance, dy: 0, resize: resizing)
        case 124: overlay.adjust(dx: distance, dy: 0, resize: resizing)
        case 125: overlay.adjust(dx: 0, dy: -distance, resize: resizing)
        case 126: overlay.adjust(dx: 0, dy: distance, resize: resizing)
        default: super.keyDown(with: event)
        }
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
    private var usesKeyboard = false

    override var isFlipped: Bool { false }

    /// 首次点击就生效，不需要先激活应用。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
        usesKeyboard = false
        anchor = point
        selection = CGRect(origin: point, size: .zero)
        needsDisplay = true
    }

    func update(to point: CGPoint) {
        guard let anchor else { return }
        // 拖出窗口时仍钳位到可视区域内，避免选区越界
        let point = CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
        selection = CGRect(
            x: min(anchor.x, point.x),
            y: min(anchor.y, point.y),
            width: abs(point.x - anchor.x),
            height: abs(point.y - anchor.y)
        )
        needsDisplay = true
    }

    /// 方向键从屏幕中心开始选择；Shift 调整上边和右边，Option 单点微调。
    func adjust(dx: CGFloat, dy: CGFloat, resize: Bool) {
        usesKeyboard = true
        let initial = CGSize(width: min(180, bounds.width), height: min(64, bounds.height))
        var rect = selection ?? CGRect(x: bounds.midX - initial.width / 2,
                                       y: bounds.midY - initial.height / 2,
                                       width: initial.width, height: initial.height)
        if resize {
            rect.size.width = min(bounds.maxX - rect.minX, max(8, rect.width + dx))
            rect.size.height = min(bounds.maxY - rect.minY, max(8, rect.height + dy))
        } else {
            rect.origin.x = min(bounds.maxX - rect.width, max(bounds.minX, rect.minX + dx))
            rect.origin.y = min(bounds.maxY - rect.height, max(bounds.minY, rect.minY + dy))
        }
        selection = rect
        setAccessibilityValue("横向 \(Int(rect.minX))，纵向 \(Int(rect.minY))，宽 \(Int(rect.width))，高 \(Int(rect.height)) 点")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds)
        if let selection, selection.width > 0, selection.height > 0 {
            path.append(NSBezierPath(rect: selection))
        }
        path.windingRule = .evenOdd
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        NSColor(srgbRed: 0.03, green: 0.05, blue: 0.09, alpha: contrast ? 0.58 : 0.40).setFill()
        path.fill()
        guard let selection, selection.width > 1, selection.height > 1 else {
            badge("拖动框选或用方向键定位  ·  Esc 取消", center: CGPoint(x: bounds.midX, y: 46))
            return
        }
        let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
        NSColor.black.withAlphaComponent(0.75).setStroke()
        border.lineWidth = 3
        border.stroke()
        NSColor.white.setStroke()
        border.lineWidth = contrast ? 2 : 1
        border.stroke()
        let radius: CGFloat = contrast ? 4 : 3
        for x in [selection.minX, selection.maxX] {
            for y in [selection.minY, selection.maxY] {
                let handle = NSBezierPath(ovalIn: CGRect(x: x - radius, y: y - radius,
                                                         width: radius * 2, height: radius * 2))
                NSColor.white.setFill()
                handle.fill()
                NSColor(calibratedWhite: 0.18, alpha: 1).setStroke()
                handle.stroke()
            }
        }
        let size = "\(Int(selection.width.rounded())) × \(Int(selection.height.rounded())) 点"
        let caption = usesKeyboard ? "\(size)  ·  ⇧ 方向键调整大小  ·  回车确认" : size
        let preferredY = selection.minY > 44 ? selection.minY - 20 : selection.maxY + 20
        badge(caption, center: CGPoint(x: selection.midX, y: preferredY))
    }

    private func badge(_ text: String, center: CGPoint) {
        let label = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ])
        let labelSize = label.size()
        let size = CGSize(width: ceil(labelSize.width) + 26, height: ceil(labelSize.height) + 14)
        let origin = CGPoint(x: max(6, min(bounds.maxX - size.width - 6, center.x - size.width / 2)),
                             y: max(6, min(bounds.maxY - size.height - 6, center.y - size.height / 2)))
        let pill = NSBezierPath(roundedRect: CGRect(origin: origin, size: size),
                                xRadius: size.height / 2, yRadius: size.height / 2)
        let opaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        NSColor(calibratedWhite: 0.10, alpha: opaque ? 1 : 0.92).setFill()
        pill.fill()
        NSColor.white.withAlphaComponent(0.44).setStroke()
        pill.stroke()
        label.draw(at: CGPoint(x: origin.x + 13, y: origin.y + 7))
    }
}
