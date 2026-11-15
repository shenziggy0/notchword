import CoreFoundation
import Foundation
import Security

enum SecretStoreError: LocalizedError {
    case emptyValue
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptyValue: return "请输入 API 密钥。"
        case .keychain(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
            return "钥匙串访问失败：\(detail)（\(status)）"
        }
    }
}

/// 翻译服务密钥。按服务标识存入 Keychain，不写 UserDefaults、不进日志。
enum SecretStore {

    static let service = "io.github.shenziggy0.notchword.translation"

    /// 改 Bundle ID 之前的钥匙串服务名与偏好域名，只在一次性迁移里使用。
    private static let legacyService = "com.example.englishwords.translation"
    private static let legacyDefaultsDomain = "com.example.englishwords"
    private static let legacyAccount = "openai-compatible"
    private static let migrationFlag = "migration.bundleID"

    static func migrateBundleIdentityIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: migrationFlag) < 1 else { return }

        copyLegacyDefaults(into: defaults)
        guard migrateKeychain() else {
            FileLog.write("钥匙串迁移未完成，下次启动再试")
            return
        }
        defaults.set(1, forKey: migrationFlag)
    }

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
        guard !trimmed.isEmpty else { return .failure(.emptyValue) }

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

    // MARK: - 一次性迁移

    /// 旧偏好域里、新域还没有的键，复制到当前 UserDefaults。
    private static func copyLegacyDefaults(into defaults: UserDefaults) {
        guard let raw = CFPreferencesCopyMultiple(
            nil,
            legacyDefaultsDomain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? [String: Any] else { return }

        let domain = Bundle.main.bundleIdentifier ?? legacyDefaultsDomain
        let existing = defaults.persistentDomain(forName: domain) ?? [:]
        for (key, value) in raw where existing[key] == nil {
            defaults.set(value, forKey: key)
        }
    }

    /// 旧 service 的条目复制到新 service。`openai-compatible` 改存为 `custom`。
    /// 新条目写入成功后才删除旧条目；任一条失败则整体未完成，下次启动再试。
    private static func migrateKeychain() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return true }
        guard status == errSecSuccess else {
            FileLog.write("读取旧钥匙串失败（\(status)）")
            return false
        }

        let items: [[String: Any]]
        if let many = result as? [[String: Any]] {
            items = many
        } else if let one = result as? [String: Any] {
            items = [one]
        } else {
            FileLog.write("旧钥匙串条目无法识别")
            return false
        }

        for item in items {
            guard let account = accountName(item),
                  let data = item[kSecValueData as String] as? Data,
                  let secret = String(data: data, encoding: .utf8),
                  !secret.isEmpty else { continue }
            let destination = account == legacyAccount ? "custom" : account
            switch save(secret, account: destination) {
            case .success:
                guard deleteLegacy(account: account) else {
                    FileLog.write("旧钥匙串条目删除失败")
                    return false
                }
            case .failure:
                FileLog.write("钥匙串条目迁移失败")
                return false
            }
        }
        return true
    }

    private static func accountName(_ item: [String: Any]) -> String? {
        if let name = item[kSecAttrAccount as String] as? String { return name }
        if let data = item[kSecAttrAccount as String] as? Data {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    private static func deleteLegacy(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
