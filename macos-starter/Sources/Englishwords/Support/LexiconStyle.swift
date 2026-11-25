import AppKit
import CoreText
import SwiftUI

enum Lexicon {
    static let page = adaptive(0xFBFBFB, 0x101011)
    static let surface = adaptive(0xFFFFFF, 0x141416)
    static let subtle = adaptive(0xF3F3F4, 0x222224)
    static let ink = adaptive(0x1D1D1F, 0xF0EFED)
    static let secondary = adaptive(0x3C3C43, 0xCFCECC)
    static let hairline = adaptive(0xEAEAEA, 0x2C2C2F)
    static let edge = adaptive(0xD6D6DA, 0x414145)
    static let accent = adaptive(0x2F6FEB, 0x3672D6)
    // 小字号蓝字在浅色实底和深色选中底上都须保持可读。
    static let link = adaptive(0x255BC1, 0xA4C6FF)
    static let selected = adaptive(0xE8F0FE, 0x203451)
    static let focus = adaptive(0x3B82F6, 0x88B3FF)
    static let glassWash = Color.white.opacity(0.82)
    static let glassHighlight = Color.white.opacity(0.88)

    private static func adaptive(_ light: Int, _ dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            nsColor(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        })
    }

    private static func nsColor(_ rgb: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}

private struct LexiconSnapshotKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// ImageRenderer 没有窗口合成器，系统玻璃在离屏导出中需要使用实体底色。
    var lexiconSnapshot: Bool {
        get { self[LexiconSnapshotKey.self] }
        set { self[LexiconSnapshotKey.self] = newValue }
    }
}

enum LexiconTheme: String, CaseIterable {
    case system, light, dark
    static let defaultsKey = "appearance.theme"

    static var current: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system
    }

    var label: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

private struct ControlGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.lexiconSnapshot) private var snapshot

    func body(content: Content) -> some View {
        content.background {
            if snapshot || reduceTransparency || contrast == .increased {
                shape.fill(Lexicon.surface)
            } else {
                glassBackground
                    .overlay { shape.inset(by: 1).strokeBorder(Lexicon.glassHighlight, lineWidth: 1) }
            }
        }
        .overlay { shape.strokeBorder(Lexicon.edge, lineWidth: 1).allowsHitTesting(false) }
        .environment(\.colorScheme, .light)
    }

    @ViewBuilder private var glassBackground: some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            Color.clear.glassEffect(.regular.tint(Lexicon.glassWash), in: shape)
        } else {
            frostedMaterial
        }
        #else
        frostedMaterial
        #endif
    }

    private var frostedMaterial: some View {
        shape.fill(.regularMaterial).overlay { shape.fill(Lexicon.glassWash) }
    }
}

extension View {
    func lexiconPage() -> some View {
        tint(Lexicon.accent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Lexicon.page)
    }

    func lexiconGlass(in shape: some InsettableShape) -> some View {
        modifier(ControlGlass(shape: shape))
    }

    func notchSurface(compact: Bool = false) -> some View {
        let radius: CGFloat = compact ? 12 : 16
        let shape = UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: radius,
                                           bottomTrailingRadius: radius, topTrailingRadius: 0)
        return background(Lexicon.surface)
            .clipShape(shape)
            .overlay { shape.strokeBorder(Lexicon.edge, lineWidth: 1).allowsHitTesting(false) }
            .tint(Lexicon.link)
            .foregroundStyle(Lexicon.ink)
    }
}

/// 与 Windows 和演示共用 Lucide 的图形含义；字体随应用离线分发。
struct LexiconIcon: View {
    enum Glyph: String {
        case book = "\u{e063}", bookmark = "\u{e064}", bookmarked = "\u{e523}"
        case history = "\u{e1f4}", chart = "\u{e06c}", search = "\u{e154}"
        case volume = "\u{e1aa}", stop = "\u{e16a}", trash = "\u{e18d}"
        case previous = "\u{e072}", next = "\u{e073}"
    }

    private static let fontName: String = {
        guard let url = AppResources.lucideFontURL() else { return "lucide" }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        return "lucide"
    }()

    let glyph: Glyph
    let size: CGFloat
    init(_ glyph: Glyph, size: CGFloat = 17) {
        self.glyph = glyph
        self.size = size
    }
    var body: some View {
        Text(verbatim: glyph.rawValue)
            .font(.custom(Self.fontName, fixedSize: size))
            .accessibilityHidden(true)
    }
}

struct LexiconIconButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(active ? Lexicon.link : Lexicon.secondary)
            .frame(width: 32, height: 32)
            .background(active ? Lexicon.selected : Lexicon.subtle, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.48)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
