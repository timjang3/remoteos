import Foundation
import Testing
@testable import RemoteOSCore

@Test func streamStartFixtureIncludesBalancedProfile() throws {
    let data = try TestSupport.fixtureData(named: "rpc-request-stream-start-balanced.json")
    let inbound = try JSONRPCInboundEnvelope(data: data)

    guard case let .request(request) = inbound else {
        Issue.record("Expected a JSON-RPC request fixture")
        return
    }

    #expect(request.method == RemoteOSRPCMethod.streamStart.rawValue)
    let params = try request.params?.decode(StreamStartPayload.self)
    #expect(params?.windowId == 9)
    #expect(params?.profile == .balanced)
}

@Test func windowsListSuccessFixtureDecodesSharedContractShape() throws {
    let data = try TestSupport.fixtureData(named: "rpc-success-windows-list.json")
    let inbound = try JSONRPCInboundEnvelope(data: data)

    guard case let .success(success) = inbound else {
        Issue.record("Expected a JSON-RPC success fixture")
        return
    }

    let result = try success.result?.decode(WindowsListPayload.self)
    #expect(result?.windows.count == 1)
    #expect(result?.windows.first?.title == "shell")
}

@Test func agentPromptFixtureDecodesNotificationPayload() throws {
    let data = try TestSupport.fixtureData(named: "rpc-notification-agent-prompt-requested.json")
    let inbound = try JSONRPCInboundEnvelope(data: data)

    guard case let .notification(notification) = inbound else {
        Issue.record("Expected a JSON-RPC notification fixture")
        return
    }

    let payload = try RemoteOSNotification(method: notification.method, params: notification.params)
    guard case let .agentPromptRequested(prompt) = payload else {
        Issue.record("Expected an agent prompt notification")
        return
    }

    #expect(prompt.id == "prompt_1")
    #expect(prompt.questions.first?.id == "profile")
}
