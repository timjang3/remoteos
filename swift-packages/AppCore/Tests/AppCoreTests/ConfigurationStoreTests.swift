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

@Test func configurationStoreResetsConnectionOverridesToRegisteredDefaults() throws {
    let suiteName = "ConfigurationStoreResetTests-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        Issue.record("Failed to create isolated defaults suite")
        return
    }
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    defaults.register(defaults: [
        "controlPlaneBaseURL": "http://localhost:8787",
        "hostMode": HostMode.hosted.rawValue
    ])
    defaults.set("http://localhost:8787", forKey: "controlPlaneBaseURL")
    defaults.set(HostMode.direct.rawValue, forKey: "hostMode")

    let store = ConfigurationStore(defaults: defaults)
    store.resetConnectionOverrides()
    let configuration = store.load()

    #expect(configuration.controlPlaneBaseURL == "http://localhost:8787")
    #expect(configuration.hostMode == .hosted)
}
