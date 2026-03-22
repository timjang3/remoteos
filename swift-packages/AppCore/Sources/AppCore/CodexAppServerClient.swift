import Foundation

public final class CodexAppServerClientCallbacks: @unchecked Sendable {
    public var onCodexStatus: ((CodexStatusPayload) async -> Void)?
    public var onTurn: ((AgentTurnPayload) async -> Void)?
    public var onItem: ((AgentItemPayload) async -> Void)?
    public var onTrace: ((TraceEventPayload) async -> Void)?
    public var onThreadIDChanged: ((String?) async -> Void)?
    public var onPromptResolved: ((String) async -> Void)?
    public var promptHandler: ((AgentPromptPayload) async -> AgentPromptResponsePayload?)?
    public var toolHandler: ((DynamicToolInvocation, Data) async throws -> DynamicToolResult)?

    public init() {}
}

final class SerialAsyncCallbackQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        lock.lock()
        let previous = tail
        let task = Task {
            _ = await previous?.result
            guard !Task.isCancelled else {
                return
            }
            await operation()
        }
        tail = task
        lock.unlock()
    }
}

struct CodexRequestTimeoutPolicy: Sendable {
    func timeout(for method: String) -> Duration? {
        switch method {
        case "turn/start":
            return nil
        default:
            return .seconds(30)
        }
    }
}

final class CodexCallbackDispatcher: @unchecked Sendable {
    private let eventQueue = SerialAsyncCallbackQueue()
    private let traceQueue = SerialAsyncCallbackQueue()

    func enqueueEvent(_ operation: @escaping @Sendable () async -> Void) {
        eventQueue.enqueue(operation)
    }

    func enqueueTrace(_ operation: @escaping @Sendable () async -> Void) {
        traceQueue.enqueue(operation)
    }
}

final class BufferedJSONLFramer: @unchecked Sendable {
    private var buffer = Data()

    func append(_ data: Data) -> [String] {
        guard !data.isEmpty else {
            return []
        }

        buffer.append(data)
        return drain(flushTrailing: false)
    }

    func finish() -> [String] {
        drain(flushTrailing: true)
    }

    private func drain(flushTrailing: Bool) -> [String] {
        var lines: [String] = []

        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = Data(buffer[..<newlineIndex])
            buffer.removeSubrange(...newlineIndex)
            lines.append(decodeLine(lineData))
        }

        if flushTrailing, !buffer.isEmpty {
            let trailing = buffer
            buffer.removeAll(keepingCapacity: false)
            lines.append(decodeLine(trailing))
        }

        return lines
    }

    private func decodeLine(_ data: Data) -> String {
        var lineData = data
        if lineData.last == 0x0D {
            lineData.removeLast()
        }
        return String(decoding: lineData, as: UTF8.self)
    }
}

final class FileHandleJSONLReader: @unchecked Sendable {
    private let handle: FileHandle
    private let queue: DispatchQueue
    private let deliveryQueue = SerialAsyncCallbackQueue()
    private let framer = BufferedJSONLFramer()
    private let onLine: @Sendable (String) async -> Void
    private let onEnd: @Sendable () async -> Void
    private var finished = false
    private var cancelled = false

    init(
        handle: FileHandle,
        label: String,
        onLine: @escaping @Sendable (String) async -> Void,
        onEnd: @escaping @Sendable () async -> Void
    ) {
        self.handle = handle
        self.queue = DispatchQueue(label: "remoteos.codex.\(label)")
        self.onLine = onLine
        self.onEnd = onEnd
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.finished else {
                return
            }

            let queue = self.queue
            self.handle.readabilityHandler = { [weak self] readableHandle in
                queue.async { [weak self] in
                    self?.consume(readableHandle)
                }
            }
        }
    }

    func cancel() {
        queue.async { [weak self] in
            self?.finish(notifyEnd: false)
        }
    }

    private func consume(_ readableHandle: FileHandle) {
        guard !finished else {
            return
        }

        let data = readableHandle.availableData
        if data.isEmpty {
            finish(notifyEnd: !cancelled)
            return
        }

        for line in framer.append(data) {
            deliveryQueue.enqueue { [onLine] in
                await onLine(line)
            }
        }
    }

    private func finish(notifyEnd: Bool) {
        guard !finished else {
            return
        }

        finished = true
        cancelled = !notifyEnd
        handle.readabilityHandler = nil

        for line in framer.finish() {
            deliveryQueue.enqueue { [onLine] in
                await onLine(line)
            }
        }

        if notifyEnd {
            deliveryQueue.enqueue { [onEnd] in
                await onEnd()
            }
        }
    }
}

enum CodexReasoningEffort: String, CaseIterable, Sendable {
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh
}

struct CodexModelProfile: Sendable {
    let model: String
    let supportedReasoningEfforts: [CodexReasoningEffort]
    let defaultReasoningEffort: CodexReasoningEffort
    let supportsPersonality: Bool

    init(
        model: String,
        supportedReasoningEfforts: [CodexReasoningEffort],
        defaultReasoningEffort: CodexReasoningEffort,
        supportsPersonality: Bool
    ) {
        self.model = model
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.defaultReasoningEffort = Self.resolveSupportedReasoningEffort(
            supportedReasoningEfforts: supportedReasoningEfforts,
            preferred: defaultReasoningEffort,
            fallback: supportedReasoningEfforts.last
        ) ?? .medium
        self.supportsPersonality = supportsPersonality
    }

    func resolvedReasoningEffort() -> CodexReasoningEffort {
        Self.resolveSupportedReasoningEffort(
            supportedReasoningEfforts: supportedReasoningEfforts,
            preferred: defaultReasoningEffort,
            fallback: supportedReasoningEfforts.last
        ) ?? .medium
    }

    private static func resolveSupportedReasoningEffort(
        supportedReasoningEfforts: [CodexReasoningEffort],
        preferred: CodexReasoningEffort,
        fallback: CodexReasoningEffort?
    ) -> CodexReasoningEffort? {
        if supportedReasoningEfforts.contains(preferred) {
            return preferred
        }
        return fallback
    }

    static func builtinProfiles() -> [String: CodexModelProfile] {
        let profiles = [
            CodexModelProfile(
                model: "gpt-5.4",
                supportedReasoningEfforts: [.low, .medium, .high, .xhigh],
                defaultReasoningEffort: .medium,
                supportsPersonality: true
            ),
            CodexModelProfile(
                model: "gpt-5.4-mini",
                supportedReasoningEfforts: [.low, .medium, .high, .xhigh],
                defaultReasoningEffort: .medium,
                supportsPersonality: true
            ),
            CodexModelProfile(
                model: "gpt-5.3-codex",
                supportedReasoningEfforts: [.low, .medium, .high, .xhigh],
                defaultReasoningEffort: .medium,
                supportsPersonality: true
            ),
            CodexModelProfile(
                model: "gpt-5.3-codex-spark",
                supportedReasoningEfforts: [.low, .medium, .high, .xhigh],
                defaultReasoningEffort: .high,
                supportsPersonality: true
            ),
            CodexModelProfile(
                model: "gpt-5.2-codex",
                supportedReasoningEfforts: [.low, .medium, .high, .xhigh],
                defaultReasoningEffort: .medium,
                supportsPersonality: true
            ),
            CodexModelProfile(
                model: "gpt-5.2",
                supportedReasoningEfforts: [.low, .medium, .high, .xhigh],
                defaultReasoningEffort: .medium,
                supportsPersonality: false
            ),
            CodexModelProfile(
                model: "gpt-5.1-codex-max",
                supportedReasoningEfforts: [.low, .medium, .high, .xhigh],
                defaultReasoningEffort: .medium,
                supportsPersonality: false
            ),
            CodexModelProfile(
                model: "gpt-5.1-codex-mini",
                supportedReasoningEfforts: [.medium, .high],
                defaultReasoningEffort: .medium,
                supportsPersonality: false
            ),
            // Legacy Codex model aliases are still accepted by the local runtime but do not
            // advertise modern capabilities via `model/list`. Keep a compatibility profile so
            // host-managed sessions do not inherit invalid ambient settings.
            CodexModelProfile(
                model: "gpt-5-codex",
                supportedReasoningEfforts: [.low, .medium, .high],
                defaultReasoningEffort: .high,
                supportsPersonality: false
            )
        ]

        return Dictionary(uniqueKeysWithValues: profiles.map { ($0.model, $0) })
    }

    static func genericFallback(for model: String) -> CodexModelProfile {
        CodexModelProfile(
            model: model,
            supportedReasoningEfforts: [.medium],
            defaultReasoningEffort: .medium,
            supportsPersonality: false
        )
    }
}

struct CodexSessionConfiguration: Sendable {
    let model: String
    let cwd: String
    let approvalPolicy: String
    let sandboxMode: String
    let reasoningEffort: CodexReasoningEffort
    let personality: String?

    static func resolved(
        model: String,
        cwd: String,
        approvalPolicy: String,
        sandboxMode: String,
        profiles: [String: CodexModelProfile]
    ) -> CodexSessionConfiguration {
        let profile = profiles[model] ?? CodexModelProfile.genericFallback(for: model)
        return CodexSessionConfiguration(
            model: profile.model,
            cwd: cwd,
            approvalPolicy: approvalPolicy,
            sandboxMode: sandboxMode,
            reasoningEffort: profile.resolvedReasoningEffort(),
            personality: profile.supportsPersonality ? "pragmatic" : nil
        )
    }

    var sandboxPolicyParameters: [String: Any] {
        switch sandboxMode {
        case "danger-full-access":
            return ["type": "dangerFullAccess"]
        case "read-only":
            return ["type": "readOnly"]
        default:
            return ["type": "workspaceWrite"]
        }
    }
}

struct JSONRPCRequestID: Sendable, Hashable, CustomStringConvertible {
    private enum Storage: Sendable, Hashable {
        case string(String)
        case integer(Int64)
        case double(Double)
    }

    private let storage: Storage

    init?(rawValue: Any) {
        if let string = rawValue as? String {
            storage = .string(string)
            return
        }

        guard let number = rawValue as? NSNumber else {
            return nil
        }
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }

        let doubleValue = number.doubleValue
        let integerValue = number.int64Value
        if Double(integerValue) == doubleValue {
            storage = .integer(integerValue)
        } else {
            storage = .double(doubleValue)
        }
    }

    var jsonObject: Any {
        switch storage {
        case let .string(value):
            value
        case let .integer(value):
            value
        case let .double(value):
            value
        }
    }

    var kind: String {
        switch storage {
        case .string:
            "string"
        case .integer:
            "integer"
        case .double:
            "double"
        }
    }

    var description: String {
        switch storage {
        case let .string(value):
            value
        case let .integer(value):
            String(value)
        case let .double(value):
            String(value)
        }
    }
}

func jsonRPCResultPayload(id: JSONRPCRequestID, result: [String: Any]) -> [String: Any] {
    [
        "id": id.jsonObject,
        "result": result
    ]
}

func jsonRPCErrorPayload(id: JSONRPCRequestID, code: Int, message: String) -> [String: Any] {
    [
        "id": id.jsonObject,
        "error": [
            "code": code,
            "message": message
        ]
    ]
}

public actor CodexAppServerClient {
    public nonisolated let callbacks = CodexAppServerClientCallbacks()

    private let log = AppLogs.codex
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutReader: FileHandleJSONLReader?
    private var stderrReader: FileHandleJSONLReader?
    private var pendingResponses: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var responseTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var serverRequestTasks: [JSONRPCRequestID: Task<Void, Never>] = [:]
    private var serverRequestTurnIDs: [JSONRPCRequestID: String] = [:]
    private var resolvedServerRequestIDs: Set<JSONRPCRequestID> = []
    private var nextRequestID = 1
    private var prepareForTurnsTask: Task<CodexStatusPayload, Never>?
    private var processStartupTask: Task<Void, Error>?
    private var processInitialized = false
    private var currentThreadID: String?
    private var activeTurn: AgentTurnPayload?
    private var itemCache: [String: AgentItemPayload] = [:]
    private var lastEnvironmentRefreshAt: Date?
    private var environmentInstalled = false
    private var environmentAuthenticated = false
    private var environmentAuthMode: String?
    private var environmentLastError: String?
    private var lastStatus = CodexStatusPayload(
        state: .unknown,
        installed: false,
        authenticated: false,
        authMode: nil,
        model: nil,
        threadId: nil,
        activeTurnId: nil,
        lastError: nil
    )
    private let configurationProvider: @Sendable () -> HostConfiguration
    private let toolSpecsProvider: @Sendable () -> [[String: Any]]
    private let developerInstructionsProvider: @Sendable () -> String
    private let appServerCommandProvider: @Sendable () -> [String]
    private let commandRunner: (@Sendable ([String], Duration) async throws -> String)?
    private let processQueue = DispatchQueue(label: "remoteos.codex.appserver")
    private let callbackDispatcher = CodexCallbackDispatcher()
    private let requestTimeoutPolicy = CodexRequestTimeoutPolicy()
    private let cliCommandTimeout: Duration = .seconds(10)
    private let environmentRefreshInterval: TimeInterval = 30

    public init(
        configurationProvider: @escaping @Sendable () -> HostConfiguration,
        toolSpecsProvider: @escaping @Sendable () -> [[String: Any]],
        developerInstructionsProvider: @escaping @Sendable () -> String,
        appServerCommandProvider: @escaping @Sendable () -> [String] = {
            ["codex", "app-server", "--listen", "stdio://"]
        },
        commandRunner: (@Sendable ([String], Duration) async throws -> String)? = nil
    ) {
        self.configurationProvider = configurationProvider
        self.toolSpecsProvider = toolSpecsProvider
        self.developerInstructionsProvider = developerInstructionsProvider
        self.appServerCommandProvider = appServerCommandProvider
        self.commandRunner = commandRunner
    }

    public func refreshStatus(force: Bool = false) async -> CodexStatusPayload {
        let configuration = configurationProvider()
        let clock = ContinuousClock()
        let startedAt = clock.now
        log.info("Refreshing Codex environment status force=\(force) model=\(configuration.codexModel)")

        if !force,
           let lastEnvironmentRefreshAt,
           Date().timeIntervalSince(lastEnvironmentRefreshAt) < environmentRefreshInterval {
            let status = makeStatus(
                installed: environmentInstalled,
                authenticated: environmentAuthenticated,
                authMode: environmentAuthMode,
                lastError: environmentLastError,
                model: configuration.codexModel
            )
            updateStatus(status)
            log.debug("Using cached Codex environment status state=\(status.state.rawValue) lastError=\(status.lastError ?? "none")")
            return status
        }

        do {
            let cliClock = ContinuousClock()
            let cliStart = cliClock.now
            let version = try await runCLICommand(arguments: ["codex", "--version"]).trimmingCharacters(in: .whitespacesAndNewlines)
            log.info("Verified Codex CLI version=\(version) elapsed=\(logDuration(cliStart.duration(to: cliClock.now)))")
        } catch {
            lastEnvironmentRefreshAt = Date()
            environmentInstalled = false
            environmentAuthenticated = false
            environmentAuthMode = nil
            environmentLastError = "The `codex` CLI is not available on this Mac."
            let status = makeStatus(
                installed: environmentInstalled,
                authenticated: environmentAuthenticated,
                authMode: environmentAuthMode,
                lastError: environmentLastError,
                model: configuration.codexModel
            )
            updateStatus(status)
            log.error("Codex CLI unavailable elapsed=\(logDuration(startedAt.duration(to: clock.now))) error=\(error.localizedDescription)")
            return status
        }

        do {
            let authClock = ContinuousClock()
            let authStart = authClock.now
            let authOutput = try await runCLICommand(arguments: ["codex", "login", "status"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let authMode = authOutput.localizedCaseInsensitiveContains("chatgpt")
                ? "chatgpt"
                : (authOutput.localizedCaseInsensitiveContains("api") ? "api_key" : "unknown")
            lastEnvironmentRefreshAt = Date()
            environmentInstalled = true
            environmentAuthenticated = true
            environmentAuthMode = authMode
            environmentLastError = nil
            let status = makeStatus(
                installed: environmentInstalled,
                authenticated: environmentAuthenticated,
                authMode: environmentAuthMode,
                lastError: environmentLastError,
                model: configuration.codexModel
            )
            updateStatus(status)
            log.info("Codex environment ready authMode=\(authMode) elapsed=\(logDuration(startedAt.duration(to: clock.now))) authCheckElapsed=\(logDuration(authStart.duration(to: authClock.now)))")
            return status
        } catch {
            lastEnvironmentRefreshAt = Date()
            environmentInstalled = true
            environmentAuthenticated = false
            environmentAuthMode = nil
            environmentLastError = "Run `codex login` on this Mac before using the agent."
            let status = makeStatus(
                installed: environmentInstalled,
                authenticated: environmentAuthenticated,
                authMode: environmentAuthMode,
                lastError: environmentLastError,
                model: configuration.codexModel
            )
            updateStatus(status)
            log.error("Codex login status check failed elapsed=\(logDuration(startedAt.duration(to: clock.now))) error=\(error.localizedDescription)")
            return status
        }
    }

    public func prepareForTurns(forceStatusRefresh: Bool = false) async -> CodexStatusPayload {
        if let prepareForTurnsTask {
            log.debug("Joining in-flight prepareForTurns task forceStatusRefresh=\(forceStatusRefresh)")
            return await prepareForTurnsTask.value
        }

        let prepClock = ContinuousClock()
        let prepStart = prepClock.now
        log.info("Preparing Codex for turns forceStatusRefresh=\(forceStatusRefresh)")
        let task = Task { [weak self] in
            guard let self else {
                return CodexStatusPayload(
                    state: .error,
                    installed: false,
                    authenticated: false,
                    authMode: nil,
                    model: nil,
                    threadId: nil,
                    activeTurnId: nil,
                    lastError: AppCoreError.transportUnavailable.localizedDescription
                )
            }
            return await self.runPrepareForTurns(forceStatusRefresh: forceStatusRefresh)
        }
        prepareForTurnsTask = task
        let status = await task.value
        prepareForTurnsTask = nil
        log.info("prepareForTurns finished state=\(status.state.rawValue) threadId=\(status.threadId ?? "nil") activeTurnId=\(status.activeTurnId ?? "nil") elapsed=\(logDuration(prepStart.duration(to: prepClock.now)))")
        return status
    }

    private func runPrepareForTurns(forceStatusRefresh: Bool) async -> CodexStatusPayload {
        let configuration = configurationProvider()
        let readiness = await refreshStatus(force: forceStatusRefresh)
        guard readiness.installed, readiness.authenticated else {
            return readiness
        }

        do {
            try await ensureProcessStarted()
            try await ensureThreadReady()
            let status = makeStatus(
                installed: environmentInstalled,
                authenticated: environmentAuthenticated,
                authMode: environmentAuthMode,
                lastError: nil,
                model: configuration.codexModel
            )
            updateStatus(status)
            return status
        } catch {
            let status = CodexStatusPayload(
                state: .error,
                installed: environmentInstalled,
                authenticated: environmentAuthenticated,
                authMode: environmentAuthMode,
                model: configuration.codexModel,
                threadId: currentThreadID,
                activeTurnId: activeTurn?.id,
                lastError: error.localizedDescription
            )
            updateStatus(status)
            return status
        }
    }

    public func startTurn(prompt: String, targetWindowID: Int?) async throws -> AgentTurnPayload {
        let clock = ContinuousClock()
        let startedAt = clock.now
        log.info("Starting turn targetWindowID=\(targetWindowID.map(String.init) ?? "nil") promptPreview=\"\(logPreview(prompt, limit: 100))\"")
        let readiness = await prepareForTurns()
        guard readiness.installed, readiness.authenticated else {
            log.error("Cannot start turn because Codex is unavailable lastError=\(readiness.lastError ?? "none")")
            throw AppCoreError.codexUnavailable(readiness.lastError ?? "Codex is not ready.")
        }
        guard let currentThreadID else {
            throw AppCoreError.transportUnavailable
        }

        let sessionConfiguration = resolvedSessionConfiguration(for: configurationProvider().codexModel)
        let turnResponse = try await sendRequest(
            method: "turn/start",
            params: makeTurnStartParams(
                threadID: currentThreadID,
                prompt: prompt,
                targetWindowID: targetWindowID,
                sessionConfiguration: sessionConfiguration
            )
        )

        guard let turn = turnResponse["turn"] as? [String: Any], let turnID = turn["id"] as? String else {
            throw AppCoreError.invalidResponse
        }

        let payload = AgentTurnPayload(
            id: turnID,
            prompt: prompt,
            targetWindowId: targetWindowID,
            status: .running,
            error: nil,
            startedAt: isoNow(),
            updatedAt: isoNow(),
            completedAt: nil
        )
        activeTurn = payload
        deliverTurn(payload)

        let userTimestamp = isoNow()
        let userItem = AgentItemPayload.userMessage(turnID: turnID, prompt: prompt, timestamp: userTimestamp)
        itemCache[userItem.id] = userItem
        deliverItem(userItem)

        var status = lastStatus
        status.state = .running
        status.activeTurnId = turnID
        status.threadId = currentThreadID
        updateStatus(status)
        log.notice(
            "Turn started turnId=\(turnID) model=\(sessionConfiguration.model) effort=\(sessionConfiguration.reasoningEffort.rawValue) personality=\(sessionConfiguration.personality ?? "none") elapsed=\(logDuration(startedAt.duration(to: clock.now)))"
        )

        return payload
    }

    public func cancelTurn(turnID: String) async throws {
        guard let currentThreadID else {
            log.debug("Ignoring cancelTurn because no thread is active turnId=\(turnID)")
            return
        }
        log.info("Interrupting turn turnId=\(turnID) threadId=\(currentThreadID)")
        cancelServerRequestTasks(forTurnID: turnID)
        _ = try await sendRequest(
            method: "turn/interrupt",
            params: [
                "threadId": currentThreadID as Any,
                "turnId": turnID
            ]
        )
    }

    public func resetThread() async throws {
        log.info("Resetting Codex thread currentThreadId=\(currentThreadID ?? "nil")")
        currentThreadID = nil
        itemCache.removeAll()
        activeTurn = nil
        deliverThreadIDChanged(nil)

        var status = lastStatus
        status.threadId = nil
        status.activeTurnId = nil
        status.state = .ready
        updateStatus(status)

        try await ensureProcessStarted()
        try await ensureThreadReady(forceNewThread: true)
    }

    public func stop() {
        log.notice("Stopping Codex client processRunning=\(process?.isRunning == true) pendingResponses=\(pendingResponses.count)")
        stdoutReader?.cancel()
        stdoutReader = nil
        stderrReader?.cancel()
        stderrReader = nil
        serverRequestTasks.values.forEach { $0.cancel() }
        serverRequestTasks.removeAll()
        serverRequestTurnIDs.removeAll()
        resolvedServerRequestIDs.removeAll()
        responseTimeoutTasks.values.forEach { $0.cancel() }
        responseTimeoutTasks.removeAll()
        stdinHandle?.closeFile()
        if process?.isRunning == true {
            process?.terminate()
            process?.waitUntilExit()
        }
        process = nil
        stdinHandle = nil
        processInitialized = false
        processStartupTask = nil
        prepareForTurnsTask = nil
        currentThreadID = nil
        activeTurn = nil
        pendingResponses.values.forEach { $0.resume(throwing: AppCoreError.transportUnavailable) }
        pendingResponses.removeAll()
    }

    private func ensureProcessStarted() async throws {
        if processInitialized, process?.isRunning == true, stdinHandle != nil, stdoutReader != nil {
            log.debug("Codex process already initialized and ready")
            return
        }
        if let processStartupTask {
            log.debug("Joining in-flight Codex process startup")
            try await processStartupTask.value
            return
        }
        if process != nil || stdinHandle != nil || stdoutReader != nil || stderrReader != nil || processInitialized {
            log.warning("Detected inconsistent Codex transport state during startup recovery")
            await handleTransportFailure(message: "Codex transport became inconsistent.", terminateProcess: true)
        }

        let startupTask = Task { [weak self] in
            guard let self else {
                throw AppCoreError.transportUnavailable
            }
            try await self.startProcessAndInitialize()
        }
        processStartupTask = startupTask
        do {
            try await startupTask.value
        } catch {
            processStartupTask = nil
            throw error
        }
        processStartupTask = nil
    }

    private func startProcessAndInitialize() async throws {
        let configuration = configurationProvider()
        let clock = ContinuousClock()
        let startedAt = clock.now
        var startingStatus = lastStatus
        startingStatus.state = .starting
        startingStatus.model = configuration.codexModel
        startingStatus.lastError = nil
        updateStatus(startingStatus)

        let command = appServerCommandProvider()
        guard let executable = command.first else {
            throw AppCoreError.codexUnavailable("Missing Codex app-server command.")
        }
        log.info("Launching Codex app-server command=\(([executable] + Array(command.dropFirst())).joined(separator: " ")) model=\(configuration.codexModel)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + Array(command.dropFirst())

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { [weak self] terminatedProcess in
            Task {
                await self?.handleProcessTermination(terminatedProcess)
            }
        }

        try process.run()
        self.process = process
        self.stdinHandle = stdin.fileHandleForWriting
        log.notice("Codex app-server launched pid=\(process.processIdentifier)")

        let stdoutReader = FileHandleJSONLReader(
            handle: stdout.fileHandleForReading,
            label: "stdout",
            onLine: { [weak self] line in
                await self?.handleServerLine(line)
            },
            onEnd: { [weak self] in
                guard let self else {
                    return
                }
                self.log.error("Codex stdout closed unexpectedly")
                await self.handleTransportFailure(message: "Codex stdout closed unexpectedly.", terminateProcess: false)
            }
        )
        stdoutReader.start()
        self.stdoutReader = stdoutReader

        let stderrReader = FileHandleJSONLReader(
            handle: stderr.fileHandleForReading,
            label: "stderr",
            onLine: { [weak self] line in
                guard let self else {
                    return
                }
                self.log.warning("Codex stderr: \(line)")
                await self.emitTrace(level: "warning", kind: "codex_stderr", message: line)
            },
            onEnd: {}
        )
        stderrReader.start()
        self.stderrReader = stderrReader

        do {
            let initClock = ContinuousClock()
            let initStart = initClock.now
            _ = try await sendRequest(
                method: "initialize",
                params: [
                    "clientInfo": [
                        "name": "remoteos-host",
                        "version": "0.1.0"
                    ],
                    "capabilities": [
                        "experimentalApi": true
                    ]
                ]
            )
            try await sendNotification(method: "initialized", params: [:])
            processInitialized = true
            log.notice("Codex app-server initialized elapsed=\(logDuration(initStart.duration(to: initClock.now))) totalStartupElapsed=\(logDuration(startedAt.duration(to: clock.now)))")
        } catch {
            await handleTransportFailure(message: error.localizedDescription, terminateProcess: true)
            throw error
        }
    }

    private func ensureThreadReady(forceNewThread: Bool = false) async throws {
        if currentThreadID != nil, !forceNewThread {
            log.debug("Reusing existing Codex thread threadId=\(currentThreadID ?? "nil")")
            return
        }

        try await ensureProcessStarted()
        let clock = ContinuousClock()
        let startedAt = clock.now
        currentThreadID = nil
        let configuration = configurationProvider()
        let sessionConfiguration = resolvedSessionConfiguration(for: configuration.codexModel)
        var params: [String: Any] = [
            "cwd": sessionConfiguration.cwd,
            "approvalPolicy": sessionConfiguration.approvalPolicy,
            "sandbox": sessionConfiguration.sandboxMode,
            "model": sessionConfiguration.model,
            "developerInstructions": developerInstructionsProvider(),
            "persistExtendedHistory": true,
            "dynamicTools": toolSpecsProvider()
        ]
        if let personality = sessionConfiguration.personality {
            params["personality"] = personality
        }
        let response = try await sendRequest(
            method: "thread/start",
            params: params
        )

        guard let thread = response["thread"] as? [String: Any], let threadID = thread["id"] as? String else {
            throw AppCoreError.invalidResponse
        }

        currentThreadID = threadID
        deliverThreadIDChanged(threadID)

        var status = lastStatus
        status.threadId = threadID
        status.model = configuration.codexModel
        status.state = .ready
        updateStatus(status)
        log.notice(
            "Codex thread ready threadId=\(threadID) forceNewThread=\(forceNewThread) model=\(sessionConfiguration.model) effort=\(sessionConfiguration.reasoningEffort.rawValue) personality=\(sessionConfiguration.personality ?? "none") elapsed=\(logDuration(startedAt.duration(to: clock.now)))"
        )
    }

    private func makeStatus(
        installed: Bool,
        authenticated: Bool,
        authMode: String?,
        lastError: String?,
        model: String?
    ) -> CodexStatusPayload {
        let state: CodexRuntimeState
        if !installed {
            state = .missingCLI
        } else if !authenticated {
            state = .unauthenticated
        } else if activeTurn != nil {
            state = .running
        } else if process?.isRunning == true, stdinHandle != nil, stdoutReader != nil, currentThreadID != nil {
            state = .ready
        } else {
            state = .starting
        }

        return CodexStatusPayload(
            state: state,
            installed: installed,
            authenticated: authenticated,
            authMode: authMode,
            model: model,
            threadId: currentThreadID,
            activeTurnId: activeTurn?.id,
            lastError: lastError
        )
    }

    private func buildTurnPrompt(userPrompt: String, targetWindowID: Int?) -> String {
        if let targetWindowID {
            return """
            Selected window id: \(targetWindowID)
            Use RemoteOS dynamic tools only for macOS window interaction. Use built-in shell and file tools for all other work.

            User request:
            \(userPrompt)
            """
        }

        return """
        No window is currently selected. Use built-in shell and file tools unless you need to inspect or switch windows.

        User request:
        \(userPrompt)
        """
    }

    private func resolvedSessionConfiguration(for model: String) -> CodexSessionConfiguration {
        CodexSessionConfiguration.resolved(
            model: model,
            cwd: NSHomeDirectory(),
            approvalPolicy: "never",
            sandboxMode: "danger-full-access",
            profiles: CodexModelProfile.builtinProfiles()
        )
    }

    private func makeTurnStartParams(
        threadID: String,
        prompt: String,
        targetWindowID: Int?,
        sessionConfiguration: CodexSessionConfiguration
    ) -> [String: Any] {
        var params: [String: Any] = [
            "threadId": threadID,
            "model": sessionConfiguration.model,
            "effort": sessionConfiguration.reasoningEffort.rawValue,
            "approvalPolicy": sessionConfiguration.approvalPolicy,
            "cwd": sessionConfiguration.cwd,
            "sandboxPolicy": sessionConfiguration.sandboxPolicyParameters,
            "input": [
                [
                    "type": "text",
                    "text": buildTurnPrompt(userPrompt: prompt, targetWindowID: targetWindowID)
                ]
            ]
        ]
        if let personality = sessionConfiguration.personality {
            params["personality"] = personality
        }
        return params
    }

    private func sendNotification(method: String, params: [String: Any]) async throws {
        guard let stdinHandle else {
            throw AppCoreError.transportUnavailable
        }
        log.debug("Sending Codex notification method=\(method)")
        let payload: [String: Any] = [
            "method": method,
            "params": params
        ]
        let data = try dataFromJSONObject(payload)
        processQueue.sync {
            stdinHandle.write(data)
            stdinHandle.write(Data([0x0A]))
        }
    }

    private func sendRequest(method: String, params: [String: Any]) async throws -> [String: Any] {
        let requestID = "\(nextRequestID)"
        nextRequestID += 1
        let requestTimeout = requestTimeout(for: method)
        let timeoutDescription = if let requestTimeout {
            logDuration(requestTimeout)
        } else {
            "none"
        }
        log.debug("Sending Codex request id=\(requestID) method=\(method) timeout=\(timeoutDescription)")

        return try await withCheckedThrowingContinuation { continuation in
            pendingResponses[requestID] = continuation

            if let timeout = requestTimeout {
                responseTimeoutTasks[requestID] = Task { [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(for: timeout)
                    await self.handlePendingResponseTimeout(requestID: requestID, method: method)
                }
            }

            do {
                guard let stdinHandle = self.stdinHandle else {
                    throw AppCoreError.transportUnavailable
                }
                let payload: [String: Any] = [
                    "id": requestID,
                    "method": method,
                    "params": params
                ]
                let data = try dataFromJSONObject(payload)
                self.processQueue.sync {
                    stdinHandle.write(data)
                    stdinHandle.write(Data([0x0A]))
                }
                self.log.debug("Codex request dispatched id=\(requestID) method=\(method)")
            } catch {
                self.log.error("Failed to dispatch Codex request id=\(requestID) method=\(method) error=\(error.localizedDescription)")
                self.responseTimeoutTasks.removeValue(forKey: requestID)?.cancel()
                continuation.resume(throwing: error)
                self.pendingResponses.removeValue(forKey: requestID)
            }
        }
    }

    private func requestTimeout(for method: String) -> Duration? {
        requestTimeoutPolicy.timeout(for: method)
    }

    private func handleServerLine(_ line: String) async {
        guard let data = line.data(using: .utf8) else {
            return
        }

        do {
            let payload = try anyDictionary(from: data)

            if let idValue = payload["id"] {
                if let method = payload["method"] as? String {
                    guard let requestID = JSONRPCRequestID(rawValue: idValue) else {
                        log.error("Received Codex server request with unsupported id type method=\(method)")
                        return
                    }
                    log.debug("Received Codex server request id=\(requestID.description) idType=\(requestID.kind) method=\(method)")
                    try await handleServerRequest(
                        requestID: requestID,
                        method: method,
                        params: stringDictionary(payload["params"])
                    )
                    return
                }

                let id = String(describing: idValue)

                if let errorPayload = payload["error"] as? [String: Any] {
                    let message = errorPayload["message"] as? String ?? "Unknown Codex transport error"
                    log.error("Received Codex error response id=\(id) message=\(message)")
                    responseTimeoutTasks.removeValue(forKey: id)?.cancel()
                    pendingResponses.removeValue(forKey: id)?.resume(throwing: AppCoreError.invalidPayload(message))
                    return
                }

                responseTimeoutTasks.removeValue(forKey: id)?.cancel()
                log.debug("Received Codex response id=\(id)")
                if let result = payload["result"] as? [String: Any] {
                    pendingResponses.removeValue(forKey: id)?.resume(returning: result)
                } else {
                    pendingResponses.removeValue(forKey: id)?.resume(returning: [:])
                }
                return
            }

            guard let method = payload["method"] as? String else {
                return
            }
            log.debug("Received Codex notification method=\(method)")
            let params = stringDictionary(payload["params"])
            try await handleNotification(method: method, params: params)
        } catch {
            log.error("Failed to decode Codex server line error=\(error.localizedDescription)")
            await emitTrace(level: "error", kind: "codex_decode", message: error.localizedDescription)
        }
    }

    private func handleNotification(method: String, params: [String: Any]) async throws {
        switch method {
        case "turn/started":
            guard let turn = params["turn"] as? [String: Any], let turnID = turn["id"] as? String else {
                return
            }
            var payload = activeTurn ?? AgentTurnPayload(
                id: turnID,
                prompt: "",
                targetWindowId: nil,
                status: .running,
                error: nil,
                startedAt: isoNow(),
                updatedAt: isoNow(),
                completedAt: nil
            )
            payload.id = turnID
            payload.status = .running
            payload.updatedAt = isoNow()
            activeTurn = payload
            deliverTurn(payload)

            var status = lastStatus
            status.state = .running
            status.activeTurnId = turnID
            updateStatus(status)
        case "turn/completed":
            guard let turn = params["turn"] as? [String: Any], let turnID = turn["id"] as? String else {
                return
            }
            cancelServerRequestTasks(forTurnID: turnID)
            let statusRaw = (turn["status"] as? String) ?? "completed"
            let turnStatus: AgentTurnStatus
            switch statusRaw {
            case "completed":
                turnStatus = .completed
            case "interrupted":
                turnStatus = .interrupted
            case "failed":
                turnStatus = .failed
            default:
                turnStatus = .completed
            }

            var payload = activeTurn ?? AgentTurnPayload(
                id: turnID,
                prompt: "",
                targetWindowId: nil,
                status: turnStatus,
                error: nil,
                startedAt: isoNow(),
                updatedAt: isoNow(),
                completedAt: isoNow()
            )
            payload.id = turnID
            payload.status = turnStatus
            payload.updatedAt = isoNow()
            payload.completedAt = isoNow()
            if let errorInfo = turn["error"] as? [String: Any] {
                payload.error = errorInfo["message"] as? String
            }
            activeTurn = nil
            deliverTurn(payload)

            var status = lastStatus
            status.state = .ready
            status.activeTurnId = nil
            status.lastError = payload.error
            updateStatus(status)
        case "item/started", "item/completed":
            guard
                let item = params["item"] as? [String: Any],
                let turnID = params["turnId"] as? String,
                var payload = makeAgentItem(
                    from: item,
                    turnID: turnID,
                    defaultStatus: method == "item/started" ? .inProgress : .completed
                )
            else {
                return
            }

            if let cached = itemCache[payload.id] {
                payload.createdAt = cached.createdAt
                if payload.body?.isEmpty != false, cached.body?.isEmpty == false {
                    payload.body = cached.body
                }
                for (key, value) in cached.metadata where payload.metadata[key] == nil {
                    payload.metadata[key] = value
                }
            }

            itemCache[payload.id] = payload
            deliverItem(payload)
        case "item/agentMessage/delta":
            guard
                let itemID = params["itemId"] as? String,
                let delta = params["delta"] as? String,
                var payload = itemCache[itemID]
            else {
                return
            }
            payload.body = (payload.body ?? "") + delta
            payload.updatedAt = isoNow()
            itemCache[itemID] = payload
            deliverItem(payload)
        case "item/plan/delta":
            guard
                let itemID = params["itemId"] as? String,
                let delta = params["delta"] as? String
            else {
                return
            }
            appendItemBodyDelta(itemID: itemID, delta: delta)
        case "item/commandExecution/outputDelta":
            guard
                let itemID = params["itemId"] as? String,
                let delta = params["delta"] as? String,
                var payload = itemCache[itemID]
            else {
                return
            }
            payload.body = (payload.body ?? "") + delta
            payload.updatedAt = isoNow()
            itemCache[itemID] = payload
            deliverItem(payload)
        case "item/fileChange/outputDelta":
            guard
                let itemID = params["itemId"] as? String,
                let delta = params["delta"] as? String
            else {
                return
            }
            appendItemBodyDelta(itemID: itemID, delta: delta)
        case "item/mcpToolCall/progress":
            guard
                let itemID = params["itemId"] as? String,
                let message = params["message"] as? String
            else {
                return
            }
            appendItemMessageLine(itemID: itemID, message: message)
        case "item/reasoning/summaryPartAdded":
            guard
                let itemID = params["itemId"] as? String,
                let summaryIndex = params["summaryIndex"] as? Int
            else {
                return
            }
            beginReasoningSummaryPart(itemID: itemID, summaryIndex: summaryIndex)
        case "item/reasoning/summaryTextDelta":
            guard
                let itemID = params["itemId"] as? String,
                let delta = params["delta"] as? String,
                let summaryIndex = params["summaryIndex"] as? Int
            else {
                return
            }
            appendReasoningSummaryDelta(itemID: itemID, delta: delta, summaryIndex: summaryIndex)
        case "item/reasoning/textDelta":
            guard
                let itemID = params["itemId"] as? String,
                let delta = params["delta"] as? String
            else {
                return
            }
            appendReasoningContentDelta(itemID: itemID, delta: delta)
        case "serverRequest/resolved":
            guard
                let rawRequestID = params["requestId"],
                let requestID = JSONRPCRequestID(rawValue: rawRequestID)
            else {
                return
            }
            resolvedServerRequestIDs.insert(requestID)
            log.debug("Received Codex serverRequest/resolved requestId=\(requestID.description) idType=\(requestID.kind)")
            await callbacks.onPromptResolved?(requestID.description)
        case "error":
            let message = ((params["error"] as? [String: Any])?["message"] as? String) ?? "Codex turn failed."
            var status = lastStatus
            status.state = .error
            status.lastError = message
            updateStatus(status)
            await emitTrace(level: "error", kind: "codex_turn", message: message)
        default:
            break
        }
    }

    private func handleServerRequest(requestID: JSONRPCRequestID, method: String, params: [String: Any]) async throws {
        switch method {
        case "item/tool/call":
            let paramsData = try dataFromJSONObject(params)
            startServerRequestTask(requestID: requestID, turnID: params["turnId"] as? String) { client in
                try await client.handleToolCall(requestID: requestID, paramsData: paramsData)
            }
        case "item/tool/requestUserInput":
            let paramsData = try dataFromJSONObject(params)
            startServerRequestTask(requestID: requestID, turnID: params["turnId"] as? String) { client in
                try await client.handleToolRequestUserInput(requestID: requestID, paramsData: paramsData)
            }
        case "item/commandExecution/requestApproval",
            "item/fileChange/requestApproval",
            "mcpServer/elicitation/request",
            "account/chatgptAuthTokens/refresh":
            log.warning("Rejecting unsupported Codex server request id=\(requestID) method=\(method)")
            await emitTrace(level: "warning", kind: "codex_server_request", message: "Unsupported server request \(method)")
            try await sendErrorResponse(
                id: requestID,
                code: -32601,
                message: "RemoteOSHost does not support \(method)."
            )
        default:
            log.warning("Rejecting unknown Codex server request id=\(requestID) method=\(method)")
            try await sendErrorResponse(
                id: requestID,
                code: -32601,
                message: "Unsupported server request \(method)."
            )
        }
    }

    private func startServerRequestTask(
        requestID: JSONRPCRequestID,
        turnID: String? = nil,
        operation: @escaping @Sendable (CodexAppServerClient) async throws -> Void
    ) {
        serverRequestTasks[requestID]?.cancel()
        if let turnID {
            serverRequestTurnIDs[requestID] = turnID
        } else {
            serverRequestTurnIDs.removeValue(forKey: requestID)
        }
        serverRequestTasks[requestID] = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                Task {
                    await self.finishServerRequestTask(requestID: requestID)
                }
            }
            do {
                try await operation(self)
            } catch is CancellationError {
                await self.emitTrace(
                    level: "warning",
                    kind: "codex_server_request",
                    message: "Server request \(requestID) was cancelled."
                )
            } catch {
                await self.emitTrace(
                    level: "warning",
                    kind: "codex_server_request",
                    message: error.localizedDescription
                )
                try? await self.sendErrorResponse(
                    id: requestID,
                    code: -32000,
                    message: error.localizedDescription
                )
            }
        }
    }

    private func finishServerRequestTask(requestID: JSONRPCRequestID) {
        serverRequestTasks.removeValue(forKey: requestID)
        serverRequestTurnIDs.removeValue(forKey: requestID)
        resolvedServerRequestIDs.remove(requestID)
    }

    private func cancelServerRequestTasks(forTurnID turnID: String) {
        let requestIDs = serverRequestTurnIDs.compactMap { requestID, mappedTurnID in
            mappedTurnID == turnID ? requestID : nil
        }
        for requestID in requestIDs {
            serverRequestTasks[requestID]?.cancel()
            serverRequestTasks.removeValue(forKey: requestID)
            serverRequestTurnIDs.removeValue(forKey: requestID)
        }
    }

    private func handleToolCall(requestID: JSONRPCRequestID, paramsData: Data) async throws {
        let params = try anyDictionary(from: paramsData)
        guard
            let threadID = params["threadId"] as? String,
            let turnID = params["turnId"] as? String,
            let callID = params["callId"] as? String,
            let tool = params["tool"] as? String,
            let arguments = params["arguments"] as? [String: Any]
        else {
            try await sendToolCallResponse(
                id: requestID,
                result: DynamicToolResult(
                    contentItems: [.init(type: .inputText("Tool arguments were invalid."))],
                    success: false
                )
            )
            return
        }

        do {
            let argumentData = try dataFromJSONObject(arguments)
            log.info("Executing Codex dynamic tool tool=\(tool) requestId=\(requestID.description) idType=\(requestID.kind)")
            let invocation = DynamicToolInvocation(
                requestId: requestID.description,
                threadId: threadID,
                turnId: turnID,
                callId: callID,
                tool: tool
            )
            let result = try await callbacks.toolHandler?(invocation, argumentData) ?? DynamicToolResult(
                contentItems: [.init(type: .inputText("No handler was registered for \(tool)."))],
                success: false
            )
            try Task.checkCancellation()
            guard !resolvedServerRequestIDs.contains(requestID) else {
                log.debug("Skipping Codex dynamic tool response because request already resolved requestId=\(requestID.description)")
                return
            }
            try await sendToolCallResponse(id: requestID, result: result)
            log.debug("Completed Codex dynamic tool tool=\(tool) requestId=\(requestID.description) success=\(result.success)")
        } catch {
            log.error("Codex dynamic tool failed tool=\(tool) requestId=\(requestID.description) error=\(error.localizedDescription)")
            let result = DynamicToolResult(
                contentItems: [.init(type: .inputText(error.localizedDescription))],
                success: false
            )
            try await sendToolCallResponse(id: requestID, result: result)
        }
    }

    private func handleToolRequestUserInput(requestID: JSONRPCRequestID, paramsData: Data) async throws {
        let params = try anyDictionary(from: paramsData)
        guard
            let turnID = params["turnId"] as? String,
            let questions = (params["questions"] as? [[String: Any]])?.compactMap(promptQuestion(from:))
        else {
            throw AppCoreError.invalidPayload("Codex request_user_input payload was invalid.")
        }

        let prompt = AgentPromptPayload(
            id: requestID.description,
            turnId: turnID,
            source: .codex,
            kind: .requestUserInput,
            title: "Codex needs input",
            body: "Answer the tool questions to continue.",
            questions: questions,
            choices: nil,
            createdAt: isoNow(),
            updatedAt: isoNow()
        )

        let response = await callbacks.promptHandler?(prompt)
        try Task.checkCancellation()
        if resolvedServerRequestIDs.contains(requestID) {
            return
        }

        let answers = response?.answers ?? [:]
        try await sendToolRequestUserInputResponse(id: requestID, answers: answers)
        log.debug("Resolved Codex request_user_input requestId=\(requestID.description) answers=\(answers.count)")
    }

    private func promptQuestion(from value: [String: Any]) -> AgentPromptQuestionPayload? {
        guard
            let id = value["id"] as? String,
            let header = value["header"] as? String,
            let question = value["question"] as? String
        else {
            return nil
        }
        let options = (value["options"] as? [[String: Any]])?.compactMap { option -> AgentPromptOptionPayload? in
            guard
                let label = option["label"] as? String,
                let description = option["description"] as? String
            else {
                return nil
            }
            return AgentPromptOptionPayload(label: label, description: description)
        }

        return AgentPromptQuestionPayload(
            id: id,
            header: header,
            question: question,
            isOther: value["isOther"] as? Bool ?? false,
            isSecret: value["isSecret"] as? Bool ?? false,
            options: options
        )
    }

    private func sendToolRequestUserInputResponse(
        id: JSONRPCRequestID,
        answers: [String: AgentPromptAnswerPayload]
    ) async throws {
        guard let stdinHandle else {
            throw AppCoreError.transportUnavailable
        }

        let payload = jsonRPCResultPayload(
            id: id,
            result: [
                "answers": answers.mapValues { answer in
                    [
                        "answers": answer.answers
                    ]
                }
            ]
        )
        let data = try dataFromJSONObject(payload)
        processQueue.sync {
            stdinHandle.write(data)
            stdinHandle.write(Data([0x0A]))
        }
    }

    private func sendToolCallResponse(id: JSONRPCRequestID, result: DynamicToolResult) async throws {
        guard let stdinHandle else {
            throw AppCoreError.transportUnavailable
        }
        let contentItems: [[String: Any]] = result.contentItems.map { item in
            switch item.type {
            case let .inputText(text):
                return [
                    "type": "inputText",
                    "text": text
                ]
            case let .inputImage(imageURL):
                return [
                    "type": "inputImage",
                    "imageUrl": imageURL
                ]
            }
        }

        let payload = jsonRPCResultPayload(
            id: id,
            result: [
                "contentItems": contentItems,
                "success": result.success
            ]
        )
        log.debug(
            "Sending Codex dynamic tool response requestId=\(id.description) idType=\(id.kind) success=\(result.success) contentItems=\(contentItems.count)"
        )
        let data = try dataFromJSONObject(payload)
        processQueue.sync {
            stdinHandle.write(data)
            stdinHandle.write(Data([0x0A]))
        }
    }

    private func sendErrorResponse(id: JSONRPCRequestID, code: Int, message: String) async throws {
        guard let stdinHandle else {
            throw AppCoreError.transportUnavailable
        }

        let payload = jsonRPCErrorPayload(id: id, code: code, message: message)
        let data = try dataFromJSONObject(payload)
        processQueue.sync {
            stdinHandle.write(data)
            stdinHandle.write(Data([0x0A]))
        }
    }

    private func updateStatus(_ status: CodexStatusPayload) {
        lastStatus = status
        let callbacks = callbacks
        callbackDispatcher.enqueueEvent { [callbacks] in
            await callbacks.onCodexStatus?(status)
        }
    }

    private func deliverTurn(_ payload: AgentTurnPayload) {
        let callbacks = callbacks
        callbackDispatcher.enqueueEvent { [callbacks] in
            await callbacks.onTurn?(payload)
        }
    }

    private func deliverItem(_ payload: AgentItemPayload) {
        let callbacks = callbacks
        callbackDispatcher.enqueueEvent { [callbacks] in
            await callbacks.onItem?(payload)
        }
    }

    private func deliverThreadIDChanged(_ threadID: String?) {
        let callbacks = callbacks
        callbackDispatcher.enqueueEvent { [callbacks] in
            await callbacks.onThreadIDChanged?(threadID)
        }
    }

    private func emitTrace(level: String, kind: String, message: String) async {
        let event = TraceEventPayload(
            id: UUID().uuidString,
            taskId: activeTurn?.id,
            level: level,
            kind: kind,
            message: message,
            createdAt: isoNow(),
            metadata: [:]
        )
        let callbacks = callbacks
        callbackDispatcher.enqueueTrace { [callbacks] in
            await callbacks.onTrace?(event)
        }
    }

    private func handlePendingResponseTimeout(requestID: String, method: String) async {
        guard let continuation = pendingResponses.removeValue(forKey: requestID) else {
            responseTimeoutTasks.removeValue(forKey: requestID)?.cancel()
            return
        }

        responseTimeoutTasks.removeValue(forKey: requestID)?.cancel()
        let message = "Codex request \(method) timed out."
        log.error("Codex request timeout id=\(requestID) method=\(method)")
        continuation.resume(throwing: AppCoreError.codexUnavailable(message))
        await emitTrace(level: "warning", kind: "codex_timeout", message: message)
    }

    private func handleProcessTermination(_ terminatedProcess: Process) async {
        guard process === terminatedProcess else {
            return
        }

        let message: String
        switch terminatedProcess.terminationReason {
        case .exit where terminatedProcess.terminationStatus == 0:
            message = "Codex app-server exited."
        case .exit:
            message = "Codex app-server exited with status \(terminatedProcess.terminationStatus)."
        case .uncaughtSignal:
            message = "Codex app-server crashed with signal \(terminatedProcess.terminationStatus)."
        @unknown default:
            message = "Codex app-server terminated unexpectedly."
        }

        await handleTransportFailure(message: message, terminateProcess: false)
    }

    private func handleTransportFailure(message: String, terminateProcess: Bool) async {
        log.error("Handling Codex transport failure terminateProcess=\(terminateProcess) message=\(message)")
        let hadLiveTransport = process != nil || stdinHandle != nil || !pendingResponses.isEmpty || currentThreadID != nil || activeTurn != nil
        guard hadLiveTransport else {
            return
        }

        responseTimeoutTasks.values.forEach { $0.cancel() }
        responseTimeoutTasks.removeAll()
        serverRequestTasks.values.forEach { $0.cancel() }
        serverRequestTasks.removeAll()
        serverRequestTurnIDs.removeAll()
        resolvedServerRequestIDs.removeAll()

        let pending = pendingResponses.values
        pendingResponses.removeAll()
        for continuation in pending {
            continuation.resume(throwing: AppCoreError.codexUnavailable(message))
        }

        stdoutReader?.cancel()
        stdoutReader = nil
        stderrReader?.cancel()
        stderrReader = nil

        if terminateProcess, process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        stdinHandle = nil

        if currentThreadID != nil {
            currentThreadID = nil
            deliverThreadIDChanged(nil)
        }

        processInitialized = false
        processStartupTask = nil
        prepareForTurnsTask = nil

        if var activeTurn {
            activeTurn.status = .failed
            activeTurn.error = message
            activeTurn.updatedAt = isoNow()
            activeTurn.completedAt = isoNow()
            self.activeTurn = nil
            deliverTurn(activeTurn)
        }

        var status = lastStatus
        status.state = .error
        status.threadId = nil
        status.activeTurnId = nil
        status.lastError = message
        updateStatus(status)
        await emitTrace(level: "error", kind: "codex_transport", message: message)
    }

    private func appendItemBodyDelta(itemID: String, delta: String) {
        guard var payload = itemCache[itemID] else {
            return
        }
        payload.body = (payload.body ?? "") + delta
        payload.updatedAt = isoNow()
        itemCache[itemID] = payload
        deliverItem(payload)
    }

    private func appendItemMessageLine(itemID: String, message: String) {
        guard var payload = itemCache[itemID] else {
            return
        }
        if let body = payload.body, !body.isEmpty {
            payload.body = body + (body.hasSuffix("\n") ? "" : "\n") + message
        } else {
            payload.body = message
        }
        payload.updatedAt = isoNow()
        itemCache[itemID] = payload
        deliverItem(payload)
    }

    private func beginReasoningSummaryPart(itemID: String, summaryIndex: Int) {
        guard var payload = itemCache[itemID], payload.kind == .reasoning else {
            return
        }
        payload.metadata["reasoningSource"] = "summary"
        payload.metadata["reasoningSummaryIndex"] = String(summaryIndex)
        if let body = payload.body, !body.isEmpty, summaryIndex > 0, !body.hasSuffix("\n\n") {
            payload.body = body + "\n\n"
        }
        payload.updatedAt = isoNow()
        itemCache[itemID] = payload
        deliverItem(payload)
    }

    private func appendReasoningSummaryDelta(itemID: String, delta: String, summaryIndex: Int) {
        guard var payload = itemCache[itemID], payload.kind == .reasoning else {
            return
        }
        let previousIndex = Int(payload.metadata["reasoningSummaryIndex"] ?? "") ?? -1
        if payload.metadata["reasoningSource"] != "summary" {
            payload.body = nil
        }
        payload.metadata["reasoningSource"] = "summary"
        if summaryIndex > max(previousIndex, 0), let body = payload.body, !body.isEmpty, !body.hasSuffix("\n\n") {
            payload.body = body + "\n\n"
        }
        payload.metadata["reasoningSummaryIndex"] = String(summaryIndex)
        payload.body = (payload.body ?? "") + delta
        payload.updatedAt = isoNow()
        itemCache[itemID] = payload
        deliverItem(payload)
    }

    private func appendReasoningContentDelta(itemID: String, delta: String) {
        guard var payload = itemCache[itemID], payload.kind == .reasoning else {
            return
        }
        if payload.metadata["reasoningSource"] == "summary" {
            return
        }
        payload.metadata["reasoningSource"] = "content"
        payload.body = (payload.body ?? "") + delta
        payload.updatedAt = isoNow()
        itemCache[itemID] = payload
        deliverItem(payload)
    }

    private func makeAgentItem(
        from item: [String: Any],
        turnID: String,
        defaultStatus: AgentItemStatus
    ) -> AgentItemPayload? {
        guard let id = item["id"] as? String, let type = item["type"] as? String else {
            return nil
        }

        let now = isoNow()
        let createdAt = itemCache[id]?.createdAt ?? now
        let updatedAt = now
        let status = completionStatus(from: item, fallback: defaultStatus)

        switch type {
        case "userMessage":
            return nil
        case "agentMessage":
            let text = item["text"] as? String
            var metadata: [String: String] = [:]
            if let phase = item["phase"] as? String, !phase.isEmpty {
                metadata["phase"] = phase
            }
            return AgentItemPayload(
                id: id,
                turnId: turnID,
                kind: .assistantMessage,
                status: status,
                title: "Codex",
                body: text,
                createdAt: createdAt,
                updatedAt: updatedAt,
                metadata: metadata
            )
        case "reasoning":
            let summary = (item["summary"] as? [String])?
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let content = (item["content"] as? [String])?
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let bodySource = (summary?.isEmpty == false) ? "summary" : ((content?.isEmpty == false) ? "content" : nil)
            return AgentItemPayload(
                id: id,
                turnId: turnID,
                kind: .reasoning,
                status: status,
                title: "Reasoning",
                body: (summary?.isEmpty == false ? summary!.joined(separator: "\n\n") : content?.joined(separator: "\n\n")),
                createdAt: createdAt,
                updatedAt: updatedAt,
                metadata: bodySource.map { ["reasoningSource": $0] } ?? [:]
            )
        case "plan":
            return AgentItemPayload(
                id: id,
                turnId: turnID,
                kind: .plan,
                status: status,
                title: "Plan",
                body: item["text"] as? String,
                createdAt: createdAt,
                updatedAt: updatedAt,
                metadata: [:]
            )
        case "commandExecution":
            let command = item["command"] as? String ?? "Shell command"
            return AgentItemPayload(
                id: id,
                turnId: turnID,
                kind: .command,
                status: status,
                title: command,
                body: item["aggregatedOutput"] as? String,
                createdAt: createdAt,
                updatedAt: updatedAt,
                metadata: ["cwd": item["cwd"] as? String ?? ""]
            )
        case "fileChange":
            let changes = (item["changes"] as? [[String: Any]]) ?? []
            return AgentItemPayload(
                id: id,
                turnId: turnID,
                kind: .fileChange,
                status: status,
                title: "File changes",
                body: changes.compactMap { $0["path"] as? String }.joined(separator: "\n"),
                createdAt: createdAt,
                updatedAt: updatedAt,
                metadata: ["count": "\(changes.count)"]
            )
        case "mcpToolCall":
            let result = item["result"]
            let error = item["error"]
            let body: String? = if let error = error as? [String: Any] {
                error["message"] as? String
            } else if let result {
                String(describing: result)
            } else {
                nil
            }
            return AgentItemPayload(
                id: id,
                turnId: turnID,
                kind: .mcpTool,
                status: status,
                title: item["tool"] as? String ?? "MCP tool",
                body: body,
                createdAt: createdAt,
                updatedAt: updatedAt,
                metadata: ["server": item["server"] as? String ?? ""]
            )
        case "dynamicToolCall":
            let contentItems = (item["contentItems"] as? [[String: Any]]) ?? []
            let body = contentItems.compactMap { $0["text"] as? String }.joined(separator: "\n")
            return AgentItemPayload(
                id: id,
                turnId: turnID,
                kind: .dynamicTool,
                status: status,
                title: item["tool"] as? String ?? "Remote tool",
                body: body.isEmpty ? nil : body,
                createdAt: createdAt,
                updatedAt: updatedAt,
                metadata: [:]
            )
        default:
            return AgentItemPayload(
                id: id,
                turnId: turnID,
                kind: .system,
                status: status,
                title: type,
                body: nil,
                createdAt: createdAt,
                updatedAt: updatedAt,
                metadata: [:]
            )
        }
    }

    private func completionStatus(from item: [String: Any], fallback: AgentItemStatus) -> AgentItemStatus {
        if let status = item["status"] as? String {
            switch status {
            case "completed":
                return .completed
            case "failed":
                return .failed
            case "declined":
                return .declined
            case "in_progress":
                return .inProgress
            default:
                return fallback
            }
        }
        return fallback
    }

    private func runCLICommand(arguments: [String]) async throws -> String {
        if let commandRunner {
            return try await commandRunner(arguments, cliCommandTimeout)
        }
        return try await runCommand(arguments: arguments)
    }

    private func runCommand(arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                process.waitUntilExit()
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
                if process.terminationStatus != 0 {
                    let message = String(data: errorData.isEmpty ? data : errorData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    throw AppCoreError.codexUnavailable(message?.isEmpty == false ? message! : "Codex command failed.")
                }
                return String(data: data, encoding: .utf8) ?? ""
            }

            group.addTask { [cliCommandTimeout] in
                try await Task.sleep(for: cliCommandTimeout)
                if process.isRunning {
                    process.terminate()
                }
                throw AppCoreError.codexUnavailable("Codex command \(arguments.joined(separator: " ")) timed out.")
            }

            defer {
                group.cancelAll()
            }

            guard let result = try await group.next() else {
                throw AppCoreError.codexUnavailable("Codex command \(arguments.joined(separator: " ")) failed to produce output.")
            }
            return result
        }
    }
}
