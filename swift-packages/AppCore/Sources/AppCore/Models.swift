import Foundation
import RemoteOSCore

public typealias WindowCapability = RemoteOSCore.WindowCapability
public typealias PermissionStatus = RemoteOSCore.PermissionStatus
public typealias HostMode = RemoteOSCore.HostMode
public typealias ControlPlaneAuthMode = RemoteOSCore.ControlPlaneAuthMode
public typealias CodexRuntimeState = RemoteOSCore.CodexRuntimeState
public typealias AgentTurnStatus = RemoteOSCore.AgentTurnStatus
public typealias AgentItemKind = RemoteOSCore.AgentItemKind
public typealias AgentItemStatus = RemoteOSCore.AgentItemStatus
public typealias AgentPromptSource = RemoteOSCore.AgentPromptSource
public typealias AgentPromptKind = RemoteOSCore.AgentPromptKind
public typealias AgentPromptResponseAction = RemoteOSCore.AgentPromptResponseAction
public typealias AgentPromptResolutionStatus = RemoteOSCore.AgentPromptResolutionStatus
public typealias DeviceEnrollmentStatus = RemoteOSCore.DeviceEnrollmentStatus
public typealias StreamProfile = RemoteOSCore.StreamProfile
public typealias WindowBounds = RemoteOSCore.WindowBounds
public typealias WindowDescriptor = RemoteOSCore.WindowDescriptor
public typealias SemanticElement = RemoteOSCore.SemanticElement
public typealias SemanticSnapshot = RemoteOSCore.SemanticSnapshot
public typealias WindowFramePayload = RemoteOSCore.WindowFramePayload
public typealias WindowSnapshotPayload = RemoteOSCore.WindowSnapshotPayload
public typealias SemanticDiffPayload = RemoteOSCore.SemanticDiffPayload
public typealias CodexStatusPayload = RemoteOSCore.CodexStatusPayload
public typealias HostStatusPayload = RemoteOSCore.HostStatusPayload
public typealias AgentTurnPayload = RemoteOSCore.AgentTurnPayload
public typealias AgentItemPayload = RemoteOSCore.AgentItemPayload
public typealias AgentPromptOptionPayload = RemoteOSCore.AgentPromptOptionPayload
public typealias AgentPromptQuestionPayload = RemoteOSCore.AgentPromptQuestionPayload
public typealias AgentPromptChoicePayload = RemoteOSCore.AgentPromptChoicePayload
public typealias AgentPromptPayload = RemoteOSCore.AgentPromptPayload
public typealias AgentPromptAnswerPayload = RemoteOSCore.AgentPromptAnswerPayload
public typealias AgentPromptResponsePayload = RemoteOSCore.AgentPromptResponsePayload
public typealias AgentPromptResolvedPayload = RemoteOSCore.AgentPromptResolvedPayload
public typealias TraceEventPayload = RemoteOSCore.TraceEventPayload
public typealias DevicePayload = RemoteOSCore.DevicePayload
public typealias BrokerRegistration = RemoteOSCore.BrokerRegistration
public typealias PairingSessionPayload = RemoteOSCore.PairingSessionPayload
public typealias ControlPlaneHealthPayload = RemoteOSCore.ControlPlaneHealthPayload
public typealias DeviceEnrollmentPayload = RemoteOSCore.DeviceEnrollmentPayload
public typealias WebSocketTicketPayload = RemoteOSCore.WebSocketTicketPayload
public typealias BootstrapClientPayload = RemoteOSCore.BootstrapClientPayload
public typealias SpeechCapabilitiesPayload = RemoteOSCore.SpeechCapabilitiesPayload
public typealias BootstrapPayload = RemoteOSCore.BootstrapPayload
public typealias PairingClaimResponsePayload = RemoteOSCore.PairingClaimResponsePayload
public typealias SpeechTranscriptionPayload = RemoteOSCore.SpeechTranscriptionPayload
public typealias MobileAuthStartPayload = RemoteOSCore.MobileAuthStartPayload
public typealias MobileAuthExchangePayload = RemoteOSCore.MobileAuthExchangePayload
public typealias MobileAuthUserPayload = RemoteOSCore.MobileAuthUserPayload
public typealias StreamStartPayload = RemoteOSCore.StreamStartPayload
public typealias StreamStopPayload = RemoteOSCore.StreamStopPayload
public typealias WindowSelectionPayload = RemoteOSCore.WindowSelectionPayload
public typealias InputTapPayload = RemoteOSCore.InputTapPayload
public typealias InputDragPayload = RemoteOSCore.InputDragPayload
public typealias InputScrollPayload = RemoteOSCore.InputScrollPayload
public typealias InputKeyPayload = RemoteOSCore.InputKeyPayload
public typealias AgentTurnStartPayload = RemoteOSCore.AgentTurnStartPayload
public typealias AgentTurnStartResultPayload = RemoteOSCore.AgentTurnStartResultPayload
public typealias AgentStateGetResultPayload = RemoteOSCore.AgentStateGetResultPayload
public typealias AgentTurnCancelPayload = RemoteOSCore.AgentTurnCancelPayload
public typealias SemanticSnapshotRequestPayload = RemoteOSCore.SemanticSnapshotRequestPayload
public typealias WindowsListPayload = RemoteOSCore.WindowsListPayload

public enum CaptureTarget: Sendable, Equatable {
    case window(windowID: Int)
    case display(displayID: Int)
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
    public var contentRectPixels: WindowBounds?
    public var pointPixelScale: Double
    public var windowBoundsPoints: WindowBounds
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
        contentRectPixels: WindowBounds? = nil,
        pointPixelScale: Double,
        windowBoundsPoints: WindowBounds? = nil,
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
        self.contentRectPixels = contentRectPixels
        self.pointPixelScale = pointPixelScale
        self.windowBoundsPoints = windowBoundsPoints ?? sourceRectPoints
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
