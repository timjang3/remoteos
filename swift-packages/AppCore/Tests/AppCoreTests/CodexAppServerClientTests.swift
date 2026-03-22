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
        model: "gpt-5.4-mini",
        cwd: "/tmp",
        approvalPolicy: "never",
        sandboxMode: "danger-full-access",
        profiles: CodexModelProfile.builtinProfiles()
    )

    #expect(configuration.model == "gpt-5.4-mini")
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
