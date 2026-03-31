import Foundation
import LocalAuthentication
import Security

public protocol SecretStringStore<Key>: Sendable {
    associatedtype Key: RawRepresentable & CaseIterable & Sendable where Key.RawValue == String

    func load(_ key: Key, authenticationUI: KeychainTokenStore<Key>.AuthenticationUIBehavior) -> String?
    func save(_ value: String?, for key: Key)
}

public final class KeychainTokenStore<Key: RawRepresentable & CaseIterable>: @unchecked Sendable where Key.RawValue == String {
    public enum AuthenticationUIBehavior: Sendable {
        case allow
        case fail
    }

    public enum LookupResult: Sendable, Equatable {
        case value(String)
        case missing
        case interactionRequired
        case error(OSStatus)
    }

    public static var legacyDefaultService: String {
        "dev.remoteos.core.tokens"
    }

    private let service: String

    public init(service: String? = nil) {
        self.service = service ?? Self.defaultServiceName()
    }

    public func load(
        _ key: Key,
        authenticationUI: AuthenticationUIBehavior = .allow
    ) -> String? {
        if case let .value(value) = lookup(key, authenticationUI: authenticationUI) {
            return value
        }
        return nil
    }

    public func lookup(
        _ key: Key,
        authenticationUI: AuthenticationUIBehavior = .allow
    ) -> LookupResult {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if authenticationUI == .fail {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard
                let data = result as? Data,
                let value = String(data: data, encoding: .utf8)
            else {
                return .error(errSecDecode)
            }
            return .value(value)
        case errSecItemNotFound:
            return .missing
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            return .interactionRequired
        default:
            return .error(status)
        }
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

    private static func defaultServiceName() -> String {
        let scope =
            Bundle.main.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ProcessInfo.processInfo.processName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !scope.isEmpty else {
            return legacyDefaultService
        }

        return "\(legacyDefaultService).\(scope)"
    }
}

extension KeychainTokenStore: SecretStringStore {}
