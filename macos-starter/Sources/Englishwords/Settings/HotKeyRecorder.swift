import AppKit
import Carbon.HIToolbox

@MainActor
final class HotKeyRecorder: ObservableObject {
    @Published private(set) var recording: String?
    @Published private(set) var message = ""
    private var monitor: Any?

    func begin(name: String, current: @escaping () -> [HotKeySpec], apply: @escaping (HotKeySpec) -> Void) {
        cancel()
        HotKeyCenter.shared.isPaused = true
        recording = name
        message = "按下新快捷键，Esc 取消。"
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = event.keyCode
            let flags = event.modifierFlags
            let handled = MainActor.assumeIsolated {
                guard let self else { return false }
                if code == kVK_Escape {
                    self.cancel()
                    return true
                }
                var modifiers: UInt32 = 0
                for (flag, carbon) in [(NSEvent.ModifierFlags.command, cmdKey), (.option, optionKey),
                                       (.control, controlKey), (.shift, shiftKey)] where flags.contains(flag) {
                    modifiers |= UInt32(carbon)
                }
                guard modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 else {
                    self.message = "请搭配 ⌘、⌥ 或 ⌃。"
                    return true
                }
                let spec = HotKeySpec(keyCode: UInt32(code), modifiers: modifiers)
                guard !current().contains(spec) else {
                    self.message = "这个组合已分配给其他功能。"
                    return true
                }
                self.cancel()
                apply(spec)
                return true
            }
            return handled ? nil : event
        }
    }

    func cancel() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
        message = ""
        HotKeyCenter.shared.isPaused = false
    }
}
