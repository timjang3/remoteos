import Foundation
import RemoteOSCore

actor ControlPlaneService {
    private let sessionStore: ClientSessionStore
    private let httpClient: ControlPlaneHTTPClient

    init(sessionStore: ClientSessionStore = ClientSessionStore()) {
        self.sessionStore = sessionStore
        self.httpClient = ControlPlaneHTTPClient(
            authTokenProvider: { [sessionStore] in
                await sessionStore.load().authToken
            }
        )
    }

    func loadStoredSession() async -> StoredClientSession {
        await sessionStore.load()
    }

    func saveControlPlaneBaseURL(_ value: String?) async {
        await sessionStore.save(controlPlaneBaseURL: value)
    }

    func saveClientName(_ value: String) async {
        await sessionStore.save(clientName: value)
    }

    func saveClientToken(_ value: String?) async {
        await sessionStore.save(clientToken: value)
    }

    func saveAuthToken(_ value: String?) async {
        await sessionStore.save(authToken: value)
    }

    func clearClientToken() async {
        await sessionStore.clearClientToken()
    }

    func clearAllTokens() async {
        await sessionStore.clearAll()
    }

    func getHealth(baseURL: String) async throws -> ControlPlaneHealthPayload {
        try await httpClient.getHealth(baseURL: baseURL)
    }

    func claimPairing(
        baseURL: String,
        pairingCode: String,
        clientName: String
    ) async throws -> PairingClaimResponsePayload {
        try await httpClient.claimPairing(
            baseURL: baseURL,
            pairingCode: pairingCode,
            clientName: clientName
        )
    }

    func bootstrap(
        baseURL: String,
        clientToken: String
    ) async throws -> BootstrapPayload {
        try await httpClient.bootstrap(baseURL: baseURL, clientToken: clientToken)
    }

    func webSocketURL(
        baseURL: String,
        bootstrap: BootstrapPayload,
        authMode: ControlPlaneAuthMode,
        clientToken: String
    ) async throws -> String {
        if authMode == .required {
            return try await httpClient.createWebSocketTicket(
                baseURL: baseURL,
                request: .client(clientToken: clientToken)
            ).wsUrl
        }

        return bootstrap.wsUrl
    }

    func mobileAuthStartURL(baseURL: String, redirectURI: String) throws -> URL {
        try httpClient.mobileAuthStartURL(
            baseURL: baseURL,
            request: MobileAuthStartRequest(redirectUri: redirectURI)
        )
    }

    func exchangeMobileAuth(baseURL: String, code: String) async throws -> MobileAuthExchangePayload {
        try await httpClient.exchangeMobileAuth(baseURL: baseURL, code: code)
    }

    func createSpeechTranscription(
        baseURL: String,
        clientToken: String,
        audioData: Data,
        filename: String,
        mimeType: String,
        language: String?,
        durationMs: Int?
    ) async throws -> SpeechTranscriptionPayload {
        try await httpClient.createSpeechTranscription(
            baseURL: baseURL,
            clientToken: clientToken,
            audio: audioData,
            filename: filename,
            mimeType: mimeType,
            language: language,
            durationMs: durationMs
        )
    }
}
