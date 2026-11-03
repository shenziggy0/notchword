import AppKit
import Carbon.HIToolbox

/// 显式取词入口的选区读取。
///
/// 顺序：
///   1. Accessibility 直接读选区（不碰剪贴板，最快）
///   2. 读不到时模拟一次 ⌘C，把选中内容复制出来，**随后恢复原剪贴板**
///   3. 仍为空则交给调用方回退到剪贴板
///
/// 第 2 步只用于用户主动按 ⌥D / ⌥T，悬停和自动划词不会走这里，
/// 避免在读取鼠标位置时反复改写剪贴板。
enum SelectionCapture {

    struct Result {
        let text: String?
        let source: Source
    }

    enum Source {
        case accessibility
        case copy
        case empty

        var description: String {
            switch self {
            case .accessibility: return "Accessibility 选区"
            case .copy:          return "模拟复制选区"
            case .empty:         return "没有取到选区"
            }
        }
    }

    static func read() -> Result {
        guard Permissions.isAccessibilityTrusted else { return Result(text: nil, source: .empty) }

        if let text = AXPicker.selectedText() {
            return Result(text: text, source: .accessibility)
        }
        // 密码管理器里不做模拟复制，避免密码经过剪贴板
        guard !AppRules.isFrontmostExcluded else { return Result(text: nil, source: .empty) }
        if let text = copySelection() {
            return Result(text: text, source: .copy)
        }
        return Result(text: nil, source: .empty)
    }

    // MARK: - 模拟复制

    private static func copySelection() -> String? {
        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount
        let snapshot = PasteboardSnapshot(pasteboard)

        postCommandC()

        // 等目标应用把内容写进剪贴板，最多 300ms
        for _ in 0..<30 {
            if pasteboard.changeCount != before { break }
            usleep(10_000)
        }

        // 没有变化说明没有选区（或应用不响应 ⌘C），此时不必改写剪贴板
        guard pasteboard.changeCount != before else { return nil }

        let copied = (pasteboard.string(forType: .string) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        snapshot.restore(to: pasteboard)
        return copied.isEmpty ? nil : copied
    }

    private static func postCommandC() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyCode = CGKeyCode(kVK_ANSI_C)

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        usleep(20_000)
        up.post(tap: .cghidEventTap)
    }
}

/// 剪贴板快照：模拟复制会临时改写剪贴板，读完要原样放回去。
struct PasteboardSnapshot {

    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { entry[type] = data }
            }
            return entry
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        let objects: [NSPasteboardItem] = items.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pasteboard.clearContents()
        if !objects.isEmpty { pasteboard.writeObjects(objects) }
    }
}
