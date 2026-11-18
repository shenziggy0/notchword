import Foundation

struct AnthropicProvider: TranslationProviding {
    let id = "anthropic"
    let displayName = "Anthropic"
    let baseURL: URL
    let model: String
    let apiKey: String

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 20
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 1024,
            "system": OpenAICompatProvider.prompt(target: request.target),
            "messages": [["role": "user", "content": request.text]]
        ])
        let data = try await OpenAICompatProvider.responseData(for: urlRequest)
        let translation = try Self.translationText(from: data)
        return TranslationResult(text: translation, providerID: id, providerName: displayName)
    }

    nonisolated static func translationText(from data: Data) throws -> String {
        struct Response: Decodable {
            struct Block: Decodable { let type: String; let text: String? }
            let content: [Block]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw TranslationError.service("Anthropic 响应格式无法解析")
        }
        let translation = OpenAICompatProvider.clean(response.content
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined(separator: "\n"))
        guard !translation.isEmpty else { throw TranslationError.service("Anthropic 返回空译文") }
        return translation
    }
}
