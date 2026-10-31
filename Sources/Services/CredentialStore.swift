import Foundation
import Security

/// 密码优先写入钥匙串；部分自签名/未签名安装方式下钥匙串不可用，
/// 此时退化为本地混淆存储，保证仍能自动登录。
enum CredentialStore {
    private static let service = "com.smbviewer.app.credentials"
    private static let fallbackPrefix = "credentials.fallback."

    static func password(for id: UUID) -> String {
        if let data = readKeychain(account: id.uuidString), let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let obfuscated = UserDefaults.standard.string(forKey: fallbackPrefix + id.uuidString),
           let data = Data(base64Encoded: obfuscated) {
            return String(decoding: xor(data), as: UTF8.self)
        }
        return ""
    }

    static func setPassword(_ password: String, for id: UUID) {
        if password.isEmpty {
            delete(for: id)
            return
        }
        let data = Data(password.utf8)
        if writeKeychain(data: data, account: id.uuidString) {
            UserDefaults.standard.removeObject(forKey: fallbackPrefix + id.uuidString)
        } else {
            let encoded = xor(data).base64EncodedString()
            UserDefaults.standard.set(encoded, forKey: fallbackPrefix + id.uuidString)
        }
    }

    static func delete(for id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: fallbackPrefix + id.uuidString)
    }

    // MARK: - Keychain

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func readKeychain(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return data
    }

    @discardableResult
    private static func writeKeychain(data: Data, account: String) -> Bool {
        let query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        return status == errSecSuccess
    }

    // MARK: - 退化方案（仅做轻量混淆，非加密）

    private static func xor(_ data: Data) -> Data {
        let key: [UInt8] = [0x53, 0x4D, 0x42, 0x56, 0x69, 0x65, 0x77, 0x21]
        var output = Data(count: data.count)
        for index in 0..<data.count {
            output[index] = data[index] ^ key[index % key.count]
        }
        return output
    }
}
