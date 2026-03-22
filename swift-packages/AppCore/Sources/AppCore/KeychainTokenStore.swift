import Foundation
import Security

public final class KeychainTokenStore: @unchecked Sendable {
    public enum Key: String, CaseIterable, Sendable {
        case deviceSecret = "device-secret"
    }

    private let service: String

    public init(service: String = "dev.remoteos.appcore.tokens") {
        self.service = service
    }

    public func load(_ key: Key) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else {
            return nil
        }
        guard
            status == errSecSuccess,
            let data = result as? Data,
            let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return value
    }

    public func save(_ value: String?, for key: Key) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let query = baseQuery(for: key)

        if trimmed.isEmpty {
            SecItemDelete(query as CFDictionary)
            return
        }

        let data = Data(trimmed.utf8)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        if updateStatus == errSecSuccess {
            return
        }

        var insertQuery = query
        insertQuery[kSecValueData as String] = data
        SecItemDelete(query as CFDictionary)
        SecItemAdd(insertQuery as CFDictionary, nil)
    }

    private func baseQuery(for key: Key) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
    }
}
