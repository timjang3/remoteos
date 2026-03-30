import Foundation

public enum WindowCapability: String, Codable, CaseIterable, Sendable {
    case managedBrowser = "managed_browser"
    case scriptableNative = "scriptable_native"
    case axRead = "ax_read"
    case axWrite = "ax_write"
    case pixelFallback = "pixel_fallback"
    case genericElectron = "generic_electron"
}

public enum PermissionStatus: String, Codable, Sendable {
    case unknown
    case granted
    case denied
    case needsPrompt = "needs_prompt"
}

public enum HostMode: String, Codable, Sendable {
    case hosted
    case direct
}

public enum ControlPlaneAuthMode: String, Codable, Sendable {
    case none
    case required
}

public enum CodexRuntimeState: String, Codable, Sendable {
    case unknown
    case missingCLI = "missing_cli"
    case unauthenticated
    case starting
    case ready
    case running
    case error
}

public enum AgentTurnStatus: String, Codable, Sendable {
    case running
    case completed
    case interrupted
    case failed
}

public enum AgentItemKind: String, Codable, Sendable {
    case userMessage = "user_message"
    case assistantMessage = "assistant_message"
    case reasoning
    case plan
    case command
    case fileChange = "file_change"
    case mcpTool = "mcp_tool"
    case dynamicTool = "dynamic_tool"
    case system
}

public enum AgentItemStatus: String, Codable, Sendable {
    case inProgress = "in_progress"
    case completed
    case failed
    case declined
}

public enum AgentPromptSource: String, Codable, Sendable {
    case codex
    case computerUse = "computer_use"
}

public enum AgentPromptKind: String, Codable, Sendable {
    case requestUserInput = "request_user_input"
    case safetyCheck = "safety_check"
}

public enum AgentPromptResponseAction: String, Codable, Sendable {
    case submit
    case accept
    case decline
    case cancel
}

public enum AgentPromptResolutionStatus: String, Codable, Sendable {
    case submitted
    case accepted
    case declined
    case cancelled
    case expired
    case interrupted
}

public enum DeviceEnrollmentStatus: String, Codable, Sendable, Equatable {
    case pending
    case approved
    case expired
}

public enum StreamProfile: String, Codable, CaseIterable, Sendable {
    case full
    case balanced
    case lowData = "low_data"
}

public struct WindowBounds: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct WindowDescriptor: Codable, Identifiable, Sendable, Equatable {
    public var id: Int
    public var ownerPid: Int
    public var ownerName: String
    public var appBundleId: String?
    public var title: String
    public var bounds: WindowBounds
    public var isOnScreen: Bool
    public var capabilities: [WindowCapability]
    public var semanticSummary: String?

    public init(
        id: Int,
        ownerPid: Int,
        ownerName: String,
        appBundleId: String?,
        title: String,
        bounds: WindowBounds,
        isOnScreen: Bool,
        capabilities: [WindowCapability],
        semanticSummary: String?
    ) {
        self.id = id
        self.ownerPid = ownerPid
        self.ownerName = ownerName
        self.appBundleId = appBundleId
        self.title = title
        self.bounds = bounds
        self.isOnScreen = isOnScreen
        self.capabilities = capabilities
        self.semanticSummary = semanticSummary
    }
}

public struct SemanticElement: Codable, Sendable, Equatable {
    public var role: String
    public var title: String?
    public var value: String?
    public var help: String?
    public var enabled: Bool?

    public init(role: String, title: String?, value: String?, help: String?, enabled: Bool?) {
        self.role = role
        self.title = title
        self.value = value
        self.help = help
        self.enabled = enabled
    }
}

public struct SemanticSnapshot: Codable, Sendable, Equatable {
    public var windowId: Int
    public var focused: SemanticElement?
    public var elements: [SemanticElement]
    public var summary: String
    public var generatedAt: String

    public init(windowId: Int, focused: SemanticElement?, elements: [SemanticElement], summary: String, generatedAt: String) {
        self.windowId = windowId
        self.focused = focused
        self.elements = elements
        self.summary = summary
        self.generatedAt = generatedAt
    }
}

public struct WindowFramePayload: Codable, Sendable, Equatable {
    public var windowId: Int
    public var frameId: String
    public var capturedAt: String
    public var mimeType: String
    public var dataBase64: String
    public var width: Int
    public var height: Int
    public var displayId: Int?
    public var sourceRectPoints: WindowBounds
    public var pointPixelScale: Double

    public init(
        windowId: Int,
        frameId: String,
        capturedAt: String,
        mimeType: String,
        dataBase64: String,
        width: Int,
        height: Int,
        displayId: Int?,
        sourceRectPoints: WindowBounds,
        pointPixelScale: Double
    ) {
        self.windowId = windowId
        self.frameId = frameId
        self.capturedAt = capturedAt
        self.mimeType = mimeType
        self.dataBase64 = dataBase64
        self.width = width
        self.height = height
        self.displayId = displayId
        self.sourceRectPoints = sourceRectPoints
        self.pointPixelScale = pointPixelScale
    }
}

public struct WindowSnapshotPayload: Codable, Sendable, Equatable {
    public var window: WindowDescriptor
    public var capturedAt: String
    public var mimeType: String
    public var dataBase64: String

    public init(window: WindowDescriptor, capturedAt: String, mimeType: String, dataBase64: String) {
        self.window = window
        self.capturedAt = capturedAt
        self.mimeType = mimeType
        self.dataBase64 = dataBase64
    }
}

public struct SemanticDiffPayload: Codable, Sendable, Equatable {
    public var windowId: Int
    public var changedAt: String
    public var summary: String

    public init(windowId: Int, changedAt: String, summary: String) {
        self.windowId = windowId
        self.changedAt = changedAt
        self.summary = summary
    }
}

public struct CodexStatusPayload: Codable, Sendable, Equatable {
    public var state: CodexRuntimeState
    public var installed: Bool
    public var authenticated: Bool
    public var authMode: String?
    public var model: String?
    public var threadId: String?
    public var activeTurnId: String?
    public var lastError: String?

    public init(
        state: CodexRuntimeState,
        installed: Bool,
        authenticated: Bool,
        authMode: String?,
        model: String?,
        threadId: String?,
        activeTurnId: String?,
        lastError: String?
    ) {
        self.state = state
        self.installed = installed
        self.authenticated = authenticated
        self.authMode = authMode
        self.model = model
        self.threadId = threadId
        self.activeTurnId = activeTurnId
        self.lastError = lastError
    }
}

public struct HostStatusPayload: Codable, Sendable, Equatable {
    public var deviceId: String
    public var online: Bool
    public var selectedWindowId: Int?
    public var screenRecording: PermissionStatus
    public var accessibility: PermissionStatus
    public var directUrl: String?
    public var codex: CodexStatusPayload

    public init(
        deviceId: String,
        online: Bool,
        selectedWindowId: Int?,
        screenRecording: PermissionStatus,
        accessibility: PermissionStatus,
        directUrl: String?,
        codex: CodexStatusPayload
    ) {
        self.deviceId = deviceId
        self.online = online
        self.selectedWindowId = selectedWindowId
        self.screenRecording = screenRecording
        self.accessibility = accessibility
        self.directUrl = directUrl
        self.codex = codex
    }
}

public struct AgentTurnPayload: Codable, Sendable, Equatable {
    public var id: String
    public var prompt: String
    public var targetWindowId: Int?
    public var status: AgentTurnStatus
    public var error: String?
    public var startedAt: String
    public var updatedAt: String
    public var completedAt: String?

    public init(
        id: String,
        prompt: String,
        targetWindowId: Int?,
        status: AgentTurnStatus,
        error: String?,
        startedAt: String,
        updatedAt: String,
        completedAt: String?
    ) {
        self.id = id
        self.prompt = prompt
        self.targetWindowId = targetWindowId
        self.status = status
        self.error = error
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }
}

public struct AgentItemPayload: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var turnId: String
    public var kind: AgentItemKind
    public var status: AgentItemStatus
    public var title: String
    public var body: String?
    public var createdAt: String
    public var updatedAt: String
    public var metadata: [String: String]

    public init(
        id: String,
        turnId: String,
        kind: AgentItemKind,
        status: AgentItemStatus,
        title: String,
        body: String?,
        createdAt: String,
        updatedAt: String,
        metadata: [String: String]
    ) {
        self.id = id
        self.turnId = turnId
        self.kind = kind
        self.status = status
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadata = metadata
    }
}

public extension AgentItemPayload {
    static func userMessage(turnID: String, prompt: String, timestamp: String) -> AgentItemPayload {
        AgentItemPayload(
            id: "user-\(turnID)",
            turnId: turnID,
            kind: .userMessage,
            status: .completed,
            title: "User",
            body: prompt,
            createdAt: timestamp,
            updatedAt: timestamp,
            metadata: [:]
        )
    }
}

public struct AgentPromptOptionPayload: Codable, Sendable, Equatable {
    public var label: String
    public var description: String

    public init(label: String, description: String) {
        self.label = label
        self.description = description
    }
}

public struct AgentPromptQuestionPayload: Codable, Sendable, Equatable {
    public var id: String
    public var header: String
    public var question: String
    public var isOther: Bool
    public var isSecret: Bool
    public var options: [AgentPromptOptionPayload]?

    public init(
        id: String,
        header: String,
        question: String,
        isOther: Bool,
        isSecret: Bool,
        options: [AgentPromptOptionPayload]?
    ) {
        self.id = id
        self.header = header
        self.question = question
        self.isOther = isOther
        self.isSecret = isSecret
        self.options = options
    }
}

public struct AgentPromptChoicePayload: Codable, Sendable, Equatable {
    public var id: String
    public var label: String
    public var description: String

    public init(id: String, label: String, description: String) {
        self.id = id
        self.label = label
        self.description = description
    }
}

public struct AgentPromptPayload: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var turnId: String
    public var source: AgentPromptSource
    public var kind: AgentPromptKind
    public var title: String
    public var body: String?
    public var questions: [AgentPromptQuestionPayload]
    public var choices: [AgentPromptChoicePayload]?
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String,
        turnId: String,
        source: AgentPromptSource,
        kind: AgentPromptKind,
        title: String,
        body: String?,
        questions: [AgentPromptQuestionPayload],
        choices: [AgentPromptChoicePayload]?,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.turnId = turnId
        self.source = source
        self.kind = kind
        self.title = title
        self.body = body
        self.questions = questions
        self.choices = choices
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct AgentPromptAnswerPayload: Codable, Sendable, Equatable {
    public var answers: [String]

    public init(answers: [String]) {
        self.answers = answers
    }
}

public struct AgentPromptResponsePayload: Codable, Sendable, Equatable {
    public var id: String
    public var action: AgentPromptResponseAction
    public var answers: [String: AgentPromptAnswerPayload]

    public init(id: String, action: AgentPromptResponseAction, answers: [String: AgentPromptAnswerPayload] = [:]) {
        self.id = id
        self.action = action
        self.answers = answers
    }
}

public struct AgentPromptResolvedPayload: Codable, Sendable, Equatable {
    public var id: String
    public var turnId: String
    public var status: AgentPromptResolutionStatus
    public var resolvedAt: String

    public init(id: String, turnId: String, status: AgentPromptResolutionStatus, resolvedAt: String) {
        self.id = id
        self.turnId = turnId
        self.status = status
        self.resolvedAt = resolvedAt
    }
}

public struct TraceEventPayload: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var taskId: String?
    public var level: String
    public var kind: String
    public var message: String
    public var createdAt: String
    public var metadata: [String: String]

    public init(
        id: String,
        taskId: String?,
        level: String,
        kind: String,
        message: String,
        createdAt: String,
        metadata: [String: String]
    ) {
        self.id = id
        self.taskId = taskId
        self.level = level
        self.kind = kind
        self.message = message
        self.createdAt = createdAt
        self.metadata = metadata
    }
}

public struct DevicePayload: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var mode: HostMode
    public var online: Bool
    public var registeredAt: String
    public var lastSeenAt: String?

    public init(id: String, name: String, mode: HostMode, online: Bool, registeredAt: String, lastSeenAt: String?) {
        self.id = id
        self.name = name
        self.mode = mode
        self.online = online
        self.registeredAt = registeredAt
        self.lastSeenAt = lastSeenAt
    }
}

public struct BrokerRegistration: Codable, Sendable, Equatable {
    public var device: DevicePayload?
    public var deviceId: String?
    public var deviceSecret: String
    public var wsUrl: String?
    public var approvalRequired: Bool?
    public var enrollmentUrl: String?
    public var enrollmentToken: String?
    public var expiresAt: String?

    public init(
        device: DevicePayload?,
        deviceId: String?,
        deviceSecret: String,
        wsUrl: String?,
        approvalRequired: Bool?,
        enrollmentUrl: String?,
        enrollmentToken: String?,
        expiresAt: String?
    ) {
        self.device = device
        self.deviceId = deviceId
        self.deviceSecret = deviceSecret
        self.wsUrl = wsUrl
        self.approvalRequired = approvalRequired
        self.enrollmentUrl = enrollmentUrl
        self.enrollmentToken = enrollmentToken
        self.expiresAt = expiresAt
    }

    public var isApprovalRequired: Bool {
        approvalRequired == true
    }
}

public struct PairingSessionPayload: Codable, Sendable, Equatable {
    public var id: String
    public var deviceId: String
    public var pairingCode: String
    public var claimed: Bool
    public var expiresAt: String
    public var createdAt: String
    public var pairingUrl: String

    public init(
        id: String,
        deviceId: String,
        pairingCode: String,
        claimed: Bool,
        expiresAt: String,
        createdAt: String,
        pairingUrl: String
    ) {
        self.id = id
        self.deviceId = deviceId
        self.pairingCode = pairingCode
        self.claimed = claimed
        self.expiresAt = expiresAt
        self.createdAt = createdAt
        self.pairingUrl = pairingUrl
    }
}

public struct ControlPlaneHealthPayload: Codable, Sendable, Equatable {
    public var ok: Bool
    public var now: String
    public var authMode: ControlPlaneAuthMode
    public var googleAuthEnabled: Bool?

    public init(ok: Bool, now: String, authMode: ControlPlaneAuthMode, googleAuthEnabled: Bool?) {
        self.ok = ok
        self.now = now
        self.authMode = authMode
        self.googleAuthEnabled = googleAuthEnabled
    }
}

public struct DeviceEnrollmentPayload: Codable, Sendable, Equatable {
    public var id: String
    public var token: String
    public var deviceId: String
    public var deviceName: String
    public var deviceMode: HostMode
    public var status: DeviceEnrollmentStatus
    public var enrollmentUrl: String
    public var expiresAt: String
    public var createdAt: String
    public var approvedAt: String?
    public var approvedByUserId: String?

    public init(
        id: String,
        token: String,
        deviceId: String,
        deviceName: String,
        deviceMode: HostMode,
        status: DeviceEnrollmentStatus,
        enrollmentUrl: String,
        expiresAt: String,
        createdAt: String,
        approvedAt: String?,
        approvedByUserId: String?
    ) {
        self.id = id
        self.token = token
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.deviceMode = deviceMode
        self.status = status
        self.enrollmentUrl = enrollmentUrl
        self.expiresAt = expiresAt
        self.createdAt = createdAt
        self.approvedAt = approvedAt
        self.approvedByUserId = approvedByUserId
    }
}

public struct WebSocketTicketPayload: Codable, Sendable, Equatable {
    public var ticket: String
    public var expiresAt: String
    public var wsUrl: String

    public init(ticket: String, expiresAt: String, wsUrl: String) {
        self.ticket = ticket
        self.expiresAt = expiresAt
        self.wsUrl = wsUrl
    }
}

public struct BootstrapClientPayload: Codable, Sendable, Equatable {
    public var id: String
    public var deviceId: String
    public var name: String
    public var token: String

    public init(id: String, deviceId: String, name: String, token: String) {
        self.id = id
        self.deviceId = deviceId
        self.name = name
        self.token = token
    }
}

public struct SpeechCapabilitiesPayload: Codable, Sendable, Equatable {
    public var transcriptionAvailable: Bool
    public var provider: String?
    public var maxDurationMs: Int
    public var maxUploadBytes: Int

    public init(transcriptionAvailable: Bool, provider: String?, maxDurationMs: Int, maxUploadBytes: Int) {
        self.transcriptionAvailable = transcriptionAvailable
        self.provider = provider
        self.maxDurationMs = maxDurationMs
        self.maxUploadBytes = maxUploadBytes
    }
}

public struct BootstrapPayload: Codable, Sendable, Equatable {
    public var client: BootstrapClientPayload
    public var device: DevicePayload
    public var windows: [WindowDescriptor]
    public var status: HostStatusPayload
    public var wsUrl: String
    public var speech: SpeechCapabilitiesPayload

    public init(
        client: BootstrapClientPayload,
        device: DevicePayload,
        windows: [WindowDescriptor],
        status: HostStatusPayload,
        wsUrl: String,
        speech: SpeechCapabilitiesPayload
    ) {
        self.client = client
        self.device = device
        self.windows = windows
        self.status = status
        self.wsUrl = wsUrl
        self.speech = speech
    }
}

public struct PairingClaimResponsePayload: Codable, Sendable, Equatable {
    public var pairing: PairingSessionPayload
    public var clientToken: String
    public var wsUrl: String

    public init(pairing: PairingSessionPayload, clientToken: String, wsUrl: String) {
        self.pairing = pairing
        self.clientToken = clientToken
        self.wsUrl = wsUrl
    }
}

public struct SpeechTranscriptionPayload: Codable, Sendable, Equatable {
    public var text: String
    public var provider: String
    public var model: String

    public init(text: String, provider: String, model: String) {
        self.text = text
        self.provider = provider
        self.model = model
    }
}

public struct MobileAuthStartPayload: Codable, Sendable, Equatable {
    public var authorizationUrl: String
    public var expiresAt: String

    public init(authorizationUrl: String, expiresAt: String) {
        self.authorizationUrl = authorizationUrl
        self.expiresAt = expiresAt
    }
}

public struct MobileAuthExchangePayload: Codable, Sendable, Equatable {
    public var authToken: String
    public var user: MobileAuthUserPayload
    public var expiresAt: String?

    public init(authToken: String, user: MobileAuthUserPayload, expiresAt: String?) {
        self.authToken = authToken
        self.user = user
        self.expiresAt = expiresAt
    }
}

public struct MobileAuthUserPayload: Codable, Sendable, Equatable {
    public var id: String
    public var email: String
    public var name: String?
    public var image: String?

    public init(id: String, email: String, name: String?, image: String?) {
        self.id = id
        self.email = email
        self.name = name
        self.image = image
    }
}

public struct StreamStartPayload: Codable, Sendable, Equatable {
    public var windowId: Int
    public var profile: StreamProfile?

    public init(windowId: Int, profile: StreamProfile? = nil) {
        self.windowId = windowId
        self.profile = profile
    }
}

public struct StreamStopPayload: Codable, Sendable, Equatable {
    public var windowId: Int

    public init(windowId: Int) {
        self.windowId = windowId
    }
}

public struct WindowSelectionPayload: Codable, Sendable, Equatable {
    public var windowId: Int

    public init(windowId: Int) {
        self.windowId = windowId
    }
}

public struct InputTapPayload: Codable, Sendable, Equatable {
    public var windowId: Int
    public var frameId: String
    public var normalizedX: Double
    public var normalizedY: Double
    public var clickCount: Int

    public init(windowId: Int, frameId: String, normalizedX: Double, normalizedY: Double, clickCount: Int) {
        self.windowId = windowId
        self.frameId = frameId
        self.normalizedX = normalizedX
        self.normalizedY = normalizedY
        self.clickCount = clickCount
    }
}

public struct InputDragPayload: Codable, Sendable, Equatable {
    public var windowId: Int
    public var frameId: String
    public var fromX: Double
    public var fromY: Double
    public var toX: Double
    public var toY: Double

    public init(windowId: Int, frameId: String, fromX: Double, fromY: Double, toX: Double, toY: Double) {
        self.windowId = windowId
        self.frameId = frameId
        self.fromX = fromX
        self.fromY = fromY
        self.toX = toX
        self.toY = toY
    }
}

public struct InputScrollPayload: Codable, Sendable, Equatable {
    public var windowId: Int
    public var frameId: String
    public var deltaX: Double
    public var deltaY: Double

    public init(windowId: Int, frameId: String, deltaX: Double, deltaY: Double) {
        self.windowId = windowId
        self.frameId = frameId
        self.deltaX = deltaX
        self.deltaY = deltaY
    }
}

public struct InputKeyPayload: Codable, Sendable, Equatable {
    public var windowId: Int
    public var frameId: String
    public var text: String?
    public var key: String?

    public init(windowId: Int, frameId: String, text: String?, key: String?) {
        self.windowId = windowId
        self.frameId = frameId
        self.text = text
        self.key = key
    }
}

public struct AgentTurnStartPayload: Codable, Sendable, Equatable {
    public var prompt: String

    public init(prompt: String) {
        self.prompt = prompt
    }
}

public struct AgentTurnStartResultPayload: Codable, Sendable, Equatable {
    public var turn: AgentTurnPayload
    public var userItem: AgentItemPayload

    public init(turn: AgentTurnPayload, userItem: AgentItemPayload) {
        self.turn = turn
        self.userItem = userItem
    }
}

public struct AgentStateGetResultPayload: Codable, Sendable, Equatable {
    public var turn: AgentTurnPayload?
    public var items: [AgentItemPayload]
    public var prompts: [AgentPromptPayload]

    public init(turn: AgentTurnPayload?, items: [AgentItemPayload], prompts: [AgentPromptPayload]) {
        self.turn = turn
        self.items = items
        self.prompts = prompts
    }
}

public struct AgentTurnCancelPayload: Codable, Sendable, Equatable {
    public var turnId: String

    public init(turnId: String) {
        self.turnId = turnId
    }
}

public struct SemanticSnapshotRequestPayload: Codable, Sendable, Equatable {
    public var windowId: Int

    public init(windowId: Int) {
        self.windowId = windowId
    }
}

public struct WindowsListPayload: Codable, Sendable, Equatable {
    public var windows: [WindowDescriptor]

    public init(windows: [WindowDescriptor]) {
        self.windows = windows
    }
}

public enum RemoteOSNotification: Sendable, Equatable {
    case windowsUpdated(WindowsListPayload)
    case windowSnapshot(WindowSnapshotPayload)
    case windowFrame(WindowFramePayload)
    case semanticDiff(SemanticDiffPayload)
    case agentTurn(AgentTurnPayload)
    case agentItem(AgentItemPayload)
    case agentPromptRequested(AgentPromptPayload)
    case agentPromptResolved(AgentPromptResolvedPayload)
    case traceEvent(TraceEventPayload)
    case hostStatus(HostStatusPayload)
    case codexStatus(CodexStatusPayload)

    public init(method: String, params: JSONValue?) throws {
        switch method {
        case RemoteOSRPCMethod.windowsUpdated.rawValue:
            self = .windowsUpdated(try params.requireDecoded(WindowsListPayload.self))
        case RemoteOSRPCMethod.windowSnapshot.rawValue:
            self = .windowSnapshot(try params.requireDecoded(WindowSnapshotPayload.self))
        case RemoteOSRPCMethod.windowFrame.rawValue:
            self = .windowFrame(try params.requireDecoded(WindowFramePayload.self))
        case RemoteOSRPCMethod.semanticDiff.rawValue:
            self = .semanticDiff(try params.requireDecoded(SemanticDiffPayload.self))
        case RemoteOSRPCMethod.agentTurn.rawValue:
            self = .agentTurn(try params.requireDecoded(AgentTurnPayload.self))
        case RemoteOSRPCMethod.agentItem.rawValue:
            self = .agentItem(try params.requireDecoded(AgentItemPayload.self))
        case RemoteOSRPCMethod.agentPromptRequested.rawValue:
            self = .agentPromptRequested(try params.requireDecoded(AgentPromptPayload.self))
        case RemoteOSRPCMethod.agentPromptResolved.rawValue:
            self = .agentPromptResolved(try params.requireDecoded(AgentPromptResolvedPayload.self))
        case RemoteOSRPCMethod.traceEvent.rawValue:
            self = .traceEvent(try params.requireDecoded(TraceEventPayload.self))
        case RemoteOSRPCMethod.hostStatus.rawValue:
            self = .hostStatus(try params.requireDecoded(HostStatusPayload.self))
        case RemoteOSRPCMethod.codexStatus.rawValue:
            self = .codexStatus(try params.requireDecoded(CodexStatusPayload.self))
        default:
            throw AppCoreError.invalidPayload("Unsupported notification method \(method)")
        }
    }
}

private extension Optional where Wrapped == JSONValue {
    func requireDecoded<T: Decodable>(_ type: T.Type) throws -> T {
        guard let value = self else {
            throw AppCoreError.invalidPayload("Missing JSON payload")
        }
        return try value.decode(type)
    }
}
