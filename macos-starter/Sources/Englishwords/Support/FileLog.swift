import Foundation

/// 极简运行日志。
///
/// 只记录诊断信息：**不写查询正文、不写翻译请求内容、不写密钥**。
/// 同时写 stderr 和 `~/Library/Logs/Englishwords/app.log`，方便排查现场问题。
enum FileLog {

    private static let queue = DispatchQueue(label: "io.github.shenziggy0.notchword.log")
    private static let maxBytes = 300_000

    private static let fileURL: URL? = {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = library.appendingPathComponent("Logs/Englishwords", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("app.log")
    }()

    static func write(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))

        queue.async {
            guard let fileURL else { return }
            if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let size = attributes[.size] as? Int, size > maxBytes {
                try? FileManager.default.removeItem(at: fileURL)
            }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }
    }

    static var logPath: String { fileURL?.path ?? "(不可用)" }
}
