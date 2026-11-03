import Foundation

/// OpenAI 兼容的联网翻译。
///
/// 只接入一个可由配置指定的服务，不做供应商目录。
struct OpenAICompatProvider: TranslationProviding {

    let id = "openai-compatible"
    let displayName = "联网翻译"

    let baseURL: URL
    let model: String
    let apiKey: String

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranslationError.emptyText }

        var url = baseURL
        url.appendPathComponent("chat/completions")

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 20
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": Self.prompt(target: request.target)],
                ["role": "user", "content": text]
            ]
        ]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch let error as URLError where error.code == .timedOut {
            throw TranslationError.timedOut
        } catch is CancellationError {
            throw TranslationError.cancelled
        } catch {
            throw TranslationError.service(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TranslationError.service("响应无效")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TranslationError.service("HTTP \(http.statusCode)\(Self.errorDetail(from: data))")
        }

        guard let content = Self.content(from: data) else {
            throw TranslationError.service("响应格式无法解析")
        }
        let cleaned = Self.clean(content)
        guard !cleaned.isEmpty else { throw TranslationError.service("服务返回空译文") }

        return TranslationResult(text: cleaned, providerID: id, providerName: displayName)
    }

    // MARK: - 解析

    private static func prompt(target: String) -> String {
        let language = target.hasPrefix("zh") ? "简体中文" : target
        return """
        你是英译中翻译器。只输出\(language)译文，不要解释、不要加引号、不要重复原文。\
        保留人名、术语与代码的原文。若输入是一个单词，只给出最常用的释义。
        """
    }

    private static func content(from data: Data) -> String? {
        struct ChatResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            let choices: [Choice]
        }
        return (try? JSONDecoder().decode(ChatResponse.self, from: data))?.choices.first?.message.content
    }

    /// 剥离推理模型的思考段，去掉包裹的引号。
    nonisolated static func clean(_ raw: String) -> String {
        var text = raw
        if let regex = try? NSRegularExpression(pattern: "(?s)<think>.*?</think>", options: []) {
            text = regex.stringByReplacingMatches(
                in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length), withTemplate: ""
            )
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let wrappers: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("「", "」")]
        for (leading, trailing) in wrappers where text.count >= 2 {
            if text.first == leading, text.last == trailing {
                text = String(text.dropFirst().dropLast())
                break
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 只取服务返回的错误说明，便于面板提示；截断后展示，不写日志。
    private static func errorDetail(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return "：" + String(message.prefix(120))
        }
        if let message = object["message"] as? String {
            return "：" + String(message.prefix(120))
        }
        return ""
    }
}
