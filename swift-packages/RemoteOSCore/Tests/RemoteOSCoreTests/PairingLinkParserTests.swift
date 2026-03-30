import Testing
@testable import RemoteOSCore

@Test func pairingLinkParserExtractsPairingCodeAndControlPlaneBaseURL() throws {
    let payload = try PairingLinkParser.parse("https://remoteos.app/?code=ABC123&api=https://control.remoteos.app")

    #expect(payload.pairingCode == "ABC123")
    #expect(payload.controlPlaneBaseURL == "https://control.remoteos.app")
}

@Test func pairingLinkParserRejectsMissingControlPlaneBaseURL() throws {
    #expect(throws: Error.self) {
        _ = try PairingLinkParser.parse("https://remoteos.app/?code=ABC123")
    }
}
