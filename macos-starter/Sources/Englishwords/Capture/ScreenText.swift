import AppKit
import CoreGraphics
import ScreenCaptureKit
import Vision

enum ScreenTextError: LocalizedError {
    case notAuthorized
    case capture(String)
    case recognition(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:     return "没有屏幕录制权限。"
        case .capture(let detail): return "截图失败：\(detail)"
        case .recognition(let detail): return "文字识别失败：\(detail)"
        }
    }
}

/// Vision 识别框。坐标归一化，原点在图像左下角。
struct RecognizedFragment {
    var text: String
    var x: Double
    var y: Double
}

/// 屏幕区域识别。截图只留在内存里，不写磁盘。
enum ScreenText {

    /// 同一行的 y 差距上限（归一化坐标）。0.80 与 0.81 算一行，0.60 另起一行。
    /// 阈值放宽到 0.035，避免带下伸字母的紧密单行被拆成两行。
    static let lineThreshold = 0.035

    private struct CapturePlan {
        let displayID: CGDirectDisplayID?
        let sourceRect: CGRect
        let scale: CGFloat
    }

    static func recognize(rect: CGRect, on screen: NSScreen) async throws -> String {
        guard Permissions.isScreenCaptureGranted else { throw ScreenTextError.notAuthorized }
        try Task.checkCancellation()
        // 屏幕几何必须在主线程读；截图与识别放到后台。
        let plan = await Self.capturePlan(rect: rect, screen: screen)
        let image = try await capture(plan)
        try Task.checkCancellation()
        let fastText = try? recognize(image, level: .fast)
        try Task.checkCancellation()
        if let text = fastText, !text.isEmpty {
            return text
        }
        do {
            let text = try recognize(image, level: .accurate)
            try Task.checkCancellation()
            return text
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ScreenTextError {
            throw error
        } catch {
            throw ScreenTextError.recognition(error.localizedDescription)
        }
    }

    @MainActor
    private static func capturePlan(rect: CGRect, screen: NSScreen) -> CapturePlan {
        CapturePlan(displayID: displayID(of: screen),
                    sourceRect: sourceRect(rect, on: screen),
                    scale: screen.backingScaleFactor)
    }

    /// 按 y 接近程度归行，行内按 x 从左到右。阅读顺序是从上到下。
    static func mergeLines(_ fragments: [RecognizedFragment]) -> [String] {
        let sorted = fragments.sorted { $0.y > $1.y }
        var lines: [[RecognizedFragment]] = []
        for fragment in sorted {
            if let anchor = lines.last?.first, abs(anchor.y - fragment.y) <= lineThreshold {
                lines[lines.count - 1].append(fragment)
            } else {
                lines.append([fragment])
            }
        }
        return lines.map { line in
            line.sorted { $0.x < $1.x }.map(\.text).joined(separator: " ")
        }
    }

    // MARK: - 截图

    /// `rect` 使用 AppKit 全局坐标（左下原点）。转成该显示器内、左上原点的 sourceRect。
    private static func capture(_ plan: CapturePlan) async throws -> CGImage {
        let local = plan.sourceRect
        guard local.width >= 1, local.height >= 1 else {
            throw ScreenTextError.capture("区域太小")
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ScreenTextError.capture(error.localizedDescription)
        }
        guard let displayID = plan.displayID,
              let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenTextError.capture("找不到对应的显示器")
        }

        // 排除本应用的所有窗口（框选遮罩 / 刘海面板），避免截进自家黑框
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        let configuration = SCStreamConfiguration()
        let scale = plan.scale
        configuration.sourceRect = local
        configuration.width = max(1, Int((local.width * scale).rounded()))
        configuration.height = max(1, Int((local.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.capturesAudio = false

        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            throw ScreenTextError.capture(error.localizedDescription)
        }
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    private static func sourceRect(_ rect: CGRect, on screen: NSScreen) -> CGRect {
        let frame = screen.frame
        return CGRect(
            x: rect.minX - frame.minX,
            y: frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    // MARK: - 识别

    private static func recognize(_ image: CGImage, level: VNRequestTextRecognitionLevel) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw ScreenTextError.recognition(error.localizedDescription)
        }
        let fragments = (request.results ?? []).compactMap { observation -> RecognizedFragment? in
            guard let text = observation.topCandidates(1).first?.string
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            let box = observation.boundingBox
            return RecognizedFragment(text: text, x: box.minX, y: box.minY)
        }
        return mergeLines(fragments).joined(separator: "\n")
    }
}
