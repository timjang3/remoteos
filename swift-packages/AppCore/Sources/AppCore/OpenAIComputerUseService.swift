import Foundation

public struct ComputerUseSafetyCheck: Codable, Sendable, Equatable {
    public var id: String?
    public var code: String?
    public var message: String?

    public init(id: String?, code: String?, message: String?) {
        self.id = id
        self.code = code
        self.message = message
    }
}

public struct ComputerUseActionPoint: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
}

public struct ComputerUseAction: Decodable, Sendable, Equatable {
    public var type: String
    public var x: Double?
    public var y: Double?
    public var button: String?
    public var path: [ComputerUseActionPoint]?
    public var deltaX: Double?
    public var deltaY: Double?
    public var scrollY: Double?
    public var text: String?
    public var key: String?
    public var keys: [String]?
    public var ms: Double?
    public var durationMs: Double?

    enum CodingKeys: String, CodingKey {
        case type
        case x
        case y
        case button
        case path
        case deltaX = "deltaX"
        case deltaY = "deltaY"
        case scrollY = "scroll_y"
        case text
        case key
        case keys
        case ms
        case durationMs = "duration_ms"
        case deltaXSnake = "delta_x"
        case deltaYSnake = "delta_y"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        x = try container.decodeIfPresent(Double.self, forKey: .x)
        y = try container.decodeIfPresent(Double.self, forKey: .y)
        button = try container.decodeIfPresent(String.self, forKey: .button)
        path = try container.decodeIfPresent([ComputerUseActionPoint].self, forKey: .path)
        deltaX = try container.decodeIfPresent(Double.self, forKey: .deltaX)
            ?? (try container.decodeIfPresent(Double.self, forKey: .deltaXSnake))
        deltaY = try container.decodeIfPresent(Double.self, forKey: .deltaY)
            ?? (try container.decodeIfPresent(Double.self, forKey: .deltaYSnake))
        scrollY = try container.decodeIfPresent(Double.self, forKey: .scrollY)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        key = try container.decodeIfPresent(String.self, forKey: .key)
        keys = try container.decodeIfPresent([String].self, forKey: .keys)
        ms = try container.decodeIfPresent(Double.self, forKey: .ms)
        durationMs = try container.decodeIfPresent(Double.self, forKey: .durationMs)
    }

    public init(
        type: String,
        x: Double? = nil,
        y: Double? = nil,
        button: String? = nil,
        path: [ComputerUseActionPoint]? = nil,
        deltaX: Double? = nil,
        deltaY: Double? = nil,
        scrollY: Double? = nil,
        text: String? = nil,
        key: String? = nil,
        keys: [String]? = nil,
        ms: Double? = nil,
        durationMs: Double? = nil
    ) {
        self.type = type
        self.x = x
        self.y = y
        self.button = button
        self.path = path
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.scrollY = scrollY
        self.text = text
        self.key = key
        self.keys = keys
        self.ms = ms
        self.durationMs = durationMs
    }
}

public struct ComputerUseCall: Decodable, Sendable, Equatable {
    public var type: String
    public var callId: String
    public var actions: [ComputerUseAction]
    public var pendingSafetyChecks: [ComputerUseSafetyCheck]

    enum CodingKeys: String, CodingKey {
        case type
        case callId = "call_id"
        case actions
        case pendingSafetyChecks = "pending_safety_checks"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        callId = try container.decode(String.self, forKey: .callId)
        actions = try container.decode([ComputerUseAction].self, forKey: .actions)
        pendingSafetyChecks = try container.decodeIfPresent([ComputerUseSafetyCheck].self, forKey: .pendingSafetyChecks) ?? []
    }
}

public struct ComputerUseMessageContent: Decodable, Sendable, Equatable {
    public var type: String?
    public var text: String?
}

public struct ComputerUseMessage: Decodable, Sendable, Equatable {
    public var type: String
    public var role: String?
    public var content: [ComputerUseMessageContent]?
}

private enum OpenAIResponsesOutputItem: Decodable, Sendable {
    case computerCall(ComputerUseCall)
    case message(ComputerUseMessage)
    case other

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKeys.self)
        let type = try container.decode(String.self, forKey: DynamicCodingKeys("type"))
        switch type {
        case "computer_call":
            self = .computerCall(try ComputerUseCall(from: decoder))
        case "message":
            self = .message(try ComputerUseMessage(from: decoder))
        default:
            self = .other
        }
    }
}

private struct OpenAIResponsesError: Decodable, Sendable {
    var message: String?
}

private struct OpenAIResponsesResult: Decodable, Sendable {
    var id: String
    var output: [OpenAIResponsesOutputItem]?
    var status: String?
    var error: OpenAIResponsesError?
}

private struct DynamicCodingKeys: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

public actor OpenAIComputerUseService {
    public struct Configuration: Sendable, Equatable {
        public var apiKey: String
        public var model: String
        public var maxResponseTurns: Int
        public var wallClockTimeout: Duration
        public var instructions: String

        public init(
            apiKey: String,
            model: String,
            maxResponseTurns: Int,
            wallClockTimeout: Duration,
            instructions: String
        ) {
            self.apiKey = apiKey
            self.model = model
            self.maxResponseTurns = maxResponseTurns
            self.wallClockTimeout = wallClockTimeout
            self.instructions = instructions
        }
    }

    public enum RunStatus: String, Sendable {
        case completed
        case blocked
        case failed
        case cancelled
    }

    public struct RunResult: Sendable {
        public var status: RunStatus
        public var finalMessage: String
        public var finalFrame: CapturedFrame

        public init(status: RunStatus, finalMessage: String, finalFrame: CapturedFrame) {
            self.status = status
            self.finalMessage = finalMessage
            self.finalFrame = finalFrame
        }
    }

    private let urlSession: URLSession
    private let responsesURL: URL

    public init(
        urlSession: URLSession = .shared,
        responsesURL: URL = URL(string: "https://api.openai.com/v1/responses")!
    ) {
        self.urlSession = urlSession
        self.responsesURL = responsesURL
    }

    public func run(
        goal: String,
        invocation: DynamicToolInvocation,
        configuration: Configuration,
        captureFrame: @escaping @Sendable () async throws -> CapturedFrame,
        executeActions: @escaping @Sendable (CapturedFrame, [ComputerUseAction]) async throws -> CapturedFrame,
        requestPrompt: @escaping @Sendable (AgentPromptPayload) async -> AgentPromptResponsePayload?
    ) async throws -> RunResult {
        let clock = ContinuousClock()
        let startedAt = clock.now
        var previousResponseID: String?
        var currentFrame = try await captureFrame()
        var nextInput: Any = Self.initialInput(goal: goal, frame: currentFrame)

        for turn in 1...configuration.maxResponseTurns {
            try Task.checkCancellation()
            guard startedAt.duration(to: clock.now) < configuration.wallClockTimeout else {
                return RunResult(
                    status: .blocked,
                    finalMessage: "The computer-use run timed out before GPT-5.4 completed the task.",
                    finalFrame: currentFrame
                )
            }

            let payload = Self.responsePayload(
                configuration: configuration,
                input: nextInput,
                previousResponseID: previousResponseID
            )
            let response = try await createResponse(apiKey: configuration.apiKey, payload: payload)
            try Self.ensureResponseSucceeded(response)
            previousResponseID = response.id

            let computerCalls = (response.output ?? []).compactMap { item -> ComputerUseCall? in
                if case let .computerCall(call) = item {
                    return call
                }
                return nil
            }

            if computerCalls.isEmpty {
                let message = Self.assistantMessage(from: response) ??
                    "GPT-5.4 finished without a final message."
                return RunResult(status: .completed, finalMessage: message, finalFrame: currentFrame)
            }

            guard computerCalls.count == 1, let computerCall = computerCalls.first else {
                throw AppCoreError.invalidPayload("GPT-5.4 returned an unsupported multi-call computer batch.")
            }

            let acknowledgedSafetyChecks = try await handlePendingSafetyChecks(
                computerCall: computerCall,
                invocation: invocation,
                turnIndex: turn,
                requestPrompt: requestPrompt
            )

            currentFrame = try await executeActions(currentFrame, computerCall.actions)
            nextInput = [
                Self.computerCallOutput(
                    callID: computerCall.callId,
                    frame: currentFrame,
                    acknowledgedSafetyChecks: acknowledgedSafetyChecks
                )
            ]
        }

        return RunResult(
            status: .blocked,
            finalMessage: "The computer-use run exhausted the configured turn budget without a final answer.",
            finalFrame: currentFrame
        )
    }

    private func createResponse(
        apiKey: String,
        payload: [String: Any]
    ) async throws -> OpenAIResponsesResult {
        var request = URLRequest(url: responsesURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try dataFromJSONObject(payload)

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppCoreError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let errorObject = (try? anyDictionary(from: data)) ?? [:]
            let message = ((errorObject["error"] as? [String: Any])?["message"] as? String)
                ?? "OpenAI Responses API request failed with status \(httpResponse.statusCode)."
            throw AppCoreError.invalidPayload(message)
        }

        return try JSONDecoder().decode(OpenAIResponsesResult.self, from: data)
    }

    private func handlePendingSafetyChecks(
        computerCall: ComputerUseCall,
        invocation: DynamicToolInvocation,
        turnIndex: Int,
        requestPrompt: @escaping @Sendable (AgentPromptPayload) async -> AgentPromptResponsePayload?
    ) async throws -> [ComputerUseSafetyCheck] {
        guard !computerCall.pendingSafetyChecks.isEmpty else {
            return []
        }

        let prompt = AgentPromptPayload(
            id: "cua-safety-\(invocation.callId)-\(turnIndex)",
            turnId: invocation.turnId,
            source: .computerUse,
            kind: .safetyCheck,
            title: "Computer use needs confirmation",
            body: computerCall.pendingSafetyChecks
                .map { $0.message ?? $0.code ?? "Unknown safety check" }
                .joined(separator: "\n"),
            questions: [],
            choices: [
                AgentPromptChoicePayload(
                    id: AgentPromptResponseAction.accept.rawValue,
                    label: "Accept",
                    description: "Acknowledge the safety checks and continue."
                ),
                AgentPromptChoicePayload(
                    id: AgentPromptResponseAction.decline.rawValue,
                    label: "Decline",
                    description: "Stop the computer-use run."
                ),
                AgentPromptChoicePayload(
                    id: AgentPromptResponseAction.cancel.rawValue,
                    label: "Cancel",
                    description: "Cancel this prompt without continuing the run."
                )
            ],
            createdAt: isoNow(),
            updatedAt: isoNow()
        )

        let response = await requestPrompt(prompt)
        switch response?.action {
        case .accept:
            return computerCall.pendingSafetyChecks
        case .decline:
            throw AppCoreError.invalidPayload("The computer-use safety check was declined.")
        case .cancel, .none:
            throw CancellationError()
        default:
            throw CancellationError()
        }
    }

    private static func responsePayload(
        configuration: Configuration,
        input: Any,
        previousResponseID: String?
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "instructions": configuration.instructions,
            "input": input,
            "model": configuration.model,
            "parallel_tool_calls": false,
            "reasoning": [
                "effort": "low"
            ],
            "tools": [
                [
                    "type": "computer"
                ]
            ],
            "truncation": "auto"
        ]
        if let previousResponseID {
            payload["previous_response_id"] = previousResponseID
        }
        return payload
    }

    private static func initialInput(goal: String, frame: CapturedFrame) -> [[String: Any]] {
        [
            [
                "role": "user",
                "content": [
                    [
                        "type": "input_text",
                        "text": goal
                    ],
                    [
                        "type": "input_image",
                        "detail": "original",
                        "image_url": dataURL(for: frame)
                    ]
                ]
            ]
        ]
    }

    private static func computerCallOutput(
        callID: String,
        frame: CapturedFrame,
        acknowledgedSafetyChecks: [ComputerUseSafetyCheck]
    ) -> [String: Any] {
        var output: [String: Any] = [
            "type": "computer_call_output",
            "call_id": callID,
            "output": [
                "type": "computer_screenshot",
                "image_url": dataURL(for: frame)
            ]
        ]
        if !acknowledgedSafetyChecks.isEmpty {
            output["acknowledged_safety_checks"] = acknowledgedSafetyChecks.map { check in
                var value: [String: Any] = [:]
                if let id = check.id {
                    value["id"] = id
                }
                if let code = check.code {
                    value["code"] = code
                }
                if let message = check.message {
                    value["message"] = message
                }
                return value
            }
        }
        return output
    }

    private static func dataURL(for frame: CapturedFrame) -> String {
        "data:\(frame.mimeType);base64,\(frame.dataBase64)"
    }

    private static func ensureResponseSucceeded(_ response: OpenAIResponsesResult) throws {
        if let message = response.error?.message, !message.isEmpty {
            throw AppCoreError.invalidPayload(message)
        }
        if response.status == "failed" {
            throw AppCoreError.invalidPayload("The OpenAI Responses request failed.")
        }
    }

    private static func assistantMessage(from response: OpenAIResponsesResult) -> String? {
        let messages = (response.output ?? []).compactMap { item -> String? in
            guard case let .message(message) = item else {
                return nil
            }
            return message.content?
                .compactMap { content in
                    guard content.type == "output_text" || content.type == nil else {
                        return nil
                    }
                    return content.text
                }
                .joined(separator: "\n")
        }

        let text = messages
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
}
