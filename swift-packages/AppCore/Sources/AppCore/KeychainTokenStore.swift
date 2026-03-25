import Foundation
import LocalAuthentication
import Security

public final class KeychainTokenStore: @unchecked Sendable {
    public enum AuthenticationUIBehavior: Sendable {
        case allow
        case fail
    }

    public enum LookupResult: Sendable {
        case value(String)
        case missing
        case interactionRequired
        case error(OSStatus)
    }

    public enum Key: String, CaseIterable, Sendable {
        case deviceSecret = "device-secret"
    }

    static let legacyDefaultService = "dev.remoteos.appcore.tokens"
    private let service: String
    var serviceName: String { service }

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

public enum DeviceSecretStoreMode: Sendable {
    case automatic
    case keychainOnly
    case defaultsOnly
}

public final class DeviceSecretStore: @unchecked Sendable {
    private let keychainTokenStore: KeychainTokenStore
    private let legacyKeychainTokenStore: KeychainTokenStore
    private let defaults: UserDefaults
    private let mode: DeviceSecretStoreMode
    private let fallbackKey: String
    private let canUseKeychainProvider: @Sendable () -> Bool

    public init(
        keychainTokenStore: KeychainTokenStore = KeychainTokenStore(),
        legacyKeychainTokenStore: KeychainTokenStore? = nil,
        defaults: UserDefaults = .standard,
        mode: DeviceSecretStoreMode = .automatic,
        canUseKeychainProvider: (@Sendable () -> Bool)? = nil
    ) {
        self.keychainTokenStore = keychainTokenStore
        self.legacyKeychainTokenStore = legacyKeychainTokenStore ?? KeychainTokenStore(service: KeychainTokenStore.legacyDefaultService)
        self.defaults = defaults
        self.mode = mode
        self.fallbackKey = "deviceSecretFallback.\(keychainTokenStore.serviceName)"
        self.canUseKeychainProvider = canUseKeychainProvider ?? { Self.currentTeamIdentifier() != nil }
    }

    public func load() -> String? {
        if usesKeychain {
            let currentLookup = keychainTokenStore.lookup(.deviceSecret, authenticationUI: .fail)
            if case let .value(value) = currentLookup,
               let normalizedValue = normalized(value)
            {
                return normalizedValue
            }

            let canWriteCurrentKeychain = canWriteWithoutInteraction(currentLookup)

            let legacyLookup = legacyKeychainTokenStore.lookup(.deviceSecret, authenticationUI: .fail)
            if case let .value(legacyValue) = legacyLookup,
               let normalizedLegacyValue = normalized(legacyValue)
            {
                if canWriteCurrentKeychain {
                    keychainTokenStore.save(normalizedLegacyValue, for: .deviceSecret)
                } else {
                    defaults.set(normalizedLegacyValue, forKey: fallbackKey)
                }
                return normalizedLegacyValue
            }

            if let fallbackValue = normalized(defaults.string(forKey: fallbackKey)) {
                if canWriteCurrentKeychain {
                    keychainTokenStore.save(fallbackValue, for: .deviceSecret)
                    defaults.removeObject(forKey: fallbackKey)
                }
                return fallbackValue
            }

            return nil
        }

        if let fallbackValue = normalized(defaults.string(forKey: fallbackKey)) {
            return fallbackValue
        }

        return nil
    }

    public func save(_ value: String?) {
        let normalizedValue = normalized(value)

        if usesKeychain, canWriteCurrentKeychainWithoutInteraction() {
            keychainTokenStore.save(normalizedValue, for: .deviceSecret)
            defaults.removeObject(forKey: fallbackKey)
        } else if let normalizedValue {
            defaults.set(normalizedValue, forKey: fallbackKey)
        } else {
            defaults.removeObject(forKey: fallbackKey)
        }
    }

    public func clear() {
        save(nil)
    }

    private var usesKeychain: Bool {
        switch mode {
        case .automatic:
            return canUseKeychainProvider()
        case .keychainOnly:
            return true
        case .defaultsOnly:
            return false
        }
    }

    private func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func canWriteCurrentKeychainWithoutInteraction() -> Bool {
        canWriteWithoutInteraction(keychainTokenStore.lookup(.deviceSecret, authenticationUI: .fail))
    }

    private func canWriteWithoutInteraction(_ result: KeychainTokenStore.LookupResult) -> Bool {
        switch result {
        case .value, .missing:
            return true
        case .interactionRequired, .error:
            return false
        }
    }

    static func currentTeamIdentifier(bundleURL: URL = Bundle.main.bundleURL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode
        else {
            return nil
        }

        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        ) == errSecSuccess,
        let info = signingInformation as? [String: Any]
        else {
            return nil
        }

        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
