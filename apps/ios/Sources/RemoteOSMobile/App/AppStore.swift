import Foundation
import Observation
import RemoteOSCore
import SwiftUI

struct ModelOption: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let description: String
}

struct PendingPromptBubble: Identifiable, Equatable, Sendable {
    let id: String
    let body: String
    let createdAt: String
}

enum ConnectionState: String, Sendable {
    case idle
    case bootstrapping
    case connecting
    case connected
    case error
}

enum DictationState: Sendable, Equatable {
    case idle
    case recording
    case transcribing
}

enum RemoteInputMode: String, CaseIterable, Identifiable, Sendable {
    case view
    case tap
    case scroll
    case drag
    case keyboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .view:
            return "View"
        case .tap:
            return "Tap"
        case .scroll:
            return "Scroll"
        case .drag:
            return "Drag"
        case .keyboard:
            return "Keyboard"
        }
    }
}

@MainActor
@Observable
final class PairingStore {
    var controlPlaneBaseURL = ""
    var pairingCode = ""
    var clientName = "iPhone"
    var health: ControlPlaneHealthPayload?
    var isCheckingHealth = false
    var isAuthenticating = false
    var isPairing = false
    var isScannerPresented = false
    var isAuthenticated = false
    var signedInEmail: String?
    var errorMessage: String?
}

@MainActor
@Observable
final class SessionStore {
    var connectionState: ConnectionState = .idle
    var windows: [WindowDescriptor] = []
    var selectedWindowID: Int?
    var currentFrame: DecodedFrame?
    var latestFrameID: String?
    var snapshots: [Int: Image] = [:]
    var semanticSnapshot: SemanticSnapshot?
    var semanticDiff: String?
    var hostStatus: HostStatusPayload?
    var codexStatus: CodexStatusPayload?
    var speechCapabilities: SpeechCapabilitiesPayload?
    var traceEvents: [TraceEventPayload] = []
    var errorMessage: String?
    var isWindowSheetPresented = false
    var isModelSheetPresented = false
    var isSettingsPresented = false
    var isTextEntryPresented = false
    var textEntryValue = ""
}

@MainActor
@Observable
final class AgentStore {
    var draftPrompt = ""
    var turn: AgentTurnPayload?
    var items: [AgentItemPayload] = []
    var prompts: [AgentPromptPayload] = []
    var pendingPrompt: PendingPromptBubble?
    var submittingPromptIDs: Set<String> = []
    var dictationState: DictationState = .idle
    var errorMessage: String?
}

@MainActor
@Observable
final class SettingsStore {
    var inputMode: RemoteInputMode = .tap
    var lowDataMode = false
}

@MainActor
@Observable
final class RemoteOSAppStore {
    static let availableModels: [ModelOption] = [
        ModelOption(id: "gpt-5.4", name: "GPT-5.4", description: "Most capable"),
        ModelOption(id: "gpt-5.4-mini", name: "GPT-5.4 Mini", description: "Fast and capable"),
        ModelOption(id: "gpt-5.3-codex", name: "Codex 5.3", description: "Coding optimized"),
        ModelOption(id: "gpt-5.3-codex-spark", name: "Codex Spark", description: "Quick coding"),
        ModelOption(id: "gpt-5.2-codex", name: "Codex 5.2", description: "Coding optimized"),
        ModelOption(id: "gpt-5.2", name: "GPT-5.2", description: "General purpose"),
        ModelOption(id: "gpt-5.1-codex-max", name: "Codex Max", description: "Extended thinking"),
        ModelOption(id: "gpt-5.1-codex-mini", name: "Codex Mini", description: "Lightweight")
    ]

    let pairing = PairingStore()
    let session = SessionStore()
    let agent = AgentStore()
    let settings = SettingsStore()
    let network = NetworkPathService()

    private let controlPlaneService: ControlPlaneService
    private let brokerService: BrokerSessionService
    private let framePipeline: FramePipeline
    private let authCoordinator: MobileAuthCoordinator
    private let dictationRecorder: DictationRecorder

    private var connectedBaseURL: String?
    private var clientToken: String?

    init(
        controlPlaneService: ControlPlaneService = ControlPlaneService(),
        brokerService: BrokerSessionService = BrokerSessionService(),
        framePipeline: FramePipeline = FramePipeline(),
        authCoordinator: MobileAuthCoordinator = MobileAuthCoordinator(),
        dictationRecorder: DictationRecorder = DictationRecorder()
    ) {
        self.controlPlaneService = controlPlaneService
        self.brokerService = brokerService
        self.framePipeline = framePipeline
        self.authCoordinator = authCoordinator
        self.dictationRecorder = dictationRecorder

        Task {
            await brokerService.setEventHandler { [weak self] event in
                await self?.handleBrokerEvent(event)
            }
            await restoreSession()
        }
    }

    var hasPersistedClientSession: Bool {
        clientToken != nil
    }

    var selectedWindow: WindowDescriptor? {
        session.windows.first(where: { $0.id == session.selectedWindowID })
    }

    var selectedSnapshot: Image? {
        guard let selectedWindowID = session.selectedWindowID else {
            return nil
        }
        return session.snapshots[selectedWindowID]
    }

    var selectedPreviewImage: Image? {
        if let currentFrame = session.currentFrame {
            return Image(uiImage: currentFrame.image)
        }
        return selectedSnapshot
    }

    var currentStreamProfile: StreamProfile {
        if settings.lowDataMode {
            return .lowData
        }
        return network.recommendedProfile
    }

    var requiresAuthentication: Bool {
        pairing.health?.authMode == .required
    }

    var canPair: Bool {
        pairing.controlPlaneBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && pairing.pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && pairing.isPairing == false
            && (requiresAuthentication == false || pairing.isAuthenticated)
    }

    var isAgentReady: Bool {
        session.connectionState == .connected
            && session.hostStatus?.online != false
            && (session.codexStatus?.state == .ready || session.codexStatus?.state == .running)
    }

    func restoreSession() async {
        let stored = await controlPlaneService.loadStoredSession()
        pairing.clientName = stored.clientName
        pairing.controlPlaneBaseURL = stored.controlPlaneBaseURL ?? ""
        pairing.isAuthenticated = stored.authToken != nil
        connectedBaseURL = stored.controlPlaneBaseURL
        clientToken = stored.clientToken

        if pairing.controlPlaneBaseURL.isEmpty == false {
            await refreshHealth()
        }
        guard let connectedBaseURL, let clientToken else {
            return
        }

        do {
            try await connect(baseURL: connectedBaseURL, clientToken: clientToken)
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    func refreshHealth() async {
        let baseURL = normalizedBaseURL(pairing.controlPlaneBaseURL)
        guard let baseURL else {
            pairing.health = nil
            pairing.errorMessage = nil
            return
        }

        pairing.isCheckingHealth = true
        defer { pairing.isCheckingHealth = false }

        do {
            let health = try await controlPlaneService.getHealth(baseURL: baseURL)
            pairing.health = health
            pairing.errorMessage = nil
            pairing.controlPlaneBaseURL = baseURL
            await controlPlaneService.saveControlPlaneBaseURL(baseURL)
            pairing.isAuthenticated = pairing.isAuthenticated && health.authMode == .required
        } catch {
            pairing.errorMessage = error.localizedDescription
        }
    }

    func applyScannedPairingLink(_ rawValue: String) async {
        do {
            let payload = try PairingLinkParser.parse(rawValue)
            pairing.controlPlaneBaseURL = payload.controlPlaneBaseURL
            pairing.pairingCode = payload.pairingCode
            pairing.errorMessage = nil
            pairing.isScannerPresented = false
            await refreshHealth()
        } catch {
            pairing.errorMessage = error.localizedDescription
        }
    }

    func signIn() async {
        guard let baseURL = normalizedBaseURL(pairing.controlPlaneBaseURL) else {
            pairing.errorMessage = "Enter a control plane URL before signing in."
            return
        }

        pairing.isAuthenticating = true
        pairing.errorMessage = nil
        defer { pairing.isAuthenticating = false }

        do {
            let startURL = try await controlPlaneService.mobileAuthStartURL(
                baseURL: baseURL,
                redirectURI: "remoteos://auth"
            )
            let callbackURL = try await authCoordinator.authenticate(
                startURL: startURL,
                callbackScheme: "remoteos"
            )

            let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
            let queryItems: [String: String] = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).compactMap { item in
                guard let value = item.value else {
                    return nil
                }
                return (item.name, value)
            })

            if let errorMessage = queryItems["error_description"] ?? queryItems["error"] {
                throw AppCoreError.invalidPayload(errorMessage)
            }
            guard let code = queryItems["code"], code.isEmpty == false else {
                throw AppCoreError.invalidPayload("Missing authentication code")
            }

            let exchange = try await controlPlaneService.exchangeMobileAuth(baseURL: baseURL, code: code)
            await controlPlaneService.saveAuthToken(exchange.authToken)
            pairing.isAuthenticated = true
            pairing.signedInEmail = exchange.user.email
            await refreshHealth()
        } catch {
            pairing.errorMessage = error.localizedDescription
        }
    }

    func pair() async {
        let baseURL = normalizedBaseURL(pairing.controlPlaneBaseURL)
        let pairingCode = pairing.pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let clientName = pairing.clientName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let baseURL, pairingCode.isEmpty == false else {
            pairing.errorMessage = "Enter a control plane URL and pairing code."
            return
        }

        if pairing.health == nil || normalizedBaseURL(pairing.controlPlaneBaseURL) != connectedBaseURL {
            await refreshHealth()
        }
        if requiresAuthentication && pairing.isAuthenticated == false {
            pairing.errorMessage = "Sign in to this control plane before pairing."
            return
        }

        pairing.isPairing = true
        pairing.errorMessage = nil
        defer { pairing.isPairing = false }

        do {
            let response = try await controlPlaneService.claimPairing(
                baseURL: baseURL,
                pairingCode: pairingCode,
                clientName: clientName.isEmpty ? "iPhone" : clientName
            )

            await controlPlaneService.saveControlPlaneBaseURL(baseURL)
            await controlPlaneService.saveClientName(clientName.isEmpty ? "iPhone" : clientName)
            await controlPlaneService.saveClientToken(response.clientToken)

            connectedBaseURL = baseURL
            clientToken = response.clientToken
            try await connect(baseURL: baseURL, clientToken: response.clientToken)
        } catch {
            pairing.errorMessage = error.localizedDescription
        }
    }

    func disconnect(clearAuthToken: Bool = false) async {
        agent.draftPrompt = ""
        agent.pendingPrompt = nil
        agent.turn = nil
        agent.items = []
        agent.prompts = []
        agent.submittingPromptIDs = []
        agent.errorMessage = nil
        agent.dictationState = .idle

        session.connectionState = .idle
        session.windows = []
        session.selectedWindowID = nil
        session.currentFrame = nil
        session.latestFrameID = nil
        session.snapshots = [:]
        session.semanticSnapshot = nil
        session.semanticDiff = nil
        session.hostStatus = nil
        session.codexStatus = nil
        session.speechCapabilities = nil
        session.traceEvents = []
        session.errorMessage = nil
        session.isWindowSheetPresented = false
        session.isModelSheetPresented = false
        session.isSettingsPresented = false
        session.isTextEntryPresented = false
        session.textEntryValue = ""

        dictationRecorder.cancel()
        await brokerService.disconnect()
        await controlPlaneService.clearClientToken()
        if clearAuthToken {
            await controlPlaneService.saveAuthToken(nil)
            pairing.isAuthenticated = false
            pairing.signedInEmail = nil
        }
        clientToken = nil
    }

    func handleScenePhase(_ phase: ScenePhase) async {
        guard let selectedWindowID = session.selectedWindowID else {
            return
        }

        switch phase {
        case .background:
            try? await brokerService.stopStream(windowID: selectedWindowID)
        case .active:
            if session.connectionState == .connected {
                try? await brokerService.startStream(windowID: selectedWindowID, profile: currentStreamProfile)
            }
        default:
            break
        }
    }

    func selectWindow(_ window: WindowDescriptor) async {
        do {
            try await brokerService.selectWindow(window.id)
            session.selectedWindowID = window.id
            session.currentFrame = nil
            session.semanticDiff = nil
            session.semanticSnapshot = nil
            session.isWindowSheetPresented = false
            clearAgentConversation()
            try await brokerService.resetAgentThread()
            try await brokerService.startStream(windowID: window.id, profile: currentStreamProfile)
            session.semanticSnapshot = try? await brokerService.semanticSnapshot(windowID: window.id)
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    func deselectWindow() async {
        guard let selectedWindowID = session.selectedWindowID else {
            return
        }

        session.selectedWindowID = nil
        session.currentFrame = nil
        session.semanticSnapshot = nil
        session.semanticDiff = nil
        try? await brokerService.stopStream(windowID: selectedWindowID)
    }

    func sendPrompt() async {
        let prompt = agent.draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard prompt.isEmpty == false else {
            return
        }
        guard isAgentReady else {
            agent.errorMessage = "The selected Mac session is still connecting."
            return
        }

        agent.errorMessage = nil
        agent.pendingPrompt = PendingPromptBubble(
            id: UUID().uuidString,
            body: prompt,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
        agent.draftPrompt = ""

        do {
            let result = try await brokerService.startAgent(prompt: prompt)
            agent.pendingPrompt = nil
            agent.turn = result.turn
            upsertAgentItem(result.userItem)
        } catch {
            agent.pendingPrompt = nil
            agent.draftPrompt = prompt
            agent.errorMessage = error.localizedDescription
        }
    }

    func cancelActiveTurn() async {
        guard let turn = agent.turn, turn.status == .running else {
            return
        }

        do {
            try await brokerService.cancelAgent(turnID: turn.id)
        } catch {
            agent.errorMessage = error.localizedDescription
        }
    }

    func resetThread() async {
        clearAgentConversation()
        do {
            try await brokerService.resetAgentThread()
        } catch {
            agent.errorMessage = error.localizedDescription
        }
    }

    func respondToPrompt(
        promptID: String,
        action: AgentPromptResponseAction,
        answers: [String: AgentPromptAnswerPayload] = [:]
    ) async {
        agent.submittingPromptIDs.insert(promptID)

        do {
            try await brokerService.respondToPrompt(
                AgentPromptResponsePayload(id: promptID, action: action, answers: answers)
            )
        } catch {
            agent.submittingPromptIDs.remove(promptID)
            agent.errorMessage = error.localizedDescription
        }
    }

    func selectModel(_ modelID: String) async {
        session.isModelSheetPresented = false
        do {
            try await brokerService.setAgentModel(modelID)
        } catch {
            agent.errorMessage = error.localizedDescription
        }
    }

    func toggleDictation() async {
        guard session.speechCapabilities?.transcriptionAvailable == true else {
            return
        }

        switch agent.dictationState {
        case .idle:
            do {
                try await dictationRecorder.start()
                agent.dictationState = .recording
                agent.errorMessage = nil
            } catch {
                agent.errorMessage = error.localizedDescription
            }
        case .recording:
            await finishDictation()
        case .transcribing:
            break
        }
    }

    func submitTextEntry() async {
        let text = session.textEntryValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else {
            return
        }

        do {
            try await sendKeyInput(text: text, key: nil)
            session.textEntryValue = ""
            session.isTextEntryPresented = false
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    func sendSpecialKey(_ key: String) async {
        do {
            try await sendKeyInput(text: nil, key: key)
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    func handleTap(normalizedX: Double, normalizedY: Double, clickCount: Int) async {
        guard let currentFrame = session.currentFrame else {
            return
        }

        do {
            try await brokerService.tap(
                InputTapPayload(
                    windowId: currentFrame.payload.windowId,
                    frameId: currentFrame.payload.frameId,
                    normalizedX: normalizedX,
                    normalizedY: normalizedY,
                    clickCount: clickCount
                )
            )
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    func handleDrag(from: CGPoint, to: CGPoint) async {
        guard let currentFrame = session.currentFrame else {
            return
        }

        do {
            try await brokerService.drag(
                InputDragPayload(
                    windowId: currentFrame.payload.windowId,
                    frameId: currentFrame.payload.frameId,
                    fromX: from.x,
                    fromY: from.y,
                    toX: to.x,
                    toY: to.y
                )
            )
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    func handleScroll(deltaX: Double, deltaY: Double) async {
        guard let currentFrame = session.currentFrame else {
            return
        }

        do {
            try await brokerService.scroll(
                InputScrollPayload(
                    windowId: currentFrame.payload.windowId,
                    frameId: currentFrame.payload.frameId,
                    deltaX: deltaX,
                    deltaY: deltaY
                )
            )
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    private func connect(baseURL: String, clientToken: String) async throws {
        session.connectionState = .bootstrapping
        let health = try await controlPlaneService.getHealth(baseURL: baseURL)
        pairing.health = health
        let bootstrap = try await controlPlaneService.bootstrap(baseURL: baseURL, clientToken: clientToken)
        let wsURL = try await controlPlaneService.webSocketURL(
            baseURL: baseURL,
            bootstrap: bootstrap,
            authMode: health.authMode,
            clientToken: clientToken
        )

        connectedBaseURL = baseURL
        self.clientToken = clientToken
        applyBootstrap(bootstrap)
        session.connectionState = .connecting
        try await brokerService.connect(to: wsURL)
        session.connectionState = .connected
        session.windows = (try? await brokerService.listWindows()) ?? bootstrap.windows

        if let selectedWindowID = session.selectedWindowID {
            try? await brokerService.startStream(windowID: selectedWindowID, profile: currentStreamProfile)
            session.semanticSnapshot = try? await brokerService.semanticSnapshot(windowID: selectedWindowID)
        }
        if let restoredAgentState = try? await brokerService.agentState() {
            agent.turn = restoredAgentState.turn
            agent.items = restoredAgentState.items
            agent.prompts = restoredAgentState.prompts
            agent.pendingPrompt = nil
            agent.submittingPromptIDs = []
        }
    }

    private func applyBootstrap(_ bootstrap: BootstrapPayload) {
        session.windows = bootstrap.windows
        session.selectedWindowID = bootstrap.status.selectedWindowId
        session.hostStatus = bootstrap.status
        session.codexStatus = bootstrap.status.codex
        session.speechCapabilities = bootstrap.speech
        session.errorMessage = nil
        pairing.errorMessage = nil
    }

    private func clearAgentConversation() {
        agent.turn = nil
        agent.items = []
        agent.prompts = []
        agent.pendingPrompt = nil
        agent.submittingPromptIDs = []
        agent.errorMessage = nil
    }

    private func upsertAgentItem(_ item: AgentItemPayload) {
        if let index = agent.items.firstIndex(where: { $0.id == item.id }) {
            agent.items[index] = item
        } else {
            agent.items.append(item)
            agent.items.sort { $0.createdAt < $1.createdAt }
        }
    }

    private func upsertPrompt(_ prompt: AgentPromptPayload) {
        if let index = agent.prompts.firstIndex(where: { $0.id == prompt.id }) {
            agent.prompts[index] = prompt
        } else {
            agent.prompts.append(prompt)
            agent.prompts.sort { $0.createdAt < $1.createdAt }
        }
    }

    private func handleBrokerEvent(_ event: BrokerSessionEvent) async {
        switch event {
        case let .disconnected(message):
            session.connectionState = .idle
            session.errorMessage = message
        case let .notification(notification):
            switch notification {
            case let .windowsUpdated(payload):
                session.windows = payload.windows
            case let .windowSnapshot(payload):
                if let decodedSnapshot = await framePipeline.decodeSnapshot(payload) {
                    session.snapshots[payload.window.id] = Image(uiImage: decodedSnapshot.image)
                }
            case let .windowFrame(payload):
                session.latestFrameID = payload.frameId
                if let decodedFrame = await framePipeline.decodeFrame(payload),
                   session.latestFrameID == payload.frameId {
                    session.currentFrame = decodedFrame
                }
            case let .semanticDiff(payload):
                session.semanticDiff = payload.summary
            case let .agentTurn(payload):
                agent.turn = payload
                if payload.status != .running {
                    agent.pendingPrompt = nil
                }
            case let .agentItem(payload):
                if payload.kind == .userMessage {
                    agent.pendingPrompt = nil
                }
                upsertAgentItem(payload)
            case let .agentPromptRequested(payload):
                upsertPrompt(payload)
            case let .agentPromptResolved(payload):
                agent.prompts.removeAll { $0.id == payload.id }
                agent.submittingPromptIDs.remove(payload.id)
            case let .traceEvent(payload):
                session.traceEvents.insert(payload, at: 0)
                session.traceEvents = Array(session.traceEvents.prefix(24))
            case let .hostStatus(payload):
                session.hostStatus = payload
                session.codexStatus = payload.codex
                if session.isWindowSheetPresented == false {
                    session.selectedWindowID = payload.selectedWindowId
                }
            case let .codexStatus(payload):
                session.codexStatus = payload
            }
        }
    }

    private func finishDictation() async {
        guard let baseURL = connectedBaseURL, let clientToken else {
            agent.errorMessage = "This client session is no longer active."
            agent.dictationState = .idle
            dictationRecorder.cancel()
            return
        }

        agent.dictationState = .transcribing

        do {
            let recorded = try await dictationRecorder.stop()
            let transcript = try await controlPlaneService.createSpeechTranscription(
                baseURL: baseURL,
                clientToken: clientToken,
                audioData: recorded.data,
                filename: recorded.filename,
                mimeType: recorded.mimeType,
                language: Locale.current.language.languageCode?.identifier,
                durationMs: recorded.durationMs
            )

            if agent.draftPrompt.isEmpty {
                agent.draftPrompt = transcript.text
            } else {
                agent.draftPrompt += agent.draftPrompt.hasSuffix(" ") ? transcript.text : " \(transcript.text)"
            }
            agent.dictationState = .idle
        } catch {
            agent.dictationState = .idle
            agent.errorMessage = error.localizedDescription
        }
    }

    private func sendKeyInput(text: String?, key: String?) async throws {
        guard let currentFrame = session.currentFrame else {
            throw AppCoreError.invalidPayload("Wait for the live stream before sending keyboard input.")
        }

        try await brokerService.key(
            InputKeyPayload(
                windowId: currentFrame.payload.windowId,
                frameId: currentFrame.payload.frameId,
                text: text,
                key: key
            )
        )
    }

    private func normalizedBaseURL(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.isEmpty == false else {
            return nil
        }
        return trimmed.replacingOccurrences(of: "/$", with: "", options: .regularExpression)
    }
}
