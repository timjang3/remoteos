import Foundation

public enum ClientSecretKey: String, CaseIterable, Sendable {
    case clientToken = "client-token"
    case authToken = "auth-token"
}

public struct StoredClientSession: Sendable, Equatable {
    public var controlPlaneBaseURL: String?
    public var clientName: String
    public var clientToken: String?
    public var authToken: String?

    public init(
        controlPlaneBaseURL: String?,
        clientName: String,
        clientToken: String?,
        authToken: String?
    ) {
        self.controlPlaneBaseURL = controlPlaneBaseURL
        self.clientName = clientName
        self.clientToken = clientToken
        self.authToken = authToken
    }
}

public actor ClientSessionStore {
    private enum DefaultsKey {
        static let controlPlaneBaseURL = "remoteos.client.controlPlaneBaseURL"
        static let clientName = "remoteos.client.clientName"
    }

    private let defaults: UserDefaults
    private let keychainLoad: @Sendable (ClientSecretKey, KeychainTokenStore<ClientSecretKey>.AuthenticationUIBehavior) -> String?
    private let keychainSave: @Sendable (String?, ClientSecretKey) -> Void

    public init(
        defaults: UserDefaults = .standard,
        keychain: KeychainTokenStore<ClientSecretKey> = KeychainTokenStore()
    ) {
        self.defaults = defaults
        self.keychainLoad = { key, behavior in
            keychain.load(key, authenticationUI: behavior)
        }
        self.keychainSave = { value, key in
            keychain.save(value, for: key)
        }
    }

    public init<Store: SecretStringStore>(
        defaults: UserDefaults = .standard,
        keychain: Store
    ) where Store.Key == ClientSecretKey {
        self.defaults = defaults
        self.keychainLoad = { key, behavior in
            keychain.load(key, authenticationUI: behavior)
        }
        self.keychainSave = { value, key in
            keychain.save(value, for: key)
        }
    }

    public func load() -> StoredClientSession {
        StoredClientSession(
            controlPlaneBaseURL: normalizedBaseURL(defaults.string(forKey: DefaultsKey.controlPlaneBaseURL)),
            clientName: defaults.string(forKey: DefaultsKey.clientName) ?? "iPhone",
            clientToken: keychainLoad(.clientToken, .fail),
            authToken: keychainLoad(.authToken, .fail)
        )
    }

    public func save(controlPlaneBaseURL: String?) {
        if let normalized = normalizedBaseURL(controlPlaneBaseURL) {
            defaults.set(normalized, forKey: DefaultsKey.controlPlaneBaseURL)
        } else {
            defaults.removeObject(forKey: DefaultsKey.controlPlaneBaseURL)
        }
    }

    public func save(clientName: String) {
        let normalized = clientName.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(normalized.isEmpty ? "iPhone" : normalized, forKey: DefaultsKey.clientName)
    }

    public func save(clientToken: String?) {
        keychainSave(clientToken, .clientToken)
    }

    public func save(authToken: String?) {
        keychainSave(authToken, .authToken)
    }

    public func clearClientToken() {
        keychainSave(nil, .clientToken)
    }

    public func clearAuthToken() {
        keychainSave(nil, .authToken)
    }

    public func clearAll() {
        clearClientToken()
        clearAuthToken()
    }

    private func normalizedBaseURL(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.isEmpty == false else {
            return nil
        }
        return trimmed.replacingOccurrences(of: "/$", with: "", options: .regularExpression)
    }
}
