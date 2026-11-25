import AppKit
import Foundation

@MainActor
final class SubtitleTracker: ObservableObject {
    private struct Snapshot: Decodable {
        let mode: String
        let videoID: String?
        let cues: [SubtitleCue]?
        let chinese: [SubtitleCue]?
        let seekable: [[Double]]?
        let videoRef: String?
        let replaying: Bool?
        let replayError: Bool?
    }

    private struct Target: Equatable {
        let bundle: String
        let video: String
    }

    struct CueID: Equatable {
        fileprivate let source: String?
        fileprivate let video: String?
        fileprivate let ocrGeneration: Int
        fileprivate let start: Double
    }

    private struct ScreenArea {
        let bundle: String
        let rect: CGRect
        let displayID: CGDirectDisplayID
    }

    @Published private(set) var cues: [SubtitleCue] = []
    @Published private(set) var position = 0
    @Published private(set) var translation = ""
    @Published private(set) var status = "在浏览器中播放含字幕的视频。"

    private let preferences: Preferences
    private let translator: any Translating
    private let bridge = BrowserBridge()
    private let script: String?
    private var tracking: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?
    private var target: Target?
    @Published private var seekable: [[Double]] = []
    private var videoReference: String?
    @Published private(set) var replayActive = false
    private var sendingReplay = false
    private var pausedByApp: Target?
    private var chinese: [SubtitleCue] = []
    private var area: ScreenArea?
    private var lastScreenCue = ""
    private var screening: [SubtitleCue] = []
    private var ocrGeneration = 0
    private var isPausing = false
    private var failures = 0
    private var presentation = 0
    private var presenting = false
    private var frontmost: String?

    init(preferences: Preferences, translator: any Translating) {
        self.preferences = preferences
        self.translator = translator
        script = AppResources.subtitleScriptURL().flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    var current: SubtitleCue? { cues.indices.contains(position) ? cues[position] : nil }

    var canReplay: Bool {
        guard let cue = current, target != nil, cue.end > cue.start else { return false }
        return seekable.contains { range in
            range.count == 2 && cue.start >= range[0] && cue.end <= range[1]
        }
    }

    var videoBookmark: VideoBookmark? {
        guard canReplay, let videoReference, let current else { return nil }
        return VideoBookmark(reference: videoReference, seconds: current.start)
    }

    func replayCurrent() {
        guard !sendingReplay, !replayActive, canReplay, let cue = current, let target,
              AppRules.frontmostBundleID == target.bundle else { return }
        sendingReplay = true
        Task {
            defer { sendingReplay = false }
            do {
                let response = try await execute("replay", browser: target.bundle, videoID: target.video, cue: cue)
                guard self.target == target else { return }
                if response == "true" || response == "busy" { replayActive = true }
                else { status = "当前字幕无法重听" }
            } catch {
                if self.target == target { status = "无法控制当前视频" }
            }
        }
    }

    func open(_ bookmark: VideoBookmark) {
        let parts = bookmark.reference.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, parts[0] == "youtube",
              parts[1].range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil,
              bookmark.seconds.isFinite, (0...1_000_000_000).contains(bookmark.seconds) else { return }
        var url = URLComponents()
        url.scheme = "https"
        url.host = "www.youtube.com"
        url.path = "/watch"
        url.queryItems = [URLQueryItem(name: "v", value: String(parts[1])),
                          URLQueryItem(name: "t", value: String(Int(bookmark.seconds)) + "s")]
        if let address = url.url { NSWorkspace.shared.open(address) }
    }

    var currentCueID: CueID? {
        current.map { cue in
            CueID(source: target?.bundle, video: target?.video,
                  ocrGeneration: target == nil ? ocrGeneration : 0, start: cue.start)
        }
    }

    func applyPreferences() {
        if preferences.videoSubtitles {
            guard tracking == nil else { return }
            tracking = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.poll()
                    // 连续无视频/出错后退避到约 2 秒一次
                    let backoff = (self?.failures ?? 0) >= 3
                    try? await Task.sleep(for: .milliseconds(backoff ? 2000 : 500))
                }
            }
        } else {
            tracking?.cancel()
            tracking = nil
            dismissed()
            reset()
            status = "字幕查询已关闭。"
        }
    }

    func configureOCR(rect: CGRect, screen: NSScreen, browser: String) {
        ocrGeneration &+= 1
        area = ScreenArea(bundle: browser, rect: rect, displayID: Self.displayID(of: screen))
        screening = []
        lastScreenCue = ""
        failures = 0
    }

    func peek() {
        presentation &+= 1
        let generation = presentation
        presenting = true
        if !cues.isEmpty { position = cues.count - 1 }
        translateCurrent()
        guard preferences.pausesVideoOnPeek, current != nil, let target,
              pausedByApp == nil, !isPausing else { return }
        isPausing = true
        Task {
            let paused = (try? await execute("pause", target: target)) == "true"
            isPausing = false
            guard paused else { return }
            if presenting, presentation == generation, self.target == target {
                pausedByApp = target
            } else if preferences.resumesVideoAfterPeek, AppRules.frontmostBundleID == target.bundle {
                _ = try? await execute("play", target: target)
            }
        }
    }

    func move(by offset: Int) {
        guard !cues.isEmpty else { return }
        presenting = true
        position = min(max(0, position + offset), cues.count - 1)
        translateCurrent()
    }

    func dismissed() {
        presenting = false
        presentation &+= 1
        translationTask?.cancel()
        translationTask = nil
        let previous = pausedByApp
        pausedByApp = nil
        guard preferences.resumesVideoAfterPeek, let previous,
              AppRules.frontmostBundleID == previous.bundle else { return }
        Task { _ = try? await execute("play", target: previous) }
    }

    private func poll() async {
        let browser = AppRules.frontmostBundleID
        if browser != frontmost {
            frontmost = browser
            reset()
        }
        guard let browser, BrowserBridge.supports(browser) else {
            status = "前台应用不是支持的浏览器。"
            failures += 1
            return
        }
        do {
            if browser == BrowserBridge.firefox {
                try await screenSubtitles(browser)
                return
            }
            guard script != nil else {
                status = "随包字幕脚本缺失。"
                failures += 1
                return
            }
            let response = try await execute("state", browser: browser)
            guard !Task.isCancelled, AppRules.frontmostBundleID == browser else { return }
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(response.utf8))
            let active = snapshot.videoID.map { Target(bundle: browser, video: $0) }
            if target != active {
                reset()
                target = active
            }
            let ranges = snapshot.mode == "dom" ? snapshot.seekable ?? [] : []
            if seekable != ranges { seekable = ranges }
            videoReference = snapshot.mode == "dom" ? snapshot.videoRef : nil
            let activeReplay = snapshot.replaying == true
            if replayActive != activeReplay { replayActive = activeReplay }
            switch snapshot.mode {
            case "dom":
                chinese = snapshot.chinese ?? []
                update(SentenceMerger.merge(snapshot.cues ?? []))
                status = snapshot.replayError == true ? "浏览器未能开始重听" : "网页字幕"
                failures = 0
            case "screen":
                try await screenSubtitles(browser)
            case "drm":
                update([])
                status = "当前视频受保护，无法读取字幕。"
                failures = 0
            case "ad":
                update([])
                status = "广告播放中。"
                failures = 0
            default:
                update([])
                status = "没有找到可用字幕。"
                failures += 1
            }
        } catch {
            guard !Task.isCancelled, AppRules.frontmostBundleID == browser else { return }
            status = error.localizedDescription
            update([])
            failures += 1
        }
    }

    private func screenSubtitles(_ browser: String) async throws {
        guard preferences.screenSubtitles else {
            update([])
            status = "网页字幕不可用。可在设置中启用屏幕字幕识别。"
            return
        }
        guard let area, area.bundle == browser else {
            update([])
            status = "请从菜单栏选择「框选字幕区域…」。"
            failures += 1
            return
        }
        guard presenting else { return }
        guard let screen = Self.screen(displayID: area.displayID) else {
            update([])
            status = "字幕区域的显示器已断开。"
            failures += 1
            return
        }
        let generation = ocrGeneration
        let text = try await ScreenText.recognize(rect: area.rect, on: screen)
        guard generation == ocrGeneration, !Task.isCancelled, presenting,
              AppRules.frontmostBundleID == browser else { return }
        if !text.isEmpty, text != lastScreenCue {
            let now = Date().timeIntervalSince1970
            screening.append(SubtitleCue(text: text, start: now, end: now))
            screening = Array(screening.suffix(80))
            lastScreenCue = text
        }
        chinese = []
        update(SentenceMerger.merge(screening))
        status = screening.isEmpty ? "字幕区域内暂未识别到文字。" : "屏幕字幕"
        failures = text.isEmpty ? failures + 1 : 0
    }

    private func update(_ next: [SubtitleCue]) {
        let previous = current
        let followsLive = cues.isEmpty || position == cues.count - 1
        if cues != next {
            cues = next
            position = followsLive ? max(0, next.count - 1) : next.firstIndex(where: { $0.start == previous?.start }) ?? 0
        }
        if presenting, current != previous { translateCurrent() }
    }

    private func reset() {
        replayActive = false
        seekable = []
        videoReference = nil
        target = nil
        pausedByApp = nil
        chinese = []
        lastScreenCue = ""
        screening = []
        ocrGeneration &+= 1
        failures = 0
        update([])
    }

    private func translateCurrent() {
        translationTask?.cancel()
        translation = ""
        guard let sentence = current else { return }
        if let aligned = SubtitleAligner.translation(of: sentence, in: chinese) {
            translation = aligned
            return
        }
        translationTask = Task {
            do {
                let result = try await translator.translate(TranslationRequest(
                    text: sentence.text, source: "en", target: preferences.targetLanguage
                ))
                if !Task.isCancelled, current == sentence { translation = result.text }
            } catch {
                guard !Task.isCancelled, current == sentence,
                      !TranslationError.isCancellation(error) else { return }
                translation = error.localizedDescription
            }
        }
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number.map { CGDirectDisplayID($0.uint32Value) } ?? CGMainDisplayID()
    }

    private static func screen(displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { self.displayID(of: $0) == displayID } ?? NSScreen.main
    }

    private func execute(_ command: String, target: Target) async throws -> String {
        try await execute(command, browser: target.bundle, videoID: target.video)
    }

    private func execute(_ command: String, browser: String, videoID: String? = nil, cue: SubtitleCue? = nil) async throws -> String {
        // JSON string encoding prevents data from becoming script commands.
        var fields: [Any] = [command, videoID ?? ""]
        if let cue { fields.append(contentsOf: [cue.start, cue.end]) }
        let values = try JSONSerialization.data(withJSONObject: fields)
        let arguments = String(decoding: values, as: UTF8.self)
        let javascript = "\(script ?? "")\nJSON.stringify(globalThis.__notchwordSubtitlesV2(...\(arguments)));"
        // The injected function returns a string because AppleScript expects a primitive.
        // Parse only the enclosing JSON string, then decode the command's payload separately.
        let response = try await bridge.run(javascript, in: browser)
        return try JSONDecoder().decode(String.self, from: Data(response.utf8))
    }
}
