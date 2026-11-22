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

    static func read() async -> Result {
        // 注意：这里不要求辅助功能授权。AX 读取会自己检查权限，
        // 而模拟复制的按键投递在当前环境下不需要该授权（实测可用）。
        if let text = AXPicker.selectedText() {
            return Result(text: text, source: .accessibility)
        }
        // 密码管理器里不做模拟复制，避免密码经过剪贴板
        guard !AppRules.isFrontmostExcluded else { return Result(text: nil, source: .empty) }
        if let text = await copySelection() {
            return Result(text: text, source: .copy)
        }
        return Result(text: nil, source: .empty)
    }

    // MARK: - 模拟复制

    private static func copySelection() async -> String? {
        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount
        let snapshot = PasteboardSnapshot(pasteboard)

        FileLog.write("选区：AX 读不到，尝试模拟复制")
        await postCommandC()

        // 等目标应用把内容写进剪贴板，最多 300ms
        for _ in 0..<30 {
            if pasteboard.changeCount != before { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        // 没有变化说明没有选区（或应用不响应 ⌘C），此时不必改写剪贴板
        guard pasteboard.changeCount != before else {
            FileLog.write("选区：模拟复制无变化")
            return nil
        }

        let copied = (pasteboard.string(forType: .string) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 只有剪贴板仍是我们刚复制的文本时才还原，避免覆盖用户刚主动按的 ⌘C
        let current = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if current == copied {
            snapshot.restore(to: pasteboard)
            FileLog.write("选区：模拟复制得到 \(copied.count) 字符，已还原剪贴板")
        } else {
            FileLog.write("选区：模拟复制得到 \(copied.count) 字符，剪贴板已被改写，保留当前内容")
        }
        return copied.isEmpty ? nil : copied
    }

    private static func postCommandC() async {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCode = CGKeyCode(kVK_ANSI_C)

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        try? await Task.sleep(for: .milliseconds(20))
        up.post(tap: .cgSessionEventTap)
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
        let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        let objects: [NSPasteboardItem] = items.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            // 标记为瞬态，让剪贴板管理器忽略这次写回
            item.setData(Data(), forType: transient)
            return item
        }
        pasteboard.clearContents()
        if !objects.isEmpty { pasteboard.writeObjects(objects) }
    }
}
