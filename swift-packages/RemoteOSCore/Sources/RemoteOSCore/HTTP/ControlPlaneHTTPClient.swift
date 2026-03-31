import Foundation

public enum WebSocketTicketRequest: Sendable, Equatable {
    case host(deviceId: String, deviceSecret: String)
    case client(clientToken: String)
}

public struct MobileAuthStartRequest: Codable, Equatable, Sendable {
    public var redirectUri: String
    public var provider: String

    public init(redirectUri: String, provider: String = "google") {
        self.redirectUri = redirectUri
        self.provider = provider
    }
}

public struct MobileAuthExchangeRequest: Codable, Equatable, Sendable {
    public var code: String

    public init(code: String) {
        self.code = code
    }
}

public final class ControlPlaneHTTPClient: @unchecked Sendable {
    private let log = RemoteOSLogs.controlPlane
    private let urlSession: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let authTokenProvider: @Sendable () async -> String?

    public init(
        urlSession: URLSession = .shared,
        authTokenProvider: @escaping @Sendable () async -> String? = { nil }
    ) {
        self.urlSession = urlSession
        self.authTokenProvider = authTokenProvider
    }

    public func getHealth(baseURL: String) async throws -> ControlPlaneHealthPayload {
        try await request(
            baseURL: baseURL,
            path: "/health",
            response: ControlPlaneHealthPayload.self
        )
    }

    public func claimPairing(baseURL: String, pairingCode: String, clientName: String) async throws -> PairingClaimResponsePayload {
        try await request(
            baseURL: baseURL,
            path: "/pairings/\(pairingCode)/claim",
            method: "POST",
            body: ["clientName": clientName],
            response: PairingClaimResponsePayload.self
        )
    }

    public func bootstrap(baseURL: String, clientToken: String) async throws -> BootstrapPayload {
        try await request(
            baseURL: baseURL,
            path: "/bootstrap?clientToken=\(clientToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? clientToken)",
            response: BootstrapPayload.self,
            requiresAuthorization: true
        )
    }

    public func createWebSocketTicket(baseURL: String, request ticketRequest: WebSocketTicketRequest) async throws -> WebSocketTicketPayload {
        let body: [String: String]
        switch ticketRequest {
        case let .host(deviceId, deviceSecret):
            body = [
                "type": "host",
                "deviceId": deviceId,
                "deviceSecret": deviceSecret
            ]
        case let .client(clientToken):
            body = [
                "type": "client",
                "clientToken": clientToken
            ]
        }

        return try await request(
            baseURL: baseURL,
            path: "/ws/ticket",
            method: "POST",
            body: body,
            response: WebSocketTicketPayload.self,
            requiresAuthorization: true
        )
    }

    public func createSpeechTranscription(
        baseURL: String,
        clientToken: String,
        audio: Data,
        filename: String,
        mimeType: String,
        language: String? = nil,
        durationMs: Int? = nil
    ) async throws -> SpeechTranscriptionPayload {
        let boundary = "RemoteOSBoundary-\(UUID().uuidString)"
        var request = try await makeRequest(
            baseURL: baseURL,
            path: "/speech/transcriptions",
            method: "POST",
            contentType: "multipart/form-data; boundary=\(boundary)",
            requiresAuthorization: true
        )
        request.httpBody = multipartBody(
            boundary: boundary,
            clientToken: clientToken,
            audio: audio,
            filename: filename,
            mimeType: mimeType,
            language: language,
            durationMs: durationMs
        )
        return try await perform(request, response: SpeechTranscriptionPayload.self)
    }

    public func getEnrollment(baseURL: String, token: String) async throws -> DeviceEnrollmentPayload {
        try await request(
            baseURL: baseURL,
            path: "/devices/enrollments/\(token.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? token)",
            response: DeviceEnrollmentPayload.self,
            requiresAuthorization: false
        )
    }

    public func approveEnrollment(baseURL: String, token: String) async throws -> DeviceEnrollmentPayload {
        try await request(
            baseURL: baseURL,
            path: "/devices/enrollments/\(token.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? token)/approve",
            method: "POST",
            response: DeviceEnrollmentPayload.self,
            requiresAuthorization: true
        )
    }

    public func mobileAuthStartURL(baseURL: String, request payload: MobileAuthStartRequest) throws -> URL {
        guard var components = URLComponents(string: normalizedBaseURL(baseURL) + "/mobile/auth/start") else {
            throw AppCoreError.invalidPayload("Invalid control plane URL \(baseURL)")
        }

        components.queryItems = [
            URLQueryItem(name: "redirectUri", value: payload.redirectUri),
            URLQueryItem(name: "provider", value: payload.provider)
        ]

        guard let url = components.url else {
            throw AppCoreError.invalidPayload("Invalid mobile auth start URL")
        }

        return url
    }

    public func exchangeMobileAuth(baseURL: String, code: String) async throws -> MobileAuthExchangePayload {
        try await request(
            baseURL: baseURL,
            path: "/mobile/auth/exchange",
            method: "POST",
            body: MobileAuthExchangeRequest(code: code),
            response: MobileAuthExchangePayload.self,
            requiresAuthorization: false
        )
    }

    private func request<Response: Decodable, Body: Encodable>(
        baseURL: String,
        path: String,
        method: String = "GET",
        body: Body? = nil,
        response: Response.Type = Response.self,
        requiresAuthorization: Bool = false
    ) async throws -> Response {
        var request = try await makeRequest(
            baseURL: baseURL,
            path: path,
            method: method,
            requiresAuthorization: requiresAuthorization
        )

        if let body {
            request.httpBody = try encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }

        return try await perform(request, response: response)
    }

    private func request<Response: Decodable>(
        baseURL: String,
        path: String,
        method: String = "GET",
        response: Response.Type = Response.self,
        requiresAuthorization: Bool = false
    ) async throws -> Response {
        try await request(
            baseURL: baseURL,
            path: path,
            method: method,
            body: Optional<String>.none,
            response: response,
            requiresAuthorization: requiresAuthorization
        )
    }

    private func makeRequest(
        baseURL: String,
        path: String,
        method: String,
        contentType: String? = nil,
        requiresAuthorization: Bool = false
    ) async throws -> URLRequest {
        guard let url = URL(string: normalizedBaseURL(baseURL) + path) else {
            throw AppCoreError.invalidPayload("Invalid control plane URL \(baseURL)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "content-type")
        }
        let token = await authTokenProvider()?.trimmingCharacters(in: .whitespacesAndNewlines)
        if requiresAuthorization, let token, token.isEmpty == false {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        }
        return request
    }

    private func perform<Response: Decodable>(_ request: URLRequest, response: Response.Type) async throws -> Response {
        log.info("HTTP \(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "unknown")")
        let (data, urlResponse) = try await urlSession.data(for: request)
        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw AppCoreError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let message = try errorMessage(from: data, fallbackStatusCode: httpResponse.statusCode)
            throw AppCoreError.invalidPayload(message)
        }

        return try decoder.decode(response, from: data)
    }

    private func errorMessage(from data: Data, fallbackStatusCode: Int) throws -> String {
        if
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = object["error"] as? String,
            error.isEmpty == false
        {
            return error
        }
        return "Request failed with \(fallbackStatusCode)"
    }

    private func normalizedBaseURL(_ value: String) -> String {
        value.replacingOccurrences(of: "/$", with: "", options: .regularExpression)
    }

    private func multipartBody(
        boundary: String,
        clientToken: String,
        audio: Data,
        filename: String,
        mimeType: String,
        language: String?,
        durationMs: Int?
    ) -> Data {
        var body = Data()

        func appendField(name: String, value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }

        appendField(name: "clientToken", value: clientToken)
        if let language, language.isEmpty == false {
            appendField(name: "language", value: language)
        }
        if let durationMs {
            appendField(name: "durationMs", value: String(durationMs))
        }

        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"audio\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
}
