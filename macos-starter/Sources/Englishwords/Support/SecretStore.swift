import Foundation
import Security

enum SecretStoreError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
            return "钥匙串访问失败：\(detail)（\(status)）"
        }
    }
}

/// 翻译服务密钥。按服务标识存入 Keychain，不写 UserDefaults、不进日志。
enum SecretStore {

    private static let service = "com.example.englishwords.translation"

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func hasSecret(account: String) -> Bool {
        (read(account: account) ?? "").isEmpty == false
    }

    @discardableResult
    static func save(_ value: String, account: String) -> Result<Void, SecretStoreError> {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return delete(account: account) }

        let data = Data(trimmed.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return .success(()) }
        guard updateStatus == errSecItemNotFound else { return .failure(.keychain(updateStatus)) }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        return addStatus == errSecSuccess ? .success(()) : .failure(.keychain(addStatus))
    }

    @discardableResult
    static func delete(account: String) -> Result<Void, SecretStoreError> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
            ? .success(())
            : .failure(.keychain(status))
    }
}
