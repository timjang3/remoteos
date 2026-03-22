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

public enum CaptureTarget: Sendable, Equatable {
    case window(windowID: Int)
    case display(displayID: Int)
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
}

public struct WindowSnapshotPayload: Codable, Sendable, Equatable {
    public var window: WindowDescriptor
    public var capturedAt: String
    public var mimeType: String
    public var dataBase64: String
}

public struct SemanticDiffPayload: Codable, Sendable, Equatable {
    public var windowId: Int
    public var changedAt: String
    public var summary: String
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

    public init(
        id: String,
        action: AgentPromptResponseAction,
        answers: [String: AgentPromptAnswerPayload] = [:]
    ) {
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
}

public struct BrokerRegistration: Codable, Sendable, Equatable {
    public var device: DevicePayload
    public var deviceSecret: String
    public var wsUrl: String
}

public struct DevicePayload: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var mode: HostMode
    public var online: Bool
    public var registeredAt: String
    public var lastSeenAt: String?
}

public struct PairingSessionPayload: Codable, Sendable, Equatable {
    public var id: String
    public var deviceId: String
    public var pairingCode: String
    public var claimed: Bool
    public var expiresAt: String
    public var createdAt: String
    public var pairingUrl: String
}

public struct InputTapPayload: Codable, Sendable, Equatable {
    public var windowId: Int
    public var frameId: String
    public var normalizedX: Double
    public var normalizedY: Double
    public var clickCount: Int
}

public struct InputDragPayload: Codable, Sendable, Equatable {
    public var windowId: Int
    public var frameId: String
    public var fromX: Double
    public var fromY: Double
    public var toX: Double
    public var toY: Double
}

public struct InputScrollPayload: Codable, Sendable, Equatable {
    public var windowId: Int
    public var frameId: String
    public var deltaX: Double
    public var deltaY: Double
}

public struct InputKeyPayload: Codable, Sendable, Equatable {
    public var windowId: Int
    public var frameId: String
    public var text: String?
    public var key: String?
}

public struct WindowSelectionPayload: Codable, Sendable, Equatable {
    public var windowId: Int
}

public struct StreamStartPayload: Codable, Sendable, Equatable {
    public var windowId: Int
}

public struct StreamStopPayload: Codable, Sendable, Equatable {
    public var windowId: Int
}

public struct AgentTurnStartPayload: Codable, Sendable, Equatable {
    public var prompt: String
}

public struct AgentTurnStartResultPayload: Codable, Sendable, Equatable {
    public var turn: AgentTurnPayload
    public var userItem: AgentItemPayload
}

public struct AgentTurnCancelPayload: Codable, Sendable, Equatable {
    public var turnId: String
}

public struct SemanticSnapshotRequestPayload: Codable, Sendable, Equatable {
    public var windowId: Int
}

public struct JsonRpcRequest: @unchecked Sendable {
    public var id: String?
    public var method: String
    public var params: [String: Any]

    public init(id: String?, method: String, params: [String: Any]) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct DynamicToolInvocation: Sendable, Equatable {
    public var requestId: String
    public var threadId: String
    public var turnId: String
    public var callId: String
    public var tool: String

    public init(requestId: String, threadId: String, turnId: String, callId: String, tool: String) {
        self.requestId = requestId
        self.threadId = threadId
        self.turnId = turnId
        self.callId = callId
        self.tool = tool
    }
}

public struct CapturedFrame: Sendable, Equatable {
    public var windowId: Int
    public var frameId: String
    public var capturedAt: String
    public var mimeType: String
    public var dataBase64: String
    public var width: Int
    public var height: Int
    public var displayID: Int?
    public var sourceRectPoints: WindowBounds
    public var pointPixelScale: Double
    public var topologyVersion: Int

    public init(
        windowId: Int,
        frameId: String,
        capturedAt: String,
        mimeType: String,
        dataBase64: String,
        width: Int,
        height: Int,
        displayID: Int?,
        sourceRectPoints: WindowBounds,
        pointPixelScale: Double,
        topologyVersion: Int
    ) {
        self.windowId = windowId
        self.frameId = frameId
        self.capturedAt = capturedAt
        self.mimeType = mimeType
        self.dataBase64 = dataBase64
        self.width = width
        self.height = height
        self.displayID = displayID
        self.sourceRectPoints = sourceRectPoints
        self.pointPixelScale = pointPixelScale
        self.topologyVersion = topologyVersion
    }
}

public struct DynamicToolContentItem: Sendable, Equatable {
    public enum ItemType: Sendable, Equatable {
        case inputText(String)
        case inputImage(String)
    }

    public var type: ItemType

    public init(type: ItemType) {
        self.type = type
    }
}

public struct DynamicToolResult: Sendable, Equatable {
    public var contentItems: [DynamicToolContentItem]
    public var success: Bool

    public init(contentItems: [DynamicToolContentItem], success: Bool) {
        self.contentItems = contentItems
        self.success = success
    }
}
