import AppKit
import Carbon.HIToolbox

enum HotKeyError: LocalizedError {
    case handlerInstallFailed(OSStatus)
    case registerFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .handlerInstallFailed(let status):
            return "热键事件处理安装失败（\(status)）"
        case .registerFailed(let status):
            return "热键注册失败（\(status)），可能已被其他程序占用"
        }
    }
}

/// 全局热键（Carbon RegisterEventHotKey），支持注册多个。
///
/// 用 Carbon 而不是 NSEvent 全局监听，是因为前者**不需要辅助功能权限**，
/// 装完就能用，只有真正取词时才需要授权。
@MainActor
final class HotKeyCenter {

    private static let signature: OSType = 0x45574457 // 'EWDW'

    static let shared = HotKeyCenter()

    /// 录制快捷键时暂停触发，避免按下旧组合就弹面板。
    var isPaused = false

    private struct Entry {
        let ref: EventHotKeyRef
        let action: () -> Void
    }

    private var entries: [UInt32: Entry] = [:]
    private var handlerRef: EventHandlerRef?
    private var nextID: UInt32 = 1

    @discardableResult
    func register(keyCode: UInt32,
                  modifiers: UInt32,
                  action: @escaping () -> Void) -> Result<UInt32, HotKeyError> {
        if handlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))

            let installStatus = InstallEventHandler(
                GetApplicationEventTarget(),
                { _, event, userData in
                    guard let userData, let event else { return noErr }
                    let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()

                    var hotKeyID = EventHotKeyID()
                    let status = GetEventParameter(
                        event,
                        EventParamName(kEventParamDirectObject),
                        EventParamType(typeEventHotKeyID),
                        nil,
                        MemoryLayout<EventHotKeyID>.size,
                        nil,
                        &hotKeyID
                    )
                    guard status == noErr else { return noErr }
                    let identifier = hotKeyID.id
                    Task { @MainActor in center.fire(identifier) }
                    return noErr
                },
                1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef
            )
            guard installStatus == noErr else { return .failure(.handlerInstallFailed(installStatus)) }
        }

        let identifier = nextID
        nextID += 1

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: identifier)
        let registerStatus = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                                 GetApplicationEventTarget(), 0, &ref)
        guard registerStatus == noErr, let ref else {
            return .failure(.registerFailed(registerStatus))
        }

        entries[identifier] = Entry(ref: ref, action: action)
        return .success(identifier)
    }

    func unregister(id: UInt32) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(entry.ref)
    }

    func unregisterAll() {
        for entry in entries.values { UnregisterEventHotKey(entry.ref) }
        entries.removeAll()

        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
    }

    private func fire(_ identifier: UInt32) {
        guard !isPaused else { return }
        entries[identifier]?.action()
    }

    deinit {
        for entry in entries.values { UnregisterEventHotKey(entry.ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
