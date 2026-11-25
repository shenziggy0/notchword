// 用法：swift macos-starter/scripts/make_icon.swift [输出目录]
// 以 README 使用的 1024px 主图为唯一图源，导出 macOS iconset 和 Windows ICO。
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

func thumbnail(_ side: Int) throws -> CGImage {
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
