import AppKit
import CoreText
import SwiftUI

enum Lexicon {
    static let page = adaptive(0xF2F3F8, 0x14161E)
    static let surface = adaptive(0xFFFFFF, 0x21242F)
    static let accent = adaptive(0x265BC8, 0xA0C2FF)
    static let secondary = adaptive(0x525E70, 0xB1BBCD)
    static let hairline = adaptive(0xCBD2DE, 0x444A59)

    static let ink = color(0x0A0D14)
    static let indigo = color(0x294D91)
    static let onDarkAccent = color(0xA8C7FF)
    static let notchText = color(0xF4F6FC)
    static let notchSecondary = color(0xB9C3D3)
    static let notchMuted = color(0xA5AFC1)
    static let notchBase = color(0x1A202C)

    private static func color(_ rgb: Int) -> Color {
        Color(nsColor: nsColor(rgb))
    }

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

private struct ControlGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.lexiconSnapshot) private var snapshot

    @ViewBuilder
    func body(content: Content) -> some View {
        if snapshot || reduceTransparency || contrast == .increased {
            content.background(Lexicon.surface, in: shape)
                .overlay { shape.strokeBorder(Lexicon.secondary, lineWidth: contrast == .increased ? 1.5 : 1).allowsHitTesting(false) }
        } else {
            #if compiler(>=6.2)
            if #available(macOS 26, *) {
                content.glassEffect(.regular.interactive(interactive), in: shape)
            } else {
                material(content)
            }
            #else
            material(content)
            #endif
        }
    }

    private func material(_ content: Content) -> some View {
        content.background(.regularMaterial, in: shape)
            .overlay { shape.strokeBorder(Lexicon.hairline.opacity(0.75), lineWidth: 1).allowsHitTesting(false) }
    }
}

extension View {
    func lexiconPage() -> some View {
        tint(Lexicon.accent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Lexicon.page)
    }

    func lexiconGlass(in shape: some InsettableShape, interactive: Bool = false) -> some View {
        modifier(ControlGlass(shape: shape, interactive: interactive))
    }

    func notchSurface(compact: Bool = false) -> some View {
        let radius: CGFloat = compact ? 18 : 28
        let shape = UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: radius,
                                           bottomTrailingRadius: radius, topTrailingRadius: 0)
        return background(
            LinearGradient(stops: [.init(color: .black, location: 0),
                                   .init(color: Lexicon.ink, location: 0.35),
                                   .init(color: Lexicon.notchBase, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        )
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(LinearGradient(colors: [.clear, .white.opacity(0.08), .white.opacity(0.23)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .tint(Lexicon.onDarkAccent)
        .environment(\.colorScheme, .dark)
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
            .foregroundStyle(active ? Lexicon.onDarkAccent : Lexicon.notchText)
            .frame(width: 44, height: 44)
            .background(active ? Lexicon.indigo : .clear, in: Circle())
            .lexiconGlass(in: Circle(), interactive: true)
            .contentShape(Circle())
            .brightness(configuration.isPressed ? 0.12 : 0)
            .opacity(enabled ? 1 : 0.48)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.93 : 1)
            .animation(reduceMotion ? nil : .spring(duration: 0.22, bounce: 0.18), value: configuration.isPressed)
    }
}
