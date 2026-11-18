// 生成 Englishwords 应用图标：白底黑字。
// 用法：swift scripts/make_icon.swift <variant> <输出目录>
//   variant: ew | aa | e
// 输出：<输出目录>/icon_1024.png 与 AppIcon.iconset/（交给 iconutil 生成 .icns）
import AppKit
import CoreText

let args = CommandLine.arguments
let variant = args.count > 1 ? args[1] : "e"
let outDir = URL(fileURLWithPath: args.count > 2 ? args[2] : "build/icon")

/// 系统衬线字体（New York），按字重取。
func serifFont(_ size: CGFloat, weight: NSFont.Weight) -> CTFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    let desc = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
    let font = (NSFont(descriptor: desc, size: size) ?? base) as CTFont
    // 大字号默认会用高反差的展示切（发丝线极细），小尺寸图标里会消失；
    // 固定光学尺寸为正文切，笔画更结实。
    let opsz = 0x6F70_737A  // 'opsz'
    let varDesc = CTFontDescriptorCreateCopyWithVariation(
        CTFontCopyFontDescriptor(font), opsz as CFNumber, 20)
    return CTFontCreateWithFontDescriptor(varDesc, size, nil)
}

/// 在 1024 画布上绘制图标；按 macOS 图标网格，主体为 824 圆角方块。
func draw(_ ctx: CGContext, side: CGFloat) {
    let s = side / 1024
    ctx.scaleBy(x: s, y: s)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    // 柔和投影：白色图标在浅色 Finder 背景上也能看清边界
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28,
                  color: CGColor(gray: 0, alpha: 0.28))
    ctx.addPath(path)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // 细描边
    ctx.addPath(path)
    ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.08))
    ctx.setLineWidth(3)
    ctx.strokePath()

    let black = CGColor(gray: 0.06, alpha: 1)

    // 顶部“刘海”：呼应刘海查词面板
    let notch = CGRect(x: 512 - 150, y: 924 - 74, width: 300, height: 74)
    let notchPath = CGMutablePath()
    let r: CGFloat = 34
    notchPath.move(to: CGPoint(x: notch.minX - 22, y: notch.maxY))
    notchPath.addQuadCurve(to: CGPoint(x: notch.minX, y: notch.maxY - 22),
                           control: CGPoint(x: notch.minX, y: notch.maxY))
    notchPath.addLine(to: CGPoint(x: notch.minX, y: notch.minY + r))
    notchPath.addQuadCurve(to: CGPoint(x: notch.minX + r, y: notch.minY),
                           control: CGPoint(x: notch.minX, y: notch.minY))
    notchPath.addLine(to: CGPoint(x: notch.maxX - r, y: notch.minY))
    notchPath.addQuadCurve(to: CGPoint(x: notch.maxX, y: notch.minY + r),
                           control: CGPoint(x: notch.maxX, y: notch.minY))
    notchPath.addLine(to: CGPoint(x: notch.maxX, y: notch.maxY - 22))
    notchPath.addQuadCurve(to: CGPoint(x: notch.maxX + 22, y: notch.maxY),
                           control: CGPoint(x: notch.maxX, y: notch.maxY))
    notchPath.closeSubpath()
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.addPath(notchPath)
    ctx.setFillColor(black)
    ctx.fillPath()
    ctx.restoreGState()

    // 主体文字
    let text: String
    let font: CTFont
    switch variant {
    case "aa": text = "Aa"; font = serifFont(460, weight: .semibold)
    case "e":  text = "E";  font = serifFont(560, weight: .semibold)
    default:   text = "Ew"; font = serifFont(470, weight: .semibold)
    }
    let attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): black,
        NSAttributedString.Key(kCTKernAttributeName as String): variant == "e" ? 0 : -14,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    // 用字形实际墨迹边界居中，避免字体留白导致偏移
    let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    let centerY: CGFloat = 470   // 略低于几何中心，给刘海留出视觉空间
    ctx.textPosition = CGPoint(x: 512 - ink.midX, y: centerY - ink.midY)
    CTLineDraw(line, ctx)
}

func render(_ side: Int) -> Data {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    draw(ctx, side: CGFloat(side))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try render(1024).write(to: outDir.appendingPathComponent("icon_1024.png"))
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("OK \(variant) -> \(outDir.path)")
