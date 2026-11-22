import AppKit

// 菜单栏 App（无 Dock 图标），用 main.swift 而不是 @main，
// 这样可以直接控制 NSApplication 的生命周期与激活策略。
let app = NSApplication.shared

// 资源自检：不启动 UI，直接查一个词并打印结果，用退出码表示成功与否。
// 打包后可用它验证「随包词库能被加载」。
if let index = CommandLine.arguments.firstIndex(of: "--check-word"),
   index + 1 < CommandLine.arguments.count {
    let word = CommandLine.arguments[index + 1]
    MainActor.assumeIsolated {
        let store = DictionaryStore()
        switch store.lookup(word) {
        case .success(let entry?):
            print("OK \(entry.word) | \(entry.translation.prefix(80))")
            if let morphology = store.morphology(word), !morphology.segments.isEmpty {
                print("PARTS \(morphology.segments.map(\.label).joined(separator: " / "))")
                if !morphology.origin.isEmpty { print("ORIGIN \(morphology.origin)") }
            }
            exit(0)
        case .success(nil):
            print("MISS \(word)")
            exit(2)
        case .failure(let error):
            print("ERROR \(error.localizedDescription)")
            exit(3)
        }
    }
}

// 取词诊断：输出授权、前台应用、选区可读性与指针取词结果。
if CommandLine.arguments.contains("--diagnose") {
    MainActor.assumeIsolated {
        print(Diagnostics.report())
        exit(0)
    }
}

// 指针取词自检：按 Accessibility 坐标（左上原点）取词，用于验证 AX 链路。
if let index = CommandLine.arguments.firstIndex(of: "--pick-word"),
   index + 2 < CommandLine.arguments.count,
   let x = Double(CommandLine.arguments[index + 1]),
   let y = Double(CommandLine.arguments[index + 2]) {
    MainActor.assumeIsolated {
        guard Permissions.isAccessibilityTrusted else {
            print("DENIED 辅助功能未授权")
            exit(4)
        }
        if let word = AXPicker.word(at: CGPoint(x: x, y: y)) {
            print("WORD \(word)")
            exit(0)
        }
        print("NONE \(AXPicker.describe(at: CGPoint(x: x, y: y)))")
        exit(5)
    }
}

// 翻译自检：跑一次真实的 Apple 本地翻译后退出，用于验证语言包与会话托管。
if let index = CommandLine.arguments.firstIndex(of: "--translate"),
   index + 1 < CommandLine.arguments.count {
    let text = CommandLine.arguments[index + 1]
    MainActor.assumeIsolated {
        app.setActivationPolicy(.accessory)
        Task {
            do {
                let result = try await AppleTranslate().translate(
                    TranslationRequest(text: text, source: "en", target: "zh-Hans")
                )
                print("OK \(result.providerName) | \(result.text)")
                exit(0)
            } catch {
                print("ERROR \(error.localizedDescription)")
                exit(1)
            }
        }
        app.run()
    }
}

// 自检模式：离屏渲染一张结果面板的预览图后退出，不启动事件循环。
if let index = CommandLine.arguments.firstIndex(of: "--render-preview"),
   index + 1 < CommandLine.arguments.count {
    let target = CommandLine.arguments[index + 1]
    let demo = index + 2 < CommandLine.arguments.count
        ? PreviewRenderer.Demo(rawValue: CommandLine.arguments[index + 2]) ?? .word
        : .word
    let ok = MainActor.assumeIsolated { PreviewRenderer.render(to: target, demo: demo) }
    exit(ok ? 0 : 1)
}

// NSApplication 与 AppDelegate 都在主线程上创建；顶层代码在 Swift 5 模式下
// 不被视为 MainActor 隔离，这里显式声明。
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
