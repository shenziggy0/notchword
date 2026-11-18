import AppKit
import ApplicationServices
import Foundation

/// Accessibility 取词。
///
/// 两个入口：
///   - 选区：焦点元素的 `AXSelectedText`
///   - 指针：`AXUIElementCopyElementAtPosition` 命中元素后，用
///     `AXBoundsForRange` 反查指针下的字符，再向两侧扩成单词。
///
/// 指针范围无法可靠定位时**不提交整段内容**（否则一段正文会被当成短句翻译）。
enum AXPicker {

    // MARK: - 选区

    /// 读取当前选区。
    ///
    /// 不同应用暴露选区的方式不一样：有的给 `AXSelectedText`，有的只给
    /// `AXSelectedTextRange` + `AXStringForRange`，还有的把选区挂在父节点上。
    /// 这里逐级兜底，避免「明明选中了却读不到」。
    static func selectedText() -> String? {
        guard Permissions.isAccessibilityTrusted, let focused = focusedElement() else { return nil }

        if let text = selectionText(of: focused) { return text }

        var element: AXUIElement? = focused
        for _ in 0..<3 {
            guard let current = element, let parent = parent(of: current) else { break }
            if let text = selectionText(of: parent) { return text }
            element = parent
        }
        return nil
    }

    private static func selectionText(of element: AXUIElement) -> String? {
        if let text = stringAttribute(element, "AXSelectedText")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }
        if let range = selectedRange(of: element), range.length > 0,
           let text = string(for: range, in: element)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }
        return nil
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextRange" as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func string(for range: CFRange, in element: AXUIElement) -> String? {
        var mutableRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, "AXStringForRange" as CFString, rangeValue, &result
        ) == .success else { return nil }
        return result as? String
    }

    /// 诊断用：焦点元素的角色，不读取内容。
    static func focusedRole() -> String? {
        guard let element = focusedElement() else { return nil }
        return stringAttribute(element, "AXRole")
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXParent" as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, "AXFocusedUIElement" as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    // MARK: - 指针

    static func word(at point: CGPoint) -> String? {
        guard Permissions.isAccessibilityTrusted, let element = element(at: point) else { return nil }

        if let role = stringAttribute(element, "AXRole"),
           role == "AXMenuBar" || role == "AXMenuBarItem" || role == "AXMenu" || role == "AXMenuItem" {
            return nil
        }

        // 命中的常常是 AXGroup / AXScrollArea，真正带文字的视图在子节点里
        let textElement = textBearingElement(at: point, in: element) ?? element
        guard let text = textContent(of: textElement), !text.isEmpty else { return nil }

        if let index = characterIndex(at: point, in: textElement, text: text),
           let word = wordAround(index, in: text) {
            return word
        }

        // 元素本身就是一小段文本（按钮标题、链接文字等）时直接使用
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 48, !trimmed.contains("\n"), TextFilter.isSingleWord(trimmed) {
            return trimmed
        }
        return nil
    }

    /// 诊断用：说明指针下命中了什么元素、能否定位字符。
    static func describe(at point: CGPoint) -> String {
        guard let element = element(at: point) else { return "no-element" }
        let role = stringAttribute(element, "AXRole") ?? "?"
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let owner = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
        let value = textContent(of: element) ?? ""
        let index = characterIndex(at: point, in: element, text: value)
        let charBounds = index.flatMap { Self.bounds(for: $0, in: element) }
        return "owner=\(owner) role=\(role) len=\(value.count) index=\(index.map(String.init) ?? "nil") bounds=\(charBounds.map { "\($0)" } ?? "nil") head=\(value.prefix(24))"
    }

    /// 向下找真正带文字的视图；元素的 frame 必须包含指针，避免拿到整页容器。
    private static func textBearingElement(at point: CGPoint,
                                           in element: AXUIElement,
                                           depth: Int = 0) -> AXUIElement? {
        if let text = textContent(of: element), !text.isEmpty { return element }
        guard depth < 5 else { return nil }

        for child in children(of: element) {
            if let frame = frame(of: child), !frame.contains(point) { continue }
            if let found = textBearingElement(at: point, in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXChildren" as CFString, &value) == .success,
              let value else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXPosition" as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, "AXSize" as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func element(at point: CGPoint) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &value) == .success,
              let element = value else { return nil }

        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success, pid == getpid() { return nil }
        return element
    }

    private static func textContent(of element: AXUIElement) -> String? {
        for attribute in ["AXValue", "AXTitle", "AXDescription"] {
            if let text = stringAttribute(element, attribute), !text.isEmpty { return text }
        }
        return nil
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value else { return nil }
        return value as? String
    }

    // MARK: - 字符定位

    private static func characterIndex(at point: CGPoint, in element: AXUIElement, text: String) -> Int? {
        let length = (text as NSString).length
        guard length > 0, length <= 20000 else { return nil }

        var low = 0
        var high = length - 1
        var found: Int?

        while low <= high {
            let mid = (low + high) / 2
            guard let rect = bounds(for: mid, in: element) else { return found }
            if rect.maxY < point.y - 1 {
                low = mid + 1
            } else if rect.minY > point.y + 1 {
                high = mid - 1
            } else if rect.maxX < point.x {
                found = mid
                low = mid + 1
            } else if rect.minX > point.x {
                high = mid - 1
            } else {
                return mid
            }
        }
        return found
    }

    private static func bounds(for index: Int, in element: AXUIElement) -> CGRect? {
        var range = CFRange(location: index, length: 1)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }

        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, "AXBoundsForRange" as CFString, rangeValue, &result
        ) == .success, let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(result as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    private static func wordAround(_ index: Int, in text: String) -> String? {
        let ns = text as NSString
        guard index >= 0, index < ns.length else { return nil }

        let allowed = CharacterSet.letters.union(CharacterSet(charactersIn: "-'’"))
        func isWordCharacter(_ position: Int) -> Bool {
            guard position >= 0, position < ns.length,
                  let scalar = UnicodeScalar(ns.character(at: position)) else { return false }
            return allowed.contains(scalar)
        }
        guard isWordCharacter(index) else { return nil }

        var start = index
        var end = index
        while start > 0, isWordCharacter(start - 1) { start -= 1 }
        while end + 1 < ns.length, isWordCharacter(end + 1) { end += 1 }

        let candidate = ns.substring(with: NSRange(location: start, length: end - start + 1))
        return TextFilter.normalizeWord(candidate).isEmpty ? nil : candidate
    }
}
