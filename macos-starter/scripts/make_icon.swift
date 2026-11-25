// 用法：swift macos-starter/scripts/make_icon.swift [输出目录]
// 导出 macOS iconset 和 Windows ICO。常规尺寸取自 README 主图，小尺寸使用像素对齐的书封。
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let macProject = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let master = macProject.deletingLastPathComponent().appendingPathComponent("docs/images/logo.png")
let output = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }
    ?? macProject.appendingPathComponent("build/icon")
guard let source = CGImageSourceCreateWithURL(master as CFURL, nil) else {
    throw CocoaError(.fileReadCorruptFile)
}

/// 16–32px 时放大书封并省略衬线，让 E 的三个横笔在任务栏里仍然分得开。
func smallCover(_ side: Int) throws -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw CocoaError(.fileWriteUnknown)
    }
    context.translateBy(x: 0, y: CGFloat(side))
    let scale = CGFloat(side) / 16
    context.scaleBy(x: scale, y: -scale)
    func rounded(_ rect: CGRect, _ radius: CGFloat, _ color: CGColor) {
        context.setFillColor(color)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
    }

    let paper = CGColor(srgbRed: 0.99, green: 0.99, blue: 0.98, alpha: 1)
    let blue = CGColor(srgbRed: 0.15, green: 0.37, blue: 0.82, alpha: 1)
    rounded(CGRect(x: 0.5, y: 0.5, width: 15, height: 15), 3.4, paper)
    rounded(CGRect(x: 2.5, y: 1.5, width: 11, height: 13), 1.6, blue)
    context.setFillColor(paper)
    context.fill(CGRect(x: 5, y: 4, width: 2, height: 7))
    for (y, width) in [(4.0, 6.0), (7.0, 5.0), (10.0, 6.0)] {
        context.fill(CGRect(x: 5, y: y, width: width, height: 1.25))
    }
    rounded(CGRect(x: 4, y: 12.5, width: 8.5, height: 0.8), 0.4, paper)
    guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
    return image
}

func thumbnail(_ side: Int) throws -> CGImage {
    if side <= 32 { return try smallCover(side) }
    let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                   kCGImageSourceThumbnailMaxPixelSize: side] as CFDictionary
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
          image.width == side, image.height == side else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return image
}

func write(_ url: URL, type: UTType, sizes: [Int]) throws {
    guard let file = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, sizes.count, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    for size in sizes {
        CGImageDestinationAddImage(file, try thumbnail(size), nil)
    }
    guard CGImageDestinationFinalize(file) else { throw CocoaError(.fileWriteUnknown) }
}

let iconset = output.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try write(iconset.appendingPathComponent("icon_\(base)x\(base).png"), type: .png, sizes: [base])
    try write(iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"), type: .png, sizes: [base * 2])
}
try write(output.appendingPathComponent("AppIcon.ico"), type: .ico, sizes: [16, 24, 32, 48, 64, 256])
