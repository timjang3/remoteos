import AppKit
import Combine
import Foundation

private struct DeckSnapshotFailureState {
    var message: String
    var lastLoggedAt: Date
}

public enum OpenAIAPIKeyStorageSource: String, Sendable {
    case none
    case saved
}

@MainActor
public final class HostRuntime: ObservableObject {
    @Published public private(set) var configuration: HostConfiguration
    @Published public private(set) var permissions: PermissionSnapshot
    @Published public private(set) var windows: [WindowDescriptor] = []
    @Published public private(set) var selectedWindowID: Int?
    @Published public private(set) var pairingSession: PairingSessionPayload?
    @Published public private(set) var traces: [TraceEventPayload] = []
    @Published public private(set) var agentTurn: AgentTurnPayload?
    @Published public private(set) var agentItems: [AgentItemPayload] = []
    @Published public private(set) var agentPrompts: [AgentPromptPayload] = []
    @Published public private(set) var hostStatus: HostStatusPayload
    @Published public private(set) var controlPlaneAuthMode: ControlPlaneAuthMode?
    @Published public private(set) var pendingEnrollment: DeviceEnrollmentPayload?
    @Published public private(set) var lastConnectionError: String?
    @Published public private(set) var openAIAPIKeyConfigured = false
    @Published public private(set) var openAIAPIKeyStorageSource: OpenAIAPIKeyStorageSource = .none

    private let configurationStore: ConfigurationStore
    private let keychainTokenStore: KeychainTokenStore
    private let openAIAPIKeyStore: OpenAIAPIKeyStore
    private let permissionCoordinator: PermissionCoordinator
    private let inventoryService: WindowInventoryService
    private let screenshotService: ScreenshotService
    private let windowStreamService: WindowStreamService
    private let accessibilityService: AccessibilityService
    private let textRecognitionService: TextRecognitionService
    private let inputInjector: InputEventInjector
    private let auditStore: AuditStore
    private let brokerClient: BrokerClient
    private let urlSession: URLSession
    private let computerUseService: OpenAIComputerUseService
    private let codexClient: CodexAppServerClient
    private let log = AppLogs.hostRuntime

    private var refreshTask: Task<Void, Never>?
    private var brokerReconnectTask: Task<Void, Never>?
    private var registrationTask: Task<BrokerRegistration, Error>?
    private var enrollmentPollingTask: Task<Void, Never>?
    private var lastOpenedEnrollmentToken: String?
    private var semanticSummaryByWindow: [Int: String] = [:]
    private var latestFrameByWindowID: [Int: CapturedFrame] = [:]
    /// Frames captured by explicit tool calls (select, capture, focus), keyed
    /// by frameId.  Unlike `latestFrameByWindowID` these are NOT overwritten by
    /// the continuous frame stream, so callers can reference them reliably.
    private var toolCapturedFrames: [String: CapturedFrame] = [:]
    private var displayTopologyVersion = 0
    private var displayObserver: DisplayTopologyObserver?
    private var shouldMaintainBrokerConnection = false
    private let codexBrokerFanoutQueue = SerialAsyncCallbackQueue()
    private let codexTraceFanoutQueue = SerialAsyncCallbackQueue()
    private var pendingPromptResponses: [String: CheckedContinuation<AgentPromptResponsePayload?, Never>] = [:]
    private var pendingPromptTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var pendingPromptsAwaitingResolution: Set<String> = []
    private var deckSnapshotFailures: [Int: DeckSnapshotFailureState] = [:]
    private var pendingStreamFramePayload: WindowFramePayload?
    private var streamFramePublishTask: Task<Void, Never>?

    public init(
        configurationStore: ConfigurationStore = ConfigurationStore(),
        keychainTokenStore: KeychainTokenStore = KeychainTokenStore(),
        openAIAPIKeyStore: OpenAIAPIKeyStore = OpenAIAPIKeyStore(),
        permissionCoordinator: PermissionCoordinator = PermissionCoordinator(),
        screenshotService: ScreenshotService = ScreenshotService(),
        windowStreamService: WindowStreamService = WindowStreamService(),
        accessibilityService: AccessibilityService = AccessibilityService(),
        textRecognitionService: TextRecognitionService = TextRecognitionService(),
        inputInjector: InputEventInjector = InputEventInjector(),
        brokerClient: BrokerClient = BrokerClient(),
        urlSession: URLSession = .shared
    ) throws {
        var configuration = configurationStore.load()
        configuration.deviceSecret = keychainTokenStore.load(.deviceSecret)
        self.configurationStore = configurationStore
        self.keychainTokenStore = keychainTokenStore
        self.openAIAPIKeyStore = openAIAPIKeyStore
        self.permissionCoordinator = permissionCoordinator
        self.inventoryService = WindowInventoryService(permissionCoordinator: permissionCoordinator)
        self.screenshotService = screenshotService
        self.windowStreamService = windowStreamService
        self.accessibilityService = accessibilityService
        self.textRecognitionService = textRecognitionService
        self.inputInjector = inputInjector
        self.brokerClient = brokerClient
        self.urlSession = urlSession
        self.computerUseService = OpenAIComputerUseService(urlSession: urlSession)
        self.auditStore = try AuditStore()
        self.configuration = configuration
        self.permissions = permissionCoordinator.snapshot()
        let initialCodexStatus = CodexStatusPayload(
            state: .unknown,
            installed: false,
            authenticated: false,
            authMode: nil,
            model: configuration.codexModel,
            threadId: nil,
            activeTurnId: nil,
            lastError: nil
        )
        self.hostStatus = HostStatusPayload(
            deviceId: configuration.deviceID ?? "unregistered",
            online: false,
            selectedWindowId: nil,
            screenRecording: permissionCoordinator.snapshot().screenRecording,
            accessibility: permissionCoordinator.snapshot().accessibility,
            directUrl: configuration.hostMode == .direct ? configuration.controlPlaneBaseURL : nil,
            codex: initialCodexStatus
        )
        self.codexClient = CodexAppServerClient(
            configurationProvider: { [configurationStore] in configurationStore.load() },
            toolSpecsProvider: { Self.remoteToolSpecs() },
            developerInstructionsProvider: { Self.codexDeveloperInstructions() }
        )
        refreshOpenAIAPIKeyState()

        brokerClient.onRequest = { [weak self] request in
            await self?.handle(request: request)
        }
        brokerClient.onDisconnected = { [weak self] in
            await MainActor.run {
                guard let self else {
                    return
                }
                self.hostStatus.online = false
                self.pairingSession = nil
                self.scheduleBrokerReconnect(after: .seconds(1))
            }
        }

        codexClient.callbacks.onCodexStatus = { [weak self] status in
            await MainActor.run {
                self?.handleCodexStatusCallback(status)
            }
        }
        codexClient.callbacks.onTurn = { [weak self] turn in
            await MainActor.run {
                self?.handleCodexTurnCallback(turn)
            }
        }
        codexClient.callbacks.onItem = { [weak self] item in
            await MainActor.run {
                self?.handleCodexItemCallback(item)
            }
        }
        codexClient.callbacks.onTrace = { [weak self] event in
            await MainActor.run {
                self?.handleCodexTraceCallback(event)
            }
        }
        codexClient.callbacks.onThreadIDChanged = { [weak self] threadID in
            await MainActor.run {
                self?.handleCodexThreadIDCallback(threadID)
            }
        }
        codexClient.callbacks.onPromptResolved = { [weak self] promptID in
            await MainActor.run {
                self?.resolveAgentPrompt(id: promptID, status: .submitted)
            }
        }
        codexClient.callbacks.promptHandler = { [weak self] prompt in
            guard let self else {
                return nil
            }
            return await Task { @MainActor in
                await self.presentPrompt(prompt, timeout: .seconds(120), awaitsExplicitResolution: true)
            }.value
        }
        codexClient.callbacks.toolHandler = { [weak self] invocation, argumentData in
            guard let self else {
                return DynamicToolResult(contentItems: [.init(type: .inputText("RemoteOS is unavailable."))], success: false)
            }
            return try await Task { @MainActor in
                let clock = ContinuousClock()
                let startedAt = clock.now
                let arguments = try anyDictionary(from: argumentData)
                self.log.notice(
                    "RemoteOS tool started tool=\(invocation.tool) requestId=\(invocation.requestId) turnId=\(invocation.turnId) selectedWindowId=\(self.selectedWindowID.map(String.init) ?? "nil")"
                )
                await self.recordTrace(
                    level: "info",
                    kind: "remote_tool",
                    message: "Started \(invocation.tool) requestId=\(invocation.requestId) selectedWindowId=\(self.selectedWindowID.map(String.init) ?? "nil")"
                )

                do {
                    let result = try await self.executeDynamicTool(invocation: invocation, named: invocation.tool, arguments: arguments)
                    self.log.notice(
                        "RemoteOS tool finished tool=\(invocation.tool) requestId=\(invocation.requestId) success=\(result.success) elapsed=\(logDuration(startedAt.duration(to: clock.now)))"
                    )
                    await self.recordTrace(
                        level: result.success ? "info" : "warning",
                        kind: "remote_tool",
                        message: "Finished \(invocation.tool) requestId=\(invocation.requestId) success=\(result.success) elapsed=\(logDuration(startedAt.duration(to: clock.now)))"
                    )
                    return result
                } catch {
                    self.log.error(
                        "RemoteOS tool failed tool=\(invocation.tool) requestId=\(invocation.requestId) elapsed=\(logDuration(startedAt.duration(to: clock.now))) error=\(error.localizedDescription)"
                    )
                    await self.recordTrace(
                        level: "error",
                        kind: "remote_tool",
                        message: "Failed \(invocation.tool) requestId=\(invocation.requestId) elapsed=\(logDuration(startedAt.duration(to: clock.now))) error=\(error.localizedDescription)"
                    )
                    throw error
                }
            }.value
        }

        displayObserver = DisplayTopologyObserver { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.displayTopologyVersion += 1
                self.invalidateFrames(reason: "Display topology changed.")
                if let selectedWindowID = self.selectedWindowID {
                    do {
                        try await self.startFrameStream(for: selectedWindowID)
                    } catch {
                        await self.recordTrace(level: "warning", kind: "frame_stream", message: error.localizedDescription)
                    }
                }
            }
        }

        windowStreamService.onFrame = { [weak self] frame in
            guard let self else { return }
            await MainActor.run {
                self.enqueueStreamFrame(frame)
            }
        }
        windowStreamService.onError = { [weak self] error in
            guard let self else { return }
            await MainActor.run {
                self.invalidateFrames(reason: error.localizedDescription)
            }
            await self.recordTrace(level: "warning", kind: "frame_stream", message: error.localizedDescription)
        }
    }

    public func start() {
        log.notice("Starting host runtime mode=\(configuration.hostMode.rawValue) deviceId=\(configuration.deviceID ?? "unregistered") model=\(configuration.codexModel)")
        shouldMaintainBrokerConnection = true
        permissions = permissionCoordinator.snapshot()
        hostStatus.screenRecording = permissions.screenRecording
        hostStatus.accessibility = permissions.accessibility
        lastConnectionError = nil

        Task {
            self.log.info("Beginning Codex warm-up")
            _ = await codexClient.prepareForTurns(forceStatusRefresh: true)
            self.log.info("Finished Codex warm-up")
        }
        Task {
            try? await refreshControlPlaneAuthMode()
        }
        log.info("Starting window inventory refresh loop.")

        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                if self.permissions.screenRecording == .granted || !self.windows.isEmpty || self.selectedWindowID != nil {
                    await self.refreshWindowsNow()
                    await self.publishDeckSnapshots()
                    await self.publishSemanticDiffIfNeeded()
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }

        scheduleBrokerReconnect(after: .zero)
    }

    public func stop() {
        log.notice("Stopping host runtime")
        shouldMaintainBrokerConnection = false
        refreshTask?.cancel()
        brokerReconnectTask?.cancel()
        brokerReconnectTask = nil
        enrollmentPollingTask?.cancel()
        enrollmentPollingTask = nil
        clearAllPrompts(status: .interrupted)
        brokerClient.disconnect()
        Task {
            try? await windowStreamService.stop()
        }
        Task {
            await codexClient.stop()
        }
        hostStatus.online = false
    }

    public func updateConfiguration(baseURL: String, mode: HostMode, deviceName: String, codexModel: String) {
        log.info("Updating host configuration mode=\(mode.rawValue) deviceName=\(deviceName) model=\(codexModel)")
        let didChangeConnectionTarget =
            configuration.controlPlaneBaseURL != baseURL || configuration.hostMode != mode
        configuration.controlPlaneBaseURL = baseURL
        configuration.hostMode = mode
        configuration.deviceName = deviceName
        configuration.codexModel = codexModel.isEmpty ? "gpt-5.4-mini" : codexModel
        if didChangeConnectionTarget {
            clearStoredDeviceRegistration(
                logMessage: "Clearing saved device registration after connection settings changed"
            )
        } else {
            persistConfiguration()
        }
        hostStatus.directUrl = mode == .direct ? baseURL : nil
        controlPlaneAuthMode = nil
        pendingEnrollment = nil
        enrollmentPollingTask?.cancel()
        enrollmentPollingTask = nil
        lastOpenedEnrollmentToken = nil
        if didChangeConnectionTarget, shouldMaintainBrokerConnection {
            scheduleBrokerReconnect(after: .zero)
        }

        Task {
            _ = await codexClient.prepareForTurns(forceStatusRefresh: true)
        }
        Task {
            try? await refreshControlPlaneAuthMode()
        }
    }

    public func resetConnectionConfigurationToDefaults() {
        log.notice("Resetting connection settings to app defaults")
        configurationStore.resetConnectionOverrides()
        let defaultConfiguration = configurationStore.load()
        let didChangeConnectionTarget =
            configuration.controlPlaneBaseURL != defaultConfiguration.controlPlaneBaseURL
            || configuration.hostMode != defaultConfiguration.hostMode

        configuration.controlPlaneBaseURL = defaultConfiguration.controlPlaneBaseURL
        configuration.hostMode = defaultConfiguration.hostMode

        if didChangeConnectionTarget {
            clearStoredDeviceRegistration(
                logMessage: "Clearing saved device registration after resetting connection settings to app defaults"
            )
        } else {
            persistConfiguration()
        }

        hostStatus.directUrl =
            configuration.hostMode == .direct ? configuration.controlPlaneBaseURL : nil
        controlPlaneAuthMode = nil
        pendingEnrollment = nil
        enrollmentPollingTask?.cancel()
        enrollmentPollingTask = nil
        lastOpenedEnrollmentToken = nil
        if didChangeConnectionTarget, shouldMaintainBrokerConnection {
            scheduleBrokerReconnect(after: .zero)
        }

        Task {
            try? await refreshControlPlaneAuthMode()
        }
    }

    public func currentOpenAIAPIKey() -> String {
        openAIAPIKeyStore.load() ?? ""
    }

    public func updateOpenAIAPIKey(_ apiKey: String) {
        openAIAPIKeyStore.save(apiKey)
        refreshOpenAIAPIKeyState()
    }

    public func clearOpenAIAPIKey() {
        openAIAPIKeyStore.save(nil)
        refreshOpenAIAPIKeyState()
    }

    public func requestScreenRecordingPermission() {
        _ = permissionCoordinator.requestScreenRecording()
        permissions = permissionCoordinator.snapshot()
        hostStatus.screenRecording = permissions.screenRecording
    }

    public func requestAccessibilityPermission() {
        _ = permissionCoordinator.requestAccessibility()
        permissions = permissionCoordinator.snapshot()
        hostStatus.accessibility = permissions.accessibility
    }

    public func refreshWindows() {
        Task {
            await refreshWindowsNow()
        }
    }

    public func openPendingEnrollmentInBrowser() {
        guard
            let pendingEnrollment,
            let url = URL(string: pendingEnrollment.enrollmentUrl)
        else {
            return
        }

        NSWorkspace.shared.open(url)
        lastOpenedEnrollmentToken = pendingEnrollment.token
    }

    public func createPairingSession() {
        Task { [weak self] in
            guard let self else { return }
            do {
                self.log.info("Creating pairing session")
                self.pairingSession = nil
                let registration = try await self.ensureDeviceRegistration()
                if registration.isApprovalRequired {
                    try await self.beginEnrollmentFlow(from: registration)
                    self.lastConnectionError = nil
                    return
                }
                guard let device = registration.device else {
                    throw AppCoreError.invalidResponse
                }
                self.pairingSession = try await self.requestPairingSession(
                    deviceID: device.id,
                    deviceSecret: registration.deviceSecret
                )
                self.lastConnectionError = nil
                self.log.notice("Pairing session ready sessionId=\(self.pairingSession?.id ?? "nil") expiresAt=\(self.pairingSession?.expiresAt ?? "nil")")
            } catch {
                self.lastConnectionError = error.localizedDescription
                self.log.error("Failed to create pairing session error=\(error.localizedDescription)")
                await self.recordTrace(level: "error", kind: "pairing", message: error.localizedDescription)
            }
        }
    }

    public func logOutHostedDevice() {
        guard configuration.hostMode == .hosted else {
            return
        }

        clearStoredDeviceRegistration(
            logMessage: "Clearing saved hosted device registration"
        )

        guard shouldMaintainBrokerConnection else {
            return
        }

        scheduleBrokerReconnect(after: .zero)
    }

    public func hardStop() {
        guard let turn = agentTurn else {
            log.debug("Ignoring hardStop because no turn is active")
            return
        }
        log.warning("Hard stop requested turnId=\(turn.id)")
        Task {
            try? await codexClient.cancelTurn(turnID: turn.id)
        }
    }

    private func scheduleBrokerReconnect(after delay: Duration) {
        guard shouldMaintainBrokerConnection else {
            return
        }
        guard brokerReconnectTask == nil else {
            log.debug("Broker reconnect already scheduled")
            return
        }
        log.info("Scheduling broker reconnect delay=\(logDuration(delay))")

        brokerReconnectTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer {
                self.brokerReconnectTask = nil
            }

            var nextDelay = delay
            while self.shouldMaintainBrokerConnection, !Task.isCancelled {
                if nextDelay > .zero {
                    try? await Task.sleep(for: nextDelay)
                    guard !Task.isCancelled else {
                        return
                    }
                }

                do {
                    self.log.info("Attempting broker reconnect")
                    try await self.connectBrokerAndRefreshPairing()
                    self.lastConnectionError = nil
                    self.log.notice("Broker reconnect succeeded")
                    return
                } catch {
                    self.lastConnectionError = error.localizedDescription
                    self.log.error("Broker reconnect failed error=\(error.localizedDescription)")
                    await self.recordTrace(level: "error", kind: "broker_connect", message: error.localizedDescription)
                    nextDelay = .seconds(2)
                }
            }
        }
    }

    private func connectBrokerAndRefreshPairing() async throws {
        guard shouldMaintainBrokerConnection else {
            return
        }
        let registration = try await ensureDeviceRegistration()
        if registration.isApprovalRequired {
            try await beginEnrollmentFlow(from: registration)
            return
        }
        guard
            let approvedDevice = registration.device,
            let deviceID = registration.deviceId ?? registration.device?.id,
            let wsURL = registration.wsUrl
        else {
            throw AppCoreError.invalidResponse
        }
        pendingEnrollment = nil
        enrollmentPollingTask?.cancel()
        enrollmentPollingTask = nil
        lastOpenedEnrollmentToken = nil
        let authMode = try await currentControlPlaneAuthMode()
        let brokerWSURLString =
            authMode == .required
            ? try await requestHostWebSocketTicket(
                deviceID: deviceID,
                deviceSecret: registration.deviceSecret
            ).wsUrl
            : wsURL
        try await connectBroker(wsURLString: brokerWSURLString)
        if Self.shouldRefreshPairingSession(current: pairingSession, deviceID: approvedDevice.id) {
            pairingSession = try await requestPairingSession(
                deviceID: approvedDevice.id,
                deviceSecret: registration.deviceSecret
            )
        } else {
            log.info("Reusing existing pairing session sessionId=\(pairingSession?.id ?? "nil") deviceId=\(approvedDevice.id)")
        }
        await publishHostStatus()
        await publishDeckSnapshots()
    }

    nonisolated static func shouldRefreshPairingSession(
        current: PairingSessionPayload?,
        deviceID: String,
        now: Date = Date()
    ) -> Bool {
        guard let current else {
            return true
        }
        guard current.deviceId == deviceID else {
            return true
        }
        guard let expirationDate = ISO8601DateFormatter().date(from: current.expiresAt) else {
            return true
        }
        return expirationDate <= now
    }

    private func persistConfiguration() {
        configurationStore.save(configuration)
        keychainTokenStore.save(configuration.deviceSecret, for: .deviceSecret)
    }

    private func clearStoredDeviceRegistration(logMessage: String) {
        log.notice("\(logMessage) deviceId=\(configuration.deviceID ?? "unregistered")")
        registrationTask?.cancel()
        registrationTask = nil
        brokerReconnectTask?.cancel()
        brokerReconnectTask = nil
        enrollmentPollingTask?.cancel()
        enrollmentPollingTask = nil
        pairingSession = nil
        pendingEnrollment = nil
        lastOpenedEnrollmentToken = nil
        lastConnectionError = nil
        configuration.deviceID = nil
        configuration.deviceSecret = nil
        persistConfiguration()
        hostStatus.deviceId = "unregistered"
        hostStatus.online = false
        brokerClient.disconnect()
    }

    private func beginEnrollmentFlow(from registration: BrokerRegistration) async throws {
        guard
            registration.isApprovalRequired,
            let deviceID = registration.deviceId,
            let enrollmentUrl = registration.enrollmentUrl,
            let enrollmentToken = registration.enrollmentToken,
            let expiresAt = registration.expiresAt
        else {
            throw AppCoreError.invalidResponse
        }

        pendingEnrollment = DeviceEnrollmentPayload(
            id: enrollmentToken,
            token: enrollmentToken,
            deviceId: deviceID,
            deviceName: configuration.deviceName,
            deviceMode: configuration.hostMode,
            status: .pending,
            enrollmentUrl: enrollmentUrl,
            expiresAt: expiresAt,
            createdAt: isoNow(),
            approvedAt: nil,
            approvedByUserId: nil
        )
        pairingSession = nil
        hostStatus.online = false
        if lastOpenedEnrollmentToken != enrollmentToken, let url = URL(string: enrollmentUrl) {
            NSWorkspace.shared.open(url)
            lastOpenedEnrollmentToken = enrollmentToken
        }
        startEnrollmentPolling(token: enrollmentToken)
    }

    private func refreshControlPlaneAuthMode() async throws -> ControlPlaneAuthMode {
        let request = URLRequest(url: URL(string: "\(configuration.controlPlaneBaseURL)/health")!)
        let (data, response) = try await urlSession.data(for: request)
        try Self.assertSuccessfulHTTPResponse(data: data, response: response)
        let health = try JSONDecoder().decode(ControlPlaneHealthPayload.self, from: data)
        controlPlaneAuthMode = health.authMode
        return health.authMode
    }

    private func currentControlPlaneAuthMode() async throws -> ControlPlaneAuthMode {
        if let controlPlaneAuthMode {
            return controlPlaneAuthMode
        }
        return try await refreshControlPlaneAuthMode()
    }

    private func requestHostWebSocketTicket(
        deviceID: String,
        deviceSecret: String
    ) async throws -> WebSocketTicketPayload {
        let requestBody = [
            "type": "host",
            "deviceId": deviceID,
            "deviceSecret": deviceSecret,
        ]
        let data = try JSONEncoder().encode(requestBody)
        var request = URLRequest(url: URL(string: "\(configuration.controlPlaneBaseURL)/ws/ticket")!)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = data

        let (responseData, response) = try await urlSession.data(for: request)
        try Self.assertSuccessfulHTTPResponse(data: responseData, response: response)
        return try JSONDecoder().decode(WebSocketTicketPayload.self, from: responseData)
    }

    @discardableResult
    func ensureDeviceRegistration() async throws -> BrokerRegistration {
        if let registrationTask {
            log.debug("Joining in-flight device registration")
            return try await registrationTask.value
        }

        let clock = ContinuousClock()
        let startedAt = clock.now
        log.info("Registering device baseUrl=\(configuration.controlPlaneBaseURL) existingDeviceId=\(configuration.deviceID ?? "nil")")
        let registrationTask = Task<BrokerRegistration, Error> { [self, urlSession] in
            let request = try await makeRegisterRequest()
            let (data, response) = try await urlSession.data(for: request)
            try Self.assertSuccessfulHTTPResponse(data: data, response: response)
            return try JSONDecoder().decode(BrokerRegistration.self, from: data)
        }
        self.registrationTask = registrationTask
        defer {
            self.registrationTask = nil
        }

        let registration = try await registrationTask.value
        configuration.deviceID = registration.deviceId ?? registration.device?.id
        configuration.deviceSecret = registration.deviceSecret
        persistConfiguration()
        hostStatus.deviceId = registration.deviceId ?? registration.device?.id ?? "unregistered"
        lastConnectionError = nil
        log.notice("Device registration ready deviceId=\(registration.deviceId ?? registration.device?.id ?? "unregistered") elapsed=\(logDuration(startedAt.duration(to: clock.now)))")
        return registration
    }

    private func makeRegisterRequest() async throws -> URLRequest {
        var body: [String: Any] = [
            "name": configuration.deviceName,
            "mode": configuration.hostMode.rawValue
        ]
        let existingDeviceID = configuration.deviceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingDeviceSecret = configuration.deviceSecret?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let existingDeviceID, !existingDeviceID.isEmpty {
            guard let existingDeviceSecret, !existingDeviceSecret.isEmpty else {
                throw AppCoreError.missingConfiguration(
                    "Stored device registration is incomplete. RemoteOS will not create a replacement device automatically; clear the saved registration and pair this Mac again."
                )
            }
            body["existingDeviceId"] = existingDeviceID
            body["existingDeviceSecret"] = existingDeviceSecret
        } else if let existingDeviceSecret, !existingDeviceSecret.isEmpty {
            throw AppCoreError.missingConfiguration(
                "Stored device secret exists without a device ID. Clear the saved registration and pair this Mac again."
            )
        }
        var request = URLRequest(url: URL(string: "\(configuration.controlPlaneBaseURL)/devices/register")!)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try dataFromJSONObject(body)
        return request
    }

    private func connectBroker(wsURLString: String) async throws {
        guard let url = URL(string: wsURLString) else {
            throw AppCoreError.invalidResponse
        }

        log.info("Connecting broker to ws url=\(wsURLString)")
        hostStatus.online = true
        brokerClient.connect(to: url)
    }

    private func requestPairingSession(deviceID: String, deviceSecret: String) async throws -> PairingSessionPayload {
        log.info("Requesting pairing session deviceId=\(deviceID)")
        do {
            return try await performPairingRequest(deviceID: deviceID, deviceSecret: deviceSecret)
        } catch {
            if case let AppCoreError.invalidPayload(message) = error, message.contains("Unauthorized device") {
                log.warning("Pairing request unauthorized; refreshing device registration")
                let refreshedRegistration = try await ensureDeviceRegistration()
                guard let refreshedDeviceID = refreshedRegistration.deviceId ?? refreshedRegistration.device?.id else {
                    throw AppCoreError.invalidResponse
                }
                return try await performPairingRequest(
                    deviceID: refreshedDeviceID,
                    deviceSecret: refreshedRegistration.deviceSecret
                )
            }
            throw error
        }
    }

    private func startEnrollmentPolling(token: String) {
        if enrollmentPollingTask != nil, pendingEnrollment?.token == token {
            return
        }

        enrollmentPollingTask?.cancel()
        enrollmentPollingTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            defer {
                self.enrollmentPollingTask = nil
            }

            while self.shouldMaintainBrokerConnection, !Task.isCancelled {
                do {
                    let enrollment = try await self.requestEnrollmentStatus(token: token)
                    self.pendingEnrollment = enrollment
                    switch enrollment.status {
                    case .approved:
                        self.pendingEnrollment = nil
                        self.lastConnectionError = nil
                        self.lastOpenedEnrollmentToken = nil
                        self.scheduleBrokerReconnect(after: .zero)
                        return
                    case .expired:
                        self.lastConnectionError = "Authorization timed out. Open the sign-in page again from the Mac app."
                        return
                    case .pending:
                        break
                    }
                } catch {
                    self.lastConnectionError = error.localizedDescription
                    return
                }

                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func requestEnrollmentStatus(token: String) async throws -> DeviceEnrollmentPayload {
        let request = URLRequest(
            url: URL(string: "\(configuration.controlPlaneBaseURL)/devices/enrollments/\(token)")!
        )
        let (data, response) = try await urlSession.data(for: request)
        try Self.assertSuccessfulHTTPResponse(data: data, response: response)
        return try JSONDecoder().decode(DeviceEnrollmentPayload.self, from: data)
    }

    private func performPairingRequest(deviceID: String, deviceSecret: String) async throws -> PairingSessionPayload {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let requestBody = ["deviceId": deviceID, "deviceSecret": deviceSecret]
        let data = try JSONEncoder().encode(requestBody)
        var request = URLRequest(url: URL(string: "\(configuration.controlPlaneBaseURL)/pairings")!)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = data
        let (responseData, response) = try await urlSession.data(for: request)
        try Self.assertSuccessfulHTTPResponse(data: responseData, response: response)
        let session = try JSONDecoder().decode(PairingSessionPayload.self, from: responseData)
        log.notice("Pairing session received sessionId=\(session.id) elapsed=\(logDuration(startedAt.duration(to: clock.now)))")
        return session
    }

    private static func assertSuccessfulHTTPResponse(data: Data, response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppCoreError.invalidResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let message = (try? anyDictionary(from: data)["error"] as? String) ?? "HTTP \(httpResponse.statusCode)"
            throw AppCoreError.invalidPayload(message)
        }
    }

    private func refreshWindowsNow() async {
        var updatedWindows = await inventoryService.listWindows()

        // SCWindow.frame can return wrong values for windows that
        // ScreenCaptureKit can't capture per-window.  Cross-check with the
        // Accessibility API which always returns correct bounds.
        for i in updatedWindows.indices {
            if let axRect = accessibilityService.windowBounds(for: updatedWindows[i]) {
                updatedWindows[i].bounds = WindowBounds(
                    x: axRect.origin.x,
                    y: axRect.origin.y,
                    width: axRect.size.width,
                    height: axRect.size.height
                )
            }
        }

        windows = updatedWindows

        if let selectedWindowID, !updatedWindows.contains(where: { $0.id == selectedWindowID }) {
            self.selectedWindowID = nil
            hostStatus.selectedWindowId = nil
            try? await windowStreamService.stop()
            invalidateFrames(reason: "The selected window is no longer available.")
        }

        await brokerClient.sendNotification(method: "windows.updated", payload: ["windows": updatedWindows])
        await publishHostStatus()
    }

    private func publishHostStatus() async {
        publishHostStatusSnapshot(hostStatus)
    }

    private func publishDeckSnapshots() async {
        for window in windows {
            do {
                let snapshot = try await screenshotService.capture(
                    windowID: window.id,
                    topologyVersion: displayTopologyVersion,
                    reason: "deck_snapshot",
                    maxPixelSize: 320,
                    compressionQuality: 0.5
                )
                clearDeckSnapshotFailure(forWindowID: window.id)
                let payload = WindowSnapshotPayload(
                    window: window,
                    capturedAt: snapshot.capturedAt,
                    mimeType: snapshot.mimeType,
                    dataBase64: snapshot.dataBase64
                )
                await brokerClient.sendNotification(method: "window.snapshot", payload: payload)
            } catch {
                // Log locally only — deck snapshot failures are operational
                // noise that shouldn't be surfaced to the client UI.
                if shouldLogDeckSnapshotFailure(forWindowID: window.id, message: error.localizedDescription) {
                    log.warning("deck_snapshot failed windowId=\(window.id) \(window.ownerName) — \(window.title): \(error.localizedDescription)")
                }
                continue
            }
        }
    }

    private func shouldLogDeckSnapshotFailure(
        forWindowID windowID: Int,
        message: String,
        now: Date = Date()
    ) -> Bool {
        let minimumInterval: TimeInterval = 30
        guard let previous = deckSnapshotFailures[windowID] else {
            deckSnapshotFailures[windowID] = DeckSnapshotFailureState(message: message, lastLoggedAt: now)
            return true
        }
        if previous.message != message || now.timeIntervalSince(previous.lastLoggedAt) >= minimumInterval {
            deckSnapshotFailures[windowID] = DeckSnapshotFailureState(message: message, lastLoggedAt: now)
            return true
        }
        return false
    }

    private func clearDeckSnapshotFailure(forWindowID windowID: Int) {
        deckSnapshotFailures.removeValue(forKey: windowID)
    }

    private func resolvedOpenAIAPIKey() -> String? {
        if let value = openAIAPIKeyStore.load()?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        return nil
    }

    private func refreshOpenAIAPIKeyState() {
        if let value = openAIAPIKeyStore.load()?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            openAIAPIKeyConfigured = true
            openAIAPIKeyStorageSource = .saved
        } else {
            openAIAPIKeyConfigured = false
            openAIAPIKeyStorageSource = .none
        }
    }

    private func publishSemanticDiffIfNeeded() async {
        guard let selectedWindow = selectedWindow else {
            return
        }
        let snapshot = accessibilityService.snapshot(for: selectedWindow)
        let lastSummary = semanticSummaryByWindow[selectedWindow.id]
        guard lastSummary != snapshot.summary else {
            return
        }
        semanticSummaryByWindow[selectedWindow.id] = snapshot.summary
        let diff = SemanticDiffPayload(
            windowId: selectedWindow.id,
            changedAt: isoNow(),
            summary: snapshot.summary
        )
        await brokerClient.sendNotification(method: "semantic.diff", payload: diff)
    }

    private func startFrameStream(for windowID: Int) async throws {
        guard windows.contains(where: { $0.id == windowID }) else {
            throw AppCoreError.missingWindow
        }

        try await windowStreamService.start(windowID: windowID, topologyVersion: displayTopologyVersion)
    }

    private func captureAndStoreFrame(windowID: Int, reason: String = "frame_capture") async throws -> CapturedFrame {
        // Get real window bounds from Accessibility API for the display-region
        // capture fallback (SCWindow.frame can be wrong for uncapturable windows).
        let axBounds = windows.first(where: { $0.id == windowID })
            .flatMap { accessibilityService.windowBounds(for: $0) }
        let frame = try await screenshotService.capture(
            windowID: windowID,
            topologyVersion: displayTopologyVersion,
            reason: reason,
            accessibilityBounds: axBounds
        )
        latestFrameByWindowID[frame.windowId] = frame
        toolCapturedFrames[frame.frameId] = frame
        // Cap size to prevent unbounded growth (each frame carries base64 data).
        if toolCapturedFrames.count > 32 {
            let oldest = toolCapturedFrames.sorted { $0.value.capturedAt < $1.value.capturedAt }
            for entry in oldest.prefix(toolCapturedFrames.count - 16) {
                toolCapturedFrames.removeValue(forKey: entry.key)
            }
        }
        return frame
    }

    private func invalidateFrames(reason: String) {
        latestFrameByWindowID.removeAll()
        toolCapturedFrames.removeAll()
        pendingStreamFramePayload = nil
        Task {
            await recordTrace(level: "warning", kind: "frame_invalidated", message: reason)
        }
    }

    private func enqueueStreamFrame(_ frame: CapturedFrame) {
        latestFrameByWindowID[frame.windowId] = frame
        pendingStreamFramePayload = WindowFramePayload(
            windowId: frame.windowId,
            frameId: frame.frameId,
            capturedAt: frame.capturedAt,
            mimeType: frame.mimeType,
            dataBase64: frame.dataBase64,
            width: frame.width,
            height: frame.height,
            displayId: frame.displayID,
            sourceRectPoints: frame.sourceRectPoints,
            pointPixelScale: frame.pointPixelScale
        )

        if streamFramePublishTask == nil {
            let brokerClient = self.brokerClient
            streamFramePublishTask = Task.detached(priority: .utility) { [weak self, brokerClient] in
                while !Task.isCancelled {
                    let nextPayload = await MainActor.run { [weak self] () -> WindowFramePayload? in
                        guard let self else {
                            return nil
                        }

                        let payload = self.pendingStreamFramePayload
                        self.pendingStreamFramePayload = nil
                        if payload == nil {
                            self.streamFramePublishTask = nil
                        }
                        return payload
                    }

                    guard let nextPayload else {
                        return
                    }

                    await brokerClient.sendNotification(method: "window.frame", payload: nextPayload)
                }
            }
        }
    }

    private func handle(request: JsonRpcRequest) async {
        log.info("Handling broker request method=\(request.method) id=\(request.id ?? "nil")")
        switch request.method {
        case "windows.list":
            await refreshWindowsNow()
            await brokerClient.sendSuccess(id: request.id ?? UUID().uuidString, payload: ["windows": windows])
        case "window.select":
            guard let windowId = request.params["windowId"] as? Int else {
                await brokerClient.sendError(id: request.id, code: -32602, message: "Missing windowId")
                return
            }
            do {
                await refreshWindowsNow()
                guard windows.contains(where: { $0.id == windowId }) else {
                    throw AppCoreError.missingWindow
                }
                selectedWindowID = windowId
                hostStatus.selectedWindowId = windowId
                do {
                    try await startFrameStream(for: windowId)
                } catch {
                    await recordTrace(level: "warning", kind: "frame_stream", message: error.localizedDescription)
                }
                await brokerClient.sendSuccess(id: request.id ?? UUID().uuidString, payload: ["ok": true])
                await publishHostStatus()
            } catch {
                await brokerClient.sendError(id: request.id, code: -32000, message: error.localizedDescription)
            }
        case "stream.start":
            guard let windowId = request.params["windowId"] as? Int else {
                await brokerClient.sendError(id: request.id, code: -32602, message: "Missing windowId")
                return
            }
            do {
                await refreshWindowsNow()
                guard windows.contains(where: { $0.id == windowId }) else {
                    throw AppCoreError.missingWindow
                }
                try await startFrameStream(for: windowId)
                await brokerClient.sendSuccess(id: request.id ?? UUID().uuidString, payload: ["ok": true])
            } catch {
                await brokerClient.sendError(id: request.id, code: -32000, message: error.localizedDescription)
            }
        case "stream.stop":
            do {
                try await windowStreamService.stop()
                await brokerClient.sendSuccess(id: request.id ?? UUID().uuidString, payload: ["ok": true])
            } catch {
                await brokerClient.sendError(id: request.id, code: -32000, message: error.localizedDescription)
            }
        case "input.tap":
            await handleTapRequest(request)
        case "input.drag":
            await handleDragRequest(request)
        case "input.scroll":
            await handleScrollRequest(request)
        case "input.key":
            await handleKeyRequest(request)
        case "semantic.snapshot":
            guard
                let windowId = request.params["windowId"] as? Int,
                let window = windows.first(where: { $0.id == windowId })
            else {
                await brokerClient.sendError(id: request.id, code: -32602, message: "Invalid semantic snapshot payload")
                return
            }
            let snapshot = accessibilityService.snapshot(for: window)
            semanticSummaryByWindow[windowId] = snapshot.summary
            await brokerClient.sendSuccess(id: request.id ?? UUID().uuidString, payload: snapshot)
        case "semantic.diff.subscribe":
            await brokerClient.sendSuccess(id: request.id ?? UUID().uuidString, payload: ["ok": true])
        case "host.state.sync":
            await brokerClient.sendNotification(method: "windows.updated", payload: ["windows": windows])
            await publishHostStatus()
            if let requestID = request.id {
                await brokerClient.sendSuccess(id: requestID, payload: ["ok": true])
            }
        case "agent.turn.start":
            guard let prompt = request.params["prompt"] as? String, !prompt.isEmpty else {
                await brokerClient.sendError(id: request.id, code: -32602, message: "Missing prompt")
                return
            }
            await startAgentTurn(prompt: prompt, requestID: request.id ?? UUID().uuidString)
        case "agent.turn.cancel":
            guard let turnId = request.params["turnId"] as? String else {
                await brokerClient.sendError(id: request.id, code: -32602, message: "Missing turnId")
                return
            }
            do {
                try await codexClient.cancelTurn(turnID: turnId)
                await brokerClient.sendSuccess(id: request.id ?? UUID().uuidString, payload: ["ok": true])
            } catch {
                await brokerClient.sendError(id: request.id, code: -32000, message: error.localizedDescription)
            }
        case "agent.thread.reset":
            do {
                agentItems.removeAll()
                agentTurn = nil
                clearAllPrompts(status: .interrupted)
                try await codexClient.resetThread()
                await brokerClient.sendSuccess(id: request.id ?? UUID().uuidString, payload: ["ok": true])
            } catch {
                await brokerClient.sendError(id: request.id, code: -32000, message: error.localizedDescription)
            }
        case "agent.prompt.respond":
            do {
                let payload = try decodePayload(AgentPromptResponsePayload.self, from: request.params)
                guard submitPromptResponse(payload) else {
                    await brokerClient.sendError(id: request.id, code: -32000, message: "Prompt \(payload.id) is no longer pending.")
                    return
                }
                await brokerClient.sendSuccess(id: request.id ?? UUID().uuidString, payload: ["ok": true])
            } catch {
                await brokerClient.sendError(id: request.id, code: -32000, message: error.localizedDescription)
            }
        case "agent.config.setModel":
            guard let modelId = request.params["modelId"] as? String, !modelId.isEmpty else {
                await brokerClient.sendError(id: request.id, code: -32602, message: "Missing modelId")
                return
            }
            log.info("Setting codex model to \(modelId)")
            configuration.codexModel = modelId
            persistConfiguration()
            await brokerClient.sendSuccess(id: request.id ?? UUID().uuidString, payload: ["ok": true])
            Task {
                _ = await codexClient.prepareForTurns(forceStatusRefresh: true)
            }
        default:
            await brokerClient.sendError(id: request.id, code: -32601, message: "Unknown method \(request.method)")
        }
    }

    private func startAgentTurn(prompt: String, requestID: String) async {
        let clock = ContinuousClock()
        let startedAt = clock.now
        log.notice("Broker requested agent turn start requestId=\(requestID) selectedWindowId=\(selectedWindowID.map(String.init) ?? "nil") promptPreview=\"\(logPreview(prompt, limit: 100))\"")
        do {
            let turn = try await codexClient.startTurn(prompt: prompt, targetWindowID: selectedWindowID)
            agentTurn = turn
            let userItem = AgentItemPayload.userMessage(turnID: turn.id, prompt: prompt, timestamp: turn.startedAt)
            await brokerClient.sendSuccess(
                id: requestID,
                payload: AgentTurnStartResultPayload(turn: turn, userItem: userItem)
            )
            log.notice("Agent turn start acknowledged requestId=\(requestID) turnId=\(turn.id) elapsed=\(logDuration(startedAt.duration(to: clock.now)))")
        } catch {
            log.error("Agent turn start failed requestId=\(requestID) elapsed=\(logDuration(startedAt.duration(to: clock.now))) error=\(error.localizedDescription)")
            await brokerClient.sendError(id: requestID, code: -32000, message: error.localizedDescription)
        }
    }

    private func handleTapRequest(_ request: JsonRpcRequest) async {
        do {
            let payload = try decodePayload(InputTapPayload.self, from: request.params)
            let window = try await focusWindow(for: payload.windowId)
            let frame = try validatedFrame(frameID: payload.frameId, for: window)
            inputInjector.tap(frame: frame, normalizedX: payload.normalizedX, normalizedY: payload.normalizedY, clickCount: payload.clickCount)
            await refreshWindowsAfterAction(for: window)
            await brokerClient.sendSuccess(id: request.id ?? UUID().uuidString, payload: ["ok": true])
        } catch {
            await brokerClient.sendError(id: request.id, code: -32000, message: error.localizedDescription)
        }
    }

    private func handleDragRequest(_ request: JsonRpcRequest) async {
        do {
            let payload = try decodePayload(InputDragPayload.self, from: request.params)
            let window = try await focusWindow(for: payload.windowId)
            let frame = try validatedFrame(frameID: payload.frameId, for: window)
            inputInjector.drag(frame: frame, fromX: payload.fromX, fromY: payload.fromY, toX: payload.toX, toY: payload.toY)
            await refreshWindowsAfterAction(for: window)
            await brokerClient.sendSuccess(id: request.id ?? UUID().uuidString, payload: ["ok": true])
        } catch {
            await brokerClient.sendError(id: request.id, code: -32000, message: error.localizedDescription)
        }
    }

    private func handleScrollRequest(_ request: JsonRpcRequest) async {
        do {
            let payload = try decodePayload(InputScrollPayload.self, from: request.params)
            let window = try await focusWindow(for: payload.windowId)
            let frame = try validatedFrame(frameID: payload.frameId, for: window)
            inputInjector.scroll(frame: frame, deltaX: payload.deltaX, deltaY: payload.deltaY)
            await refreshWindowsAfterAction(for: window)
            await brokerClient.sendSuccess(id: request.id ?? UUID().uuidString, payload: ["ok": true])
        } catch {
            await brokerClient.sendError(id: request.id, code: -32000, message: error.localizedDescription)
        }
    }

    private func handleKeyRequest(_ request: JsonRpcRequest) async {
        do {
            let payload = try decodePayload(InputKeyPayload.self, from: request.params)
            let window = try await focusWindow(for: payload.windowId)
            _ = try validatedFrame(frameID: payload.frameId, for: window)
            if let text = payload.text {
                inputInjector.type(text: text)
            } else if let key = payload.key, inputInjector.key(named: key) == false {
                throw AppCoreError.invalidPayload("Unsupported key \(key)")
            }
            await refreshWindowsAfterAction(for: window)
            await brokerClient.sendSuccess(id: request.id ?? UUID().uuidString, payload: ["ok": true])
        } catch {
            await brokerClient.sendError(id: request.id, code: -32000, message: error.localizedDescription)
        }
    }

    private func focusWindow(for windowID: Int) async throws -> WindowDescriptor {
        await refreshWindowsNow()
        guard let window = windows.first(where: { $0.id == windowID }) else {
            throw AppCoreError.missingWindow
        }

        guard accessibilityService.focus(window: window) else {
            throw AppCoreError.focusFailed
        }

        await refreshWindowsNow()
        if let focused = accessibilityService.focusedWindowDescriptor(pid: window.ownerPid, knownWindows: windows) {
            if focused.id != selectedWindowID {
                selectedWindowID = focused.id
                hostStatus.selectedWindowId = focused.id
                do {
                    try await startFrameStream(for: focused.id)
                } catch {
                    await recordTrace(level: "warning", kind: "frame_stream", message: error.localizedDescription)
                }
                await publishHostStatus()
            }
            return focused
        }

        guard accessibilityService.isFocused(window: window) else {
            throw AppCoreError.focusFailed
        }

        return window
    }

    private func validatedFrame(frameID: String, for window: WindowDescriptor) throws -> CapturedFrame {
        // Look up by frameId directly so the continuous frame stream (which
        // overwrites latestFrameByWindowID) cannot invalidate tool-captured
        // frames between capture and action.
        guard let frame = toolCapturedFrames[frameID], frame.windowId == window.id else {
            throw AppCoreError.staleFrame
        }
        guard frame.topologyVersion == displayTopologyVersion else {
            throw AppCoreError.staleFrame
        }

        guard Self.capturedWindowBoundsStillMatch(frame.windowBoundsPoints, current: window.bounds) else {
            throw AppCoreError.staleFrame
        }
        return frame
    }

    private func refreshWindowsAfterAction(for window: WindowDescriptor) async {
        await refreshWindowsNow()
        if let focused = accessibilityService.focusedWindowDescriptor(pid: window.ownerPid, knownWindows: windows) {
            if focused.id != selectedWindowID {
                selectedWindowID = focused.id
                hostStatus.selectedWindowId = focused.id
                do {
                    try await startFrameStream(for: focused.id)
                } catch {
                    await recordTrace(level: "warning", kind: "frame_stream", message: error.localizedDescription)
                }
                await publishHostStatus()
            }
        }
    }

    private func pressVisibleText(label: String, in window: WindowDescriptor) async throws {
        let frame = try await captureAndStoreFrame(
            windowID: window.id,
            reason: "tool:remoteos_window_press_element_lookup"
        )
        guard let match = try textRecognitionService.bestMatch(in: frame, query: label) else {
            throw AppCoreError.invalidPayload("Could not find a matching visible element named \(label).")
        }
        textRecognitionService.logMatch(frame: frame, query: label, match: match)
        let center = match.centerPointPixels
        try inputInjector.click(frame: frame, x: center.x, y: center.y, clickCount: 1)
    }

    private func executeDynamicTool(
        invocation: DynamicToolInvocation,
        named tool: String,
        arguments: [String: Any]
    ) async throws -> DynamicToolResult {
        switch tool {
        case "remoteos_list_windows":
            await refreshWindowsNow()
            let body = windows
                .enumerated()
                .map { index, window in
                    "\(index + 1). id=\(window.id) \(window.ownerName) — \(window.title)"
                }
                .joined(separator: "\n")
            return DynamicToolResult(
                contentItems: [.init(type: .inputText(body.isEmpty ? "No windows are available." : body))],
                success: true
            )
        case "remoteos_select_window":
            guard let rawWindowID = arguments["windowId"] as? Int else {
                throw AppCoreError.invalidPayload("windowId is required.")
            }
            await refreshWindowsNow()
            guard windows.contains(where: { $0.id == rawWindowID }) else {
                throw AppCoreError.missingWindow
            }
            selectedWindowID = rawWindowID
            hostStatus.selectedWindowId = rawWindowID
            do {
                try await startFrameStream(for: rawWindowID)
            } catch {
                await recordTrace(level: "warning", kind: "frame_stream", message: error.localizedDescription)
            }
            _ = try await focusWindow(for: rawWindowID)
            await publishHostStatus()
            do {
                return try await captureSelectedWindowResult(
                    prefix: "Selected and focused window \(rawWindowID).",
                    reason: "tool:remoteos_select_window"
                )
            } catch {
                // Screenshot may fail for certain windows (e.g. permission
                // changes not yet effective). Still report success so the
                // agent can proceed with accessibility-based tools.
                guard let selectedWindow else {
                    throw error
                }
                let summary = """
                Selected and focused window \(rawWindowID).
                Window: \(selectedWindow.ownerName) — \(selectedWindow.title)
                Screenshot unavailable: \(error.localizedDescription)
                Use accessibility tools (remoteos_window_semantic_snapshot, remoteos_window_press_element) to interact with this window.
                """
                return DynamicToolResult(
                    contentItems: [.init(type: .inputText(summary))],
                    success: true
                )
            }
        case "remoteos_window_capture":
            return try await captureSelectedWindowResult(
                prefix: "Captured the selected window.",
                reason: "tool:remoteos_window_capture"
            )
        case "remoteos_window_semantic_snapshot":
            guard let selectedWindow else {
                throw AppCoreError.invalidPayload("Select a window first.")
            }
            let snapshot = accessibilityService.snapshot(for: selectedWindow)
            let lines = snapshot.elements.prefix(18).map { element in
                [element.role, element.title, element.value].compactMap { $0 }.joined(separator: " | ")
            }
            let text = ([snapshot.summary] + lines).joined(separator: "\n")
            return DynamicToolResult(contentItems: [.init(type: .inputText(text))], success: true)
        case "remoteos_window_focus":
            guard let selectedWindow else {
                throw AppCoreError.invalidPayload("Select a window first.")
            }
            _ = try await focusWindow(for: selectedWindow.id)
            do {
                return try await captureSelectedWindowResult(
                    prefix: "Focused the selected window.",
                    reason: "tool:remoteos_window_focus"
                )
            } catch {
                let summary = """
                Focused the selected window.
                Window: \(selectedWindow.ownerName) — \(selectedWindow.title)
                Screenshot unavailable: \(error.localizedDescription)
                Use accessibility tools (remoteos_window_semantic_snapshot, remoteos_window_press_element) to interact with this window.
                """
                return DynamicToolResult(
                    contentItems: [.init(type: .inputText(summary))],
                    success: true
                )
            }
        case "remoteos_window_press_element":
            guard let selectedWindow else {
                throw AppCoreError.invalidPayload("Select a window first.")
            }
            guard let label = arguments["label"] as? String, !label.isEmpty else {
                throw AppCoreError.invalidPayload("label is required.")
            }
            let focusedWindow = try await focusWindow(for: selectedWindow.id)
            do {
                try await pressVisibleText(label: label, in: focusedWindow)
            } catch {
                guard accessibilityService.press(label: label, in: focusedWindow) else {
                    throw error
                }
            }
            await refreshWindowsAfterAction(for: focusedWindow)
            return try await captureSelectedWindowResult(
                prefix: "Activated labeled control \(label).",
                reason: "tool:remoteos_window_press_element"
            )
        case "remoteos_window_type_element":
            guard let selectedWindow else {
                throw AppCoreError.invalidPayload("Select a window first.")
            }
            guard
                let label = arguments["label"] as? String, !label.isEmpty,
                let text = arguments["text"] as? String, !text.isEmpty
            else {
                throw AppCoreError.invalidPayload("label and text are required.")
            }
            let focusedWindow = try await focusWindow(for: selectedWindow.id)
            guard accessibilityService.type(text: text, into: label, in: focusedWindow) else {
                throw AppCoreError.invalidPayload("Could not set the accessibility value for \(label).")
            }
            await refreshWindowsAfterAction(for: focusedWindow)
            return try await captureSelectedWindowResult(
                prefix: "Typed into accessibility element \(label).",
                reason: "tool:remoteos_window_type_element"
            )
        case "remoteos_window_computer_use":
            return try await runWindowComputerUse(invocation: invocation, arguments: arguments)
        case "remoteos_window_click":
            return try await performPixelTool(
                arguments: arguments,
                action: { frame, args in
                    let x = try Self.number(args["x"], name: "x")
                    let y = try Self.number(args["y"], name: "y")
                    let clickCount = (args["clickCount"] as? Int) ?? 1
                    try inputInjector.click(frame: frame, x: x, y: y, clickCount: clickCount)
                },
                successPrefix: "Clicked in the selected window."
            )
        case "remoteos_window_drag":
            return try await performPixelTool(
                arguments: arguments,
                action: { frame, args in
                    let fromX = try Self.number(args["fromX"], name: "fromX")
                    let fromY = try Self.number(args["fromY"], name: "fromY")
                    let toX = try Self.number(args["toX"], name: "toX")
                    let toY = try Self.number(args["toY"], name: "toY")
                    try inputInjector.drag(
                        frame: frame,
                        path: [
                            CGPoint(x: fromX, y: fromY),
                            CGPoint(x: toX, y: toY)
                        ]
                    )
                },
                successPrefix: "Dragged in the selected window."
            )
        case "remoteos_window_scroll":
            return try await performPixelTool(
                arguments: arguments,
                action: { frame, args in
                    let deltaX = try Self.number(args["deltaX"], name: "deltaX")
                    let deltaY = try Self.number(args["deltaY"], name: "deltaY")
                    inputInjector.scroll(frame: frame, deltaX: deltaX, deltaY: deltaY)
                },
                successPrefix: "Scrolled in the selected window."
            )
        case "remoteos_window_type_text":
            return try await performPixelTool(
                arguments: arguments,
                action: { _, args in
                    guard let text = args["text"] as? String, !text.isEmpty else {
                        throw AppCoreError.invalidPayload("text is required.")
                    }
                    inputInjector.type(text: text)
                },
                successPrefix: "Typed text into the selected window."
            )
        case "remoteos_window_press_key":
            return try await performPixelTool(
                arguments: arguments,
                action: { _, args in
                    guard let key = args["key"] as? String, !key.isEmpty else {
                        throw AppCoreError.invalidPayload("key is required.")
                    }
                    guard inputInjector.keypress(keys: key.split(separator: "+").map(String.init)) else {
                        throw AppCoreError.invalidPayload("Unsupported key \(key).")
                    }
                },
                successPrefix: "Pressed a key in the selected window."
            )
        default:
            return DynamicToolResult(
                contentItems: [.init(type: .inputText("Unknown RemoteOS tool \(tool)."))],
                success: false
            )
        }
    }

    private func captureSelectedWindowResult(prefix: String, reason: String = "selected_window_capture") async throws -> DynamicToolResult {
        guard let selectedWindow else {
            throw AppCoreError.invalidPayload("Select a window first.")
        }
        let frame = try await captureAndStoreFrame(windowID: selectedWindow.id, reason: reason)
        let summary = """
        \(prefix)
        Window: \(selectedWindow.ownerName) — \(selectedWindow.title)
        frame_id: \(frame.frameId)
        image_size: \(frame.width)x\(frame.height)
        source_rect_points: x=\(Int(frame.sourceRectPoints.x)) y=\(Int(frame.sourceRectPoints.y)) width=\(Int(frame.sourceRectPoints.width)) height=\(Int(frame.sourceRectPoints.height))
        point_pixel_scale: \(frame.pointPixelScale)
        Prefer `remoteos_window_press_element` for visible labeled controls instead of guessing pixel coordinates.
        Use image pixel coordinates from the attached image when calling pixel tools.
        """
        return DynamicToolResult(
            contentItems: [
                .init(type: .inputText(summary)),
                .init(type: .inputImage("data:\(frame.mimeType);base64,\(frame.dataBase64)"))
            ],
            success: true
        )
    }

    private func runWindowComputerUse(
        invocation: DynamicToolInvocation,
        arguments: [String: Any]
    ) async throws -> DynamicToolResult {
        guard let goal = arguments["goal"] as? String, !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppCoreError.invalidPayload("goal is required.")
        }
        guard let apiKey = resolvedOpenAIAPIKey() else {
            throw AppCoreError.missingConfiguration("Set an OpenAI API key in RemoteOS Settings before using computer use.")
        }

        let configuration = OpenAIComputerUseService.Configuration(
            apiKey: apiKey,
            model: "gpt-5.4",
            maxResponseTurns: 12,
            wallClockTimeout: .seconds(90),
            instructions: Self.computerUseInstructions()
        )

        do {
            let result = try await computerUseService.run(
                goal: goal,
                invocation: invocation,
                configuration: configuration,
                captureFrame: { [weak self] in
                    guard let self else { throw CancellationError() }
                    await self.recordTrace(level: "info", kind: "computer_use", message: "Capturing window screenshot…")
                    return try await Task { @MainActor in
                        try await self.captureFocusedSelectedWindowFrame()
                    }.value
                },
                executeActions: { [weak self] frame, actions in
                    guard let self else { throw CancellationError() }
                    await self.recordTrace(level: "info", kind: "computer_use", message: Self.describeComputerUseActions(actions))
                    return try await Task { @MainActor in
                        try await self.executeComputerUseActions(actions, from: frame)
                    }.value
                },
                requestPrompt: { [weak self] prompt in
                    guard let self else {
                        return nil
                    }
                    return await Task { @MainActor in
                        await self.presentPrompt(prompt, timeout: .seconds(120), awaitsExplicitResolution: false)
                    }.value
                }
            )
            return computerUseToolResult(
                status: result.status.rawValue,
                message: result.finalMessage,
                frame: result.finalFrame,
                success: result.status == .completed
            )
        } catch is CancellationError {
            let frame = try? await captureFocusedSelectedWindowFrame()
            return computerUseToolResult(
                status: "cancelled",
                message: "The computer-use run was cancelled before it completed.",
                frame: frame,
                success: false
            )
        } catch {
            let frame = try? await captureFocusedSelectedWindowFrame()
            return computerUseToolResult(
                status: "failed",
                message: error.localizedDescription,
                frame: frame,
                success: false
            )
        }
    }

    private func captureFocusedSelectedWindowFrame() async throws -> CapturedFrame {
        guard let selectedWindow else {
            throw AppCoreError.invalidPayload("Select a window first.")
        }
        let focusedWindow = try await focusWindow(for: selectedWindow.id)
        return try await captureAndStoreFrame(windowID: focusedWindow.id, reason: "computer_use_capture")
    }

    private func executeComputerUseActions(
        _ actions: [ComputerUseAction],
        from frame: CapturedFrame
    ) async throws -> CapturedFrame {
        let focusedWindow = try await focusWindow(for: frame.windowId)

        // The frame was captured by our own computer-use flow moments ago, so
        // we trust it without checking latestFrameByWindowID (which the
        // continuous frame stream may have overwritten with a newer frameId
        // in the interim). If the window moved or resized, the frame is stale
        // and must be recaptured before executing more actions.
        guard Self.capturedWindowBoundsStillMatch(frame.windowBoundsPoints, current: focusedWindow.bounds) else {
            throw AppCoreError.staleFrame
        }

        let normalizedActions = try normalizeComputerUseActions(actions)

        for action in normalizedActions {
            try Task.checkCancellation()
            try await executeComputerUseAction(action, frame: frame)
            if action.type != "wait", action.type != "screenshot" {
                try await Task.sleep(for: .milliseconds(120))
            }
        }

        await refreshWindowsAfterAction(for: focusedWindow)
        return try await captureFocusedSelectedWindowFrame()
    }

    private func normalizeComputerUseActions(_ actions: [ComputerUseAction]) throws -> [ComputerUseAction] {
        let filtered = actions.filter { $0.type != "screenshot" }
        let nonNeutral = filtered.filter { $0.type != "wait" }
        let pointerActions = nonNeutral.filter { Self.isPointerAction($0.type) }
        let keyboardActions = nonNeutral.filter { Self.isKeyboardAction($0.type) }

        if pointerActions.isEmpty {
            return filtered
        }
        if !keyboardActions.isEmpty {
            throw AppCoreError.invalidPayload("Computer use returned a pointer action mixed with typing, which RemoteOS does not execute in one batch.")
        }

        if pointerActions.count == 1, nonNeutral.count == 1 {
            return filtered
        }

        if pointerActions.count == 2,
           let firstPointer = pointerActions.first,
           let secondPointer = pointerActions.dropFirst().first,
           firstPointer.type == "move",
           Self.isLeadingMove(for: firstPointer, compatibleWith: secondPointer),
           nonNeutral.count == 2 {
            return filtered.filter { !($0.type == "move" && $0.x == firstPointer.x && $0.y == firstPointer.y) }
        }

        throw AppCoreError.invalidPayload("Computer use returned an unsupported multi-pointer batch.")
    }

    private func executeComputerUseAction(_ action: ComputerUseAction, frame: CapturedFrame) async throws {
        switch action.type {
        case "click":
            try inputInjector.click(
                frame: frame,
                x: try Self.requiredCoordinate(action.x, name: "x"),
                y: try Self.requiredCoordinate(action.y, name: "y"),
                button: Self.mouseButton(from: action.button),
                clickCount: 1
            )
        case "double_click":
            try inputInjector.click(
                frame: frame,
                x: try Self.requiredCoordinate(action.x, name: "x"),
                y: try Self.requiredCoordinate(action.y, name: "y"),
                button: Self.mouseButton(from: action.button),
                clickCount: 2
            )
        case "move":
            try inputInjector.move(
                frame: frame,
                x: try Self.requiredCoordinate(action.x, name: "x"),
                y: try Self.requiredCoordinate(action.y, name: "y")
            )
        case "drag":
            guard let path = action.path, path.count >= 2 else {
                throw AppCoreError.invalidPayload("Computer use drag actions require a path with at least two points.")
            }
            try inputInjector.drag(
                frame: frame,
                path: path.map { CGPoint(x: $0.x, y: $0.y) },
                button: Self.mouseButton(from: action.button)
            )
        case "scroll":
            let deltaX = action.deltaX ?? 0
            let deltaY = action.deltaY ?? action.scrollY ?? 0
            if let x = action.x, let y = action.y {
                try inputInjector.scroll(frame: frame, x: x, y: y, deltaX: deltaX, deltaY: deltaY)
            } else {
                inputInjector.scroll(frame: frame, deltaX: deltaX, deltaY: deltaY)
            }
        case "type":
            guard let text = action.text, !text.isEmpty else {
                throw AppCoreError.invalidPayload("Computer use type actions require text.")
            }
            inputInjector.type(text: text)
        case "keypress":
            let keys = action.keys ?? (action.key.map { [$0] } ?? [])
            guard inputInjector.keypress(keys: keys) else {
                throw AppCoreError.invalidPayload("Computer use returned an unsupported keypress action.")
            }
        case "wait":
            let durationMs = action.durationMs ?? action.ms ?? 750
            if durationMs > 0 {
                try await Task.sleep(for: .milliseconds(Int(durationMs.rounded())))
            }
        case "screenshot":
            return
        default:
            throw AppCoreError.invalidPayload("Unsupported computer-use action \(action.type).")
        }
    }

    private func computerUseToolResult(
        status: String,
        message: String,
        frame: CapturedFrame?,
        success: Bool
    ) -> DynamicToolResult {
        let summary = """
        Computer use status: \(status)
        \(message)
        """
        var contentItems: [DynamicToolContentItem] = [
            .init(type: .inputText(summary))
        ]
        if let frame {
            contentItems.append(.init(type: .inputImage("data:\(frame.mimeType);base64,\(frame.dataBase64)")))
        }
        return DynamicToolResult(contentItems: contentItems, success: success)
    }

    private func performPixelTool(
        arguments: [String: Any],
        action: (CapturedFrame, [String: Any]) throws -> Void,
        successPrefix: String
    ) async throws -> DynamicToolResult {
        guard let selectedWindow else {
            throw AppCoreError.invalidPayload("Select a window first.")
        }
        guard let frameID = arguments["frameId"] as? String, !frameID.isEmpty else {
            throw AppCoreError.invalidPayload("frameId is required.")
        }

        let focusedWindow = try await focusWindow(for: selectedWindow.id)
        let frame = try validatedFrame(frameID: frameID, for: focusedWindow)
        try action(frame, arguments)
        await refreshWindowsAfterAction(for: focusedWindow)
        return try await captureSelectedWindowResult(prefix: successPrefix, reason: "pixel_tool_capture")
    }

    private func presentPrompt(
        _ prompt: AgentPromptPayload,
        timeout: Duration,
        awaitsExplicitResolution: Bool
    ) async -> AgentPromptResponsePayload? {
        pendingPromptTimeoutTasks[prompt.id]?.cancel()
        if awaitsExplicitResolution {
            pendingPromptsAwaitingResolution.insert(prompt.id)
        } else {
            pendingPromptsAwaitingResolution.remove(prompt.id)
        }

        var pendingPrompt = prompt
        pendingPrompt.updatedAt = isoNow()
        upsertAgentPrompt(pendingPrompt)
        publishAgentPromptRequested(pendingPrompt)

        return await withCheckedContinuation { continuation in
            pendingPromptResponses[prompt.id] = continuation
            pendingPromptTimeoutTasks[prompt.id] = Task { [weak self] in
                guard timeout > .zero else {
                    return
                }
                try? await Task.sleep(for: timeout)
                await MainActor.run {
                    self?.resolveAgentPrompt(id: prompt.id, status: .expired)
                }
            }
        }
    }

    @discardableResult
    private func submitPromptResponse(_ response: AgentPromptResponsePayload) -> Bool {
        guard let continuation = pendingPromptResponses.removeValue(forKey: response.id) else {
            return false
        }

        pendingPromptTimeoutTasks.removeValue(forKey: response.id)?.cancel()
        continuation.resume(returning: response)

        if !pendingPromptsAwaitingResolution.contains(response.id) {
            resolveAgentPrompt(id: response.id, status: Self.promptResolutionStatus(for: response.action))
        }
        return true
    }

    private func resolveAgentPrompt(id: String, status: AgentPromptResolutionStatus) {
        if let continuation = pendingPromptResponses.removeValue(forKey: id) {
            continuation.resume(returning: nil)
        }
        pendingPromptTimeoutTasks.removeValue(forKey: id)?.cancel()
        pendingPromptsAwaitingResolution.remove(id)

        guard let index = agentPrompts.firstIndex(where: { $0.id == id }) else {
            return
        }

        let prompt = agentPrompts.remove(at: index)
        let resolved = AgentPromptResolvedPayload(
            id: id,
            turnId: prompt.turnId,
            status: status,
            resolvedAt: isoNow()
        )
        publishAgentPromptResolved(resolved)
    }

    private func clearAllPrompts(status: AgentPromptResolutionStatus) {
        let promptIDs = Set(agentPrompts.map(\.id)).union(pendingPromptResponses.keys)
        for promptID in promptIDs {
            resolveAgentPrompt(id: promptID, status: status)
        }
    }

    private func clearPrompts(forTurnID turnID: String, status: AgentPromptResolutionStatus) {
        let promptIDs = agentPrompts
            .filter { $0.turnId == turnID }
            .map(\.id)
        for promptID in promptIDs {
            resolveAgentPrompt(id: promptID, status: status)
        }
    }

    private func upsertAgentPrompt(_ prompt: AgentPromptPayload) {
        if let index = agentPrompts.firstIndex(where: { $0.id == prompt.id }) {
            agentPrompts[index] = prompt
            return
        }
        agentPrompts.append(prompt)
    }

    private func publishAgentPromptRequested(_ prompt: AgentPromptPayload) {
        let brokerClient = self.brokerClient
        codexBrokerFanoutQueue.enqueue { [brokerClient] in
            await brokerClient.sendNotification(method: "agent.prompt.requested", payload: prompt)
        }
    }

    private func publishAgentPromptResolved(_ payload: AgentPromptResolvedPayload) {
        let brokerClient = self.brokerClient
        codexBrokerFanoutQueue.enqueue { [brokerClient] in
            await brokerClient.sendNotification(method: "agent.prompt.resolved", payload: payload)
        }
    }

    private func decodePayload<T: Decodable>(_ type: T.Type, from params: [String: Any]) throws -> T {
        let data = try dataFromJSONObject(params)
        return try JSONDecoder().decode(type, from: data)
    }

    private func upsertAgentItem(_ item: AgentItemPayload) {
        if let index = agentItems.firstIndex(where: { $0.id == item.id }) {
            agentItems[index] = item
        } else {
            agentItems.append(item)
        }
    }

    private func handleCodexStatusCallback(_ status: CodexStatusPayload) {
        log.info("Codex status updated state=\(status.state.rawValue) threadId=\(status.threadId ?? "nil") activeTurnId=\(status.activeTurnId ?? "nil") lastError=\(status.lastError ?? "none")")
        hostStatus.codex = status
        publishHostStatusSnapshot(hostStatus)
    }

    private func handleCodexTurnCallback(_ turn: AgentTurnPayload) {
        log.notice("Codex turn callback turnId=\(turn.id) status=\(turn.status.rawValue) error=\(turn.error ?? "none")")
        agentTurn = turn
        if turn.status != .running {
            let resolutionStatus: AgentPromptResolutionStatus
            switch turn.status {
            case .completed:
                resolutionStatus = .cancelled
            case .interrupted, .failed:
                resolutionStatus = .interrupted
            case .running:
                resolutionStatus = .submitted
            }
            clearPrompts(forTurnID: turn.id, status: resolutionStatus)
        }
        let brokerClient = self.brokerClient
        codexBrokerFanoutQueue.enqueue { [brokerClient] in
            await brokerClient.sendNotification(method: "agent.turn", payload: turn)
        }
    }

    private func handleCodexItemCallback(_ item: AgentItemPayload) {
        log.info("Codex item callback itemId=\(item.id) turnId=\(item.turnId) kind=\(item.kind.rawValue) status=\(item.status.rawValue)")
        upsertAgentItem(item)
        let brokerClient = self.brokerClient
        codexBrokerFanoutQueue.enqueue { [brokerClient] in
            await brokerClient.sendNotification(method: "agent.item", payload: item)
        }
    }

    private func handleCodexTraceCallback(_ event: TraceEventPayload) {
        log.debug("Codex trace callback kind=\(event.kind) level=\(event.level) taskId=\(event.taskId ?? "nil") message=\(logPreview(event.message, limit: 160))")
        traces.insert(event, at: 0)
        traces = Array(traces.prefix(40))

        let auditStore = self.auditStore
        let brokerClient = self.brokerClient
        codexTraceFanoutQueue.enqueue {
            try? await auditStore.append(event)
            await brokerClient.sendNotification(method: "trace.event", payload: event)
        }
    }

    private func handleCodexThreadIDCallback(_ threadID: String?) {
        log.info("Codex thread id changed threadId=\(threadID ?? "nil")")
        hostStatus.codex.threadId = threadID
        publishHostStatusSnapshot(hostStatus)
    }

    private func publishHostStatusSnapshot(_ status: HostStatusPayload) {
        log.debug("Publishing host status online=\(status.online) selectedWindowId=\(status.selectedWindowId.map(String.init) ?? "nil") codexState=\(status.codex.state.rawValue)")
        let brokerClient = self.brokerClient
        codexBrokerFanoutQueue.enqueue { [brokerClient] in
            await brokerClient.sendNotification(method: "host.status", payload: status)
            await brokerClient.sendNotification(method: "codex.status", payload: status.codex)
        }
    }

    private func storeTrace(_ event: TraceEventPayload) async {
        handleCodexTraceCallback(event)
    }

    private func recordTrace(level: String, kind: String, message: String) async {
        let event = TraceEventPayload(
            id: UUID().uuidString,
            taskId: agentTurn?.id,
            level: level,
            kind: kind,
            message: message,
            createdAt: isoNow(),
            metadata: [:]
        )
        await storeTrace(event)
    }

    private var selectedWindow: WindowDescriptor? {
        guard let selectedWindowID else {
            return nil
        }
        return windows.first(where: { $0.id == selectedWindowID })
    }

    nonisolated private static func codexDeveloperInstructions() -> String {
        """
        You are the local Codex agent running inside RemoteOS on macOS.
        Prefer built-in shell and file tools for repo work, filesystem work, app control, and generic Mac tasks.
        Only use RemoteOS dynamic tools for native macOS window interaction.
        If the user explicitly asks to use the computer-use tool, use `remoteos_window_computer_use` instead of substituting accessibility or pixel tools unless that tool is blocked by permissions or scope.
        Otherwise, prefer accessibility tools before pixel tools or computer use.
        If the user names a visible tab, button, row, or label inside the selected window, prefer `remoteos_window_press_element` before guessing image coordinates. That tool can activate accessibility elements and OCR-detected visible text.
        After selecting a window for native interaction, keep it focused before continuing with visual actions.
        If the user asks you to click, type, press, drag, or scroll in a selected window, continue until you either attempt that action or hit a concrete blocker. Do not stop after only taking a snapshot or capture.
        Use `remoteos_window_computer_use` only when accessibility tools or direct pixel tools are insufficient for visual interaction inside the selected window.
        The computer-use tool is selected-window only. Do not assume full-display context, and do not use it for cross-window or cross-application navigation.
        Before using pixel tools, capture the selected window and use the returned frame_id.
        Pixel tool coordinates are image pixel coordinates relative to the attached capture image, not global screen coordinates.
        If a window is not selected, ask the user to select one or use shell/file tools instead.
        """
    }

    nonisolated private static func remoteToolSpecs() -> [[String: Any]] {
        [
            dynamicTool(name: "remoteos_list_windows", description: "List the currently available macOS windows that RemoteOS can target.", schema: emptySchema()),
            dynamicTool(name: "remoteos_select_window", description: "Select a window by windowId so subsequent RemoteOS tools operate on it.", schema: requiredObject(properties: ["windowId": ["type": "integer"]], required: ["windowId"])),
            dynamicTool(name: "remoteos_window_capture", description: "Capture the currently selected macOS window and return an image plus frame metadata.", schema: emptySchema()),
            dynamicTool(name: "remoteos_window_semantic_snapshot", description: "Return an accessibility snapshot for the currently selected macOS window.", schema: emptySchema()),
            dynamicTool(name: "remoteos_window_focus", description: "Bring the selected macOS window to the front and return a fresh capture.", schema: emptySchema()),
            dynamicTool(name: "remoteos_window_press_element", description: "Activate a visible labeled control in the selected window by label. Uses accessibility when available and OCR-backed text matching for rendered UI.", schema: requiredObject(properties: ["label": ["type": "string"]], required: ["label"])),
            dynamicTool(name: "remoteos_window_type_element", description: "Type into an accessibility element in the selected window by label.", schema: requiredObject(properties: ["label": ["type": "string"], "text": ["type": "string"]], required: ["label", "text"])),
            dynamicTool(name: "remoteos_window_computer_use", description: "Use GPT-5.4 computer use on the selected window only. Provide a goal; RemoteOS will capture the selected window, execute returned actions locally, and return the final screenshot.", schema: requiredObject(properties: ["goal": ["type": "string"]], required: ["goal"])),
            dynamicTool(name: "remoteos_window_click", description: "Click an arbitrary point inside the selected window using image pixel coordinates from the latest capture. Prefer `remoteos_window_press_element` for visible labeled controls instead of guessing coordinates.", schema: requiredObject(properties: ["frameId": ["type": "string"], "x": ["type": "number"], "y": ["type": "number"], "clickCount": ["type": "integer"]], required: ["frameId", "x", "y"])),
            dynamicTool(name: "remoteos_window_drag", description: "Drag inside the selected window using image pixel coordinates from the latest capture.", schema: requiredObject(properties: ["frameId": ["type": "string"], "fromX": ["type": "number"], "fromY": ["type": "number"], "toX": ["type": "number"], "toY": ["type": "number"]], required: ["frameId", "fromX", "fromY", "toX", "toY"])),
            dynamicTool(name: "remoteos_window_scroll", description: "Scroll inside the selected window using the latest capture context.", schema: requiredObject(properties: ["frameId": ["type": "string"], "deltaX": ["type": "number"], "deltaY": ["type": "number"]], required: ["frameId", "deltaX", "deltaY"])),
            dynamicTool(name: "remoteos_window_type_text", description: "Type text into the selected window using the latest capture context.", schema: requiredObject(properties: ["frameId": ["type": "string"], "text": ["type": "string"]], required: ["frameId", "text"])),
            dynamicTool(name: "remoteos_window_press_key", description: "Press a named key in the selected window using the latest capture context.", schema: requiredObject(properties: ["frameId": ["type": "string"], "key": ["type": "string"]], required: ["frameId", "key"]))
        ]
    }

    nonisolated private static func dynamicTool(name: String, description: String, schema: [String: Any]) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": schema
        ]
    }

    nonisolated private static func emptySchema() -> [String: Any] {
        [
            "type": "object",
            "properties": [:]
        ]
    }

    nonisolated private static func requiredObject(properties: [String: [String: Any]], required: [String]) -> [String: Any] {
        [
            "type": "object",
            "properties": properties,
            "required": required
        ]
    }

    nonisolated private static func computerUseInstructions() -> String {
        """
        You are controlling a selected macOS window through RemoteOS.
        You only receive screenshots of the currently selected window, not the whole display.
        Never assume anything outside the visible selected window.
        Stay inside the selected window. Do not attempt cross-window, cross-app, Dock, menu bar, or system-level navigation.
        After any click, drag, type, keypress, or scroll that could change the UI, request a fresh screenshot before continuing.
        Emit at most one pointer action per turn. Keyboard-only batches and wait actions are allowed.
        Use screenshot actions when you need a fresh capture. Use precise image coordinates from the screenshot.
        If the task becomes blocked, unsafe, or requires action outside the selected window, stop and explain why.
        """
    }

    nonisolated private static func describeComputerUseActions(_ actions: [ComputerUseAction]) -> String {
        let descriptions = actions.compactMap { action -> String? in
            switch action.type {
            case "click":
                return "Click at (\(Int(action.x ?? 0)), \(Int(action.y ?? 0)))"
            case "double_click":
                return "Double-click at (\(Int(action.x ?? 0)), \(Int(action.y ?? 0)))"
            case "type":
                let preview = (action.text ?? "").prefix(40)
                return "Type \"\(preview)\(action.text?.count ?? 0 > 40 ? "…" : "")\""
            case "keypress":
                return "Press \(action.keys?.joined(separator: "+") ?? action.key ?? "key")"
            case "scroll":
                return "Scroll"
            case "drag":
                return "Drag"
            case "move":
                return "Move to (\(Int(action.x ?? 0)), \(Int(action.y ?? 0)))"
            case "wait":
                return nil
            case "screenshot":
                return nil
            default:
                return action.type
            }
        }
        return descriptions.isEmpty ? "Executing actions" : descriptions.joined(separator: ", ")
    }

    nonisolated private static func isPointerAction(_ type: String) -> Bool {
        switch type {
        case "click", "double_click", "move", "drag", "scroll":
            return true
        default:
            return false
        }
    }

    nonisolated private static func isKeyboardAction(_ type: String) -> Bool {
        switch type {
        case "type", "keypress":
            return true
        default:
            return false
        }
    }

    nonisolated private static func isLeadingMove(
        for move: ComputerUseAction,
        compatibleWith action: ComputerUseAction
    ) -> Bool {
        guard action.type != "move" else {
            return false
        }

        let tolerance = 1.0
        let moveMatches: (Double?, Double?) -> Bool = { x, y in
            guard let moveX = move.x, let moveY = move.y, let x, let y else {
                return false
            }
            return abs(moveX - x) <= tolerance && abs(moveY - y) <= tolerance
        }

        switch action.type {
        case "click", "double_click":
            return moveMatches(action.x, action.y)
        case "drag":
            guard let firstPoint = action.path?.first else {
                return false
            }
            return moveMatches(firstPoint.x, firstPoint.y)
        case "scroll":
            if action.x == nil && action.y == nil {
                return false
            }
            return moveMatches(action.x, action.y)
        default:
            return false
        }
    }

    nonisolated static func capturedWindowBoundsStillMatch(
        _ captured: WindowBounds,
        current: WindowBounds,
        tolerance: Double = 12
    ) -> Bool {
        let positionDelta = abs(captured.x - current.x) + abs(captured.y - current.y)
        let sizeDelta = abs(captured.width - current.width) + abs(captured.height - current.height)
        return positionDelta <= tolerance && sizeDelta <= tolerance
    }

    nonisolated private static func requiredCoordinate(_ value: Double?, name: String) throws -> Double {
        guard let value else {
            throw AppCoreError.invalidPayload("Computer use action is missing \(name).")
        }
        return value
    }

    nonisolated private static func mouseButton(from value: String?) -> InputMouseButton {
        switch value?.lowercased() {
        case "right":
            return .right
        case "middle", "center":
            return .middle
        default:
            return .left
        }
    }

    nonisolated private static func promptResolutionStatus(for action: AgentPromptResponseAction) -> AgentPromptResolutionStatus {
        switch action {
        case .submit:
            return .submitted
        case .accept:
            return .accepted
        case .decline:
            return .declined
        case .cancel:
            return .cancelled
        }
    }

    nonisolated private static func number(_ value: Any?, name: String) throws -> Double {
        if let value = value as? Double {
            return value
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        throw AppCoreError.invalidPayload("\(name) is required.")
    }
}
