import Foundation
import Testing
@testable import AppCore

@Test func configurationStoreClearsPersistedCodexThreadID() throws {
    let suiteName = "ConfigurationStoreTests-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        Issue.record("Failed to create isolated defaults suite")
        return
    }
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    defaults.set("thread_old", forKey: "codexThreadID")
    defaults.set("gpt-5.4-mini", forKey: "codexModel")

    let store = ConfigurationStore(defaults: defaults)
    let configuration = store.load()

    #expect(configuration.codexThreadID == nil)
    #expect(defaults.string(forKey: "codexThreadID") == nil)

    store.save(
        HostConfiguration(
            controlPlaneBaseURL: "http://localhost:8787",
            hostMode: .hosted,
            deviceID: nil,
            deviceSecret: nil,
            deviceName: "Test Mac",
            codexModel: "gpt-5.4-mini",
            codexThreadID: "thread_new"
        )
    )

    #expect(defaults.string(forKey: "codexThreadID") == nil)
}
