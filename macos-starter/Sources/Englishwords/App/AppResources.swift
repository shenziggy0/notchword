import Foundation

/// 随包资源的定位。
///
/// 同一个应用有两种运行形态：
///   - `swift build` / `swift run`：资源在 `.build/<config>/Englishwords_Englishwords.bundle`
///   - 打包后的 `.app`：资源被 `build.sh` 复制进 `Contents/Resources`
///
/// 这里按目录逐个探测，任何一处命中即可；开发期仍可用环境变量覆盖。
enum AppResources {

    static let dictionaryName = "dictionary.sqlite"
    static let wordpartsName = "wordparts.sqlite"
    static let noticesName = "THIRD-PARTY-NOTICES.md"

    static func dictionaryURL() -> URL? {
        locate(dictionaryName, override: "EW_DICT")
    }

    static func wordpartsURL() -> URL? {
        locate(wordpartsName, override: "EW_PARTS")
    }

    static func noticesURL() -> URL? {
        locate(noticesName, override: "EW_NOTICES")
    }

    private static func locate(_ name: String, override: String) -> URL? {
        if let raw = ProcessInfo.processInfo.environment[override], !raw.isEmpty {
            let url = URL(fileURLWithPath: raw)
            if FileManager.default.fileExists(atPath: url.path) { return url }
            FileLog.write("资源覆盖路径不存在：\(override)")
        }

        let fm = FileManager.default
        for directory in searchDirectories() {
            let candidate = directory.appendingPathComponent(name)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }

        // 兜底：SwiftPM 资源包名由「包名_目标名」拼成，扫描同级目录避免写死
        if let executable = Bundle.main.executableURL?.deletingLastPathComponent(),
           let entries = try? fm.contentsOfDirectory(at: executable, includingPropertiesForKeys: nil) {
            for bundle in entries where bundle.pathExtension == "bundle" {
                for sub in ["Contents/Resources", ""] {
                    let candidate = bundle.appendingPathComponent(sub).appendingPathComponent(name)
                    if fm.fileExists(atPath: candidate.path) { return candidate }
                }
            }
        }
        return nil
    }

    private static func searchDirectories() -> [URL] {
        var dirs: [URL] = []
        if let resources = Bundle.main.resourceURL {
            dirs.append(resources)
            dirs.append(resources.appendingPathComponent("Englishwords_Englishwords.bundle/Contents/Resources"))
            dirs.append(resources.appendingPathComponent("Englishwords_Englishwords.bundle"))
        }

        let executableDir = Bundle.main.executableURL?.deletingLastPathComponent()
        if let executableDir {
            dirs.append(executableDir)
            dirs.append(executableDir.appendingPathComponent("Englishwords_Englishwords.bundle/Contents/Resources"))
            dirs.append(executableDir.appendingPathComponent("Englishwords_Englishwords.bundle"))
            dirs.append(executableDir.appendingPathComponent("../Resources").standardizedFileURL)
        }
        return dirs
    }
}
