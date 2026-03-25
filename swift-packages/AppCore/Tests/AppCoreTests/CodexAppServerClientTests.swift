import Foundation
import Testing
@testable import AppCore

private actor CallbackOrderRecorder {
    private var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func snapshot() -> [String] {
        events
    }
}

@Test func turnStartHasNoHardRequestTimeout() async {
    let policy = CodexRequestTimeoutPolicy()

    #expect(policy.timeout(for: "turn/start") == nil)
    #expect(policy.timeout(for: "thread/start") == .seconds(30))
    #expect(policy.timeout(for: "initialize") == .seconds(30))
}

@Test func traceCallbacksDoNotBlockEventCallbacks() async throws {
    let dispatcher = CodexCallbackDispatcher()
    let recorder = CallbackOrderRecorder()

    dispatcher.enqueueTrace {
        try? await Task.sleep(for: .milliseconds(300))
        await recorder.append("trace")
    }
    dispatcher.enqueueEvent {
        await recorder.append("event")
    }

    try? await Task.sleep(for: .milliseconds(50))
    #expect(await recorder.snapshot() == ["event"])

    try? await Task.sleep(for: .milliseconds(350))
    #expect(await recorder.snapshot() == ["event", "trace"])
}

@Test func legacyCodexAliasUsesCompatibleHostManagedSessionSettings() {
    let configuration = CodexSessionConfiguration.resolved(
        model: "gpt-5-codex",
        cwd: "/tmp",
        approvalPolicy: "never",
        sandboxMode: "danger-full-access",
        profiles: CodexModelProfile.builtinProfiles()
    )

    #expect(configuration.model == "gpt-5-codex")
    #expect(configuration.reasoningEffort == .high)
    #expect(configuration.personality == nil)
}

@Test func modelProfileClampsUnsupportedDefaultEffort() {
    let profile = CodexModelProfile(
        model: "example-model",
        supportedReasoningEfforts: [.low, .medium, .high],
        defaultReasoningEffort: .xhigh,
        supportsPersonality: true
    )

    #expect(profile.defaultReasoningEffort == .high)
    #expect(profile.resolvedReasoningEffort() == .high)
}

@Test func bufferedJSONLFramerPreservesChunkedLineOrder() {
    let framer = BufferedJSONLFramer()

    #expect(framer.append(Data("first\nsec".utf8)) == ["first"])
    #expect(framer.append(Data("ond\nthird\n".utf8)) == ["second", "third"])
}

@Test func bufferedJSONLFramerFlushesTrailingLineWithoutNewline() {
    let framer = BufferedJSONLFramer()

    #expect(framer.append(Data("partial".utf8)).isEmpty)
    #expect(framer.finish() == ["partial"])
}

@Test func jsonRPCResultPayloadPreservesNumericRequestIDs() throws {
    let requestID = try #require(JSONRPCRequestID(rawValue: 0))
    let payload = jsonRPCResultPayload(id: requestID, result: ["ok": true])
    let encoded = try dataFromJSONObject(payload)
    let decoded = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

    #expect(decoded["id"] as? String == nil)
    let numericID = try #require(decoded["id"] as? NSNumber)
    #expect(numericID.intValue == 0)
}

@Test func jsonRPCResultPayloadPreservesStringRequestIDs() throws {
    let requestID = try #require(JSONRPCRequestID(rawValue: "tool-7"))
    let payload = jsonRPCResultPayload(id: requestID, result: ["ok": true])
    let encoded = try dataFromJSONObject(payload)
    let decoded = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

    #expect(decoded["id"] as? String == "tool-7")
}

@Test func cliCommandResolverAddsFallbackPATHForGUIApps() {
    let environment = CLICommandResolver.environmentWithFallbackPATH(
        environment: [
            "HOME": "/Users/tester",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
        ],
        homeDirectory: "/Users/tester"
    )

    let pathEntries = Set((environment["PATH"] ?? "").split(separator: ":").map(String.init))
    #expect(pathEntries.contains("/opt/homebrew/bin"))
    #expect(pathEntries.contains("/usr/local/bin"))
    #expect(pathEntries.contains("/Applications/Codex.app/Contents/Resources"))
    #expect(pathEntries.contains("/Users/tester/.local/bin"))
}

@Test func cliCommandResolverFindsCodexOutsideMinimalPATH() throws {
    let resolution = try CLICommandResolver.resolve(
        arguments: ["codex", "app-server", "--listen", "stdio://"],
        environment: [
            "HOME": "/Users/tester",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
        ],
        homeDirectory: "/Users/tester",
        isExecutableFile: { path in
            path == "/Applications/Codex.app/Contents/Resources/codex"
        }
    )

    #expect(resolution.executableURL.path == "/Applications/Codex.app/Contents/Resources/codex")
    #expect(resolution.arguments == ["app-server", "--listen", "stdio://"])
    #expect((resolution.environment["PATH"] ?? "").contains("/Applications/Codex.app/Contents/Resources"))
}

@Test func deviceSecretStoreUsesDefaultsWhenKeychainTrackingIsUnavailable() {
    let suiteName = "DeviceSecretStoreDefaults-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        Issue.record("Failed to create isolated defaults suite")
        return
    }
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    let keychain = KeychainTokenStore(service: "DeviceSecretStoreDefaults-\(UUID().uuidString)")
    let store = DeviceSecretStore(
        keychainTokenStore: keychain,
        defaults: defaults,
        mode: .automatic,
        canUseKeychainProvider: { false }
    )

    store.save("secret_defaults")

    #expect(store.load() == "secret_defaults")
    #expect(keychain.load(.deviceSecret, authenticationUI: .fail) == nil)
}

@Test func deviceSecretStoreDefaultsOnlyIgnoresKeychainSecretsUntilSaved() {
    let suiteName = "DeviceSecretStoreDefaultsOnly-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        Issue.record("Failed to create isolated defaults suite")
        return
    }
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    let keychain = KeychainTokenStore(service: "DeviceSecretStoreDefaultsOnly-\(UUID().uuidString)")
    keychain.save("secret_keychain", for: .deviceSecret)
    defer {
        keychain.save(nil, for: .deviceSecret)
    }

    let store = DeviceSecretStore(
        keychainTokenStore: keychain,
        defaults: defaults,
        mode: .defaultsOnly
    )

    #expect(store.load() == nil)
    store.save("secret_defaults")
    #expect(store.load() == "secret_defaults")
}
