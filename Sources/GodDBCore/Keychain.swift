import Foundation
import Security

/// 접속 비밀번호를 macOS 로그인 키체인에 보관한다. (service = "GodDB", account = 접속 ID)
public enum Keychain {
    private static let service = "GodDB"

    public static func password(for id: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// - Returns: 저장 성공 여부 (빈 비밀번호는 지우기만 하고 true)
    @discardableResult
    public static func setPassword(_ password: String, for id: UUID) -> Bool {
        deletePassword(for: id)
        guard !password.isEmpty else { return true }
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecAttrLabel as String: tr("GodDB DB 비밀번호"),
            kSecValueData as String: Data(password.utf8),
        ]
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    public static func deletePassword(for id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
