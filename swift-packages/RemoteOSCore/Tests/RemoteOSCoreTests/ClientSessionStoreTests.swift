import Foundation
import Testing
@testable import RemoteOSCore

private final class InMemorySecretStore: SecretStringStore, @unchecked Sendable {
    typealias Key = ClientSecretKey

    private let lock = NSLock()
    private var values: [String: String] = [:]

    func load(
        _ key: ClientSecretKey,
        authenticationUI: KeychainTokenStore<ClientSecretKey>.AuthenticationUIBehavior
    ) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key.rawValue]
    }

    func save(_ value: String?, for key: ClientSecretKey) {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        defer { lock.unlock() }
        if let normalized, normalized.isEmpty == false {
            values[key.rawValue] = normalized
        } else {
            values.removeValue(forKey: key.rawValue)
        }
    }
}

@Test func clientSessionStorePersistsNormalizedDefaultsAndSecrets() async {
    let suiteName = "RemoteOSCoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let store = ClientSessionStore(defaults: defaults, keychain: InMemorySecretStore())

    await store.save(controlPlaneBaseURL: " https://example.com/ ")
    await store.save(clientName: "  Remote iPhone  ")
    await store.save(clientToken: " client_token ")
    await store.save(authToken: " auth_token ")

    let session = await store.load()
    #expect(session.controlPlaneBaseURL == "https://example.com")
    #expect(session.clientName == "Remote iPhone")
    #expect(session.clientToken == "client_token")
    #expect(session.authToken == "auth_token")
}

@Test func clientSessionStoreClearsSecretsWithoutDroppingDefaults() async {
    let suiteName = "RemoteOSCoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let store = ClientSessionStore(defaults: defaults, keychain: InMemorySecretStore())

    await store.save(controlPlaneBaseURL: "https://example.com")
    await store.save(clientName: "Remote iPhone")
    await store.save(clientToken: "client_token")
    await store.save(authToken: "auth_token")
    await store.clearAll()

    let session = await store.load()
    #expect(session.controlPlaneBaseURL == "https://example.com")
    #expect(session.clientName == "Remote iPhone")
    #expect(session.clientToken == nil)
    #expect(session.authToken == nil)
}
