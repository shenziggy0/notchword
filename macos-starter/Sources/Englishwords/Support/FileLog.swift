import Foundation

/// 极简运行日志。
///
/// 只记录诊断信息：**不写查询正文、不写翻译请求内容、不写密钥**。
enum FileLog {
    static func write(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("[\(stamp)] \(message)\n".utf8))
    }
}
