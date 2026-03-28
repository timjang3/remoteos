import AppKit
import AppCore
import ServiceManagement
import SwiftUI

@main
struct RemoteOSHostApp: App {
    @StateObject private var runtime: HostRuntime
    private let settingsWindowController: SettingsWindowController

    init() {
        DefaultConfigurationRegistrar.register()
        RemoteOSBranding.applyDockIcon()
        let runtime = RuntimeHolder.makeRuntime()
        let foregroundSessionCoordinator = ForegroundSessionCoordinator { policy in
            NSApp.setActivationPolicy(policy)
        }
        let appUpdater = AppUpdater(foregroundSessionCoordinator: foregroundSessionCoordinator)
        _runtime = StateObject(wrappedValue: runtime)
        settingsWindowController = SettingsWindowController(
            runtime: runtime,
            appUpdater: appUpdater,
            foregroundSessionCoordinator: foregroundSessionCoordinator
        )
        runtime.start()
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(
                runtime: runtime,
                openSettingsWindow: { settingsWindowController.show() }
            )
                .frame(width: 360, height: 600)
        } label: {
            RemoteOSMenuBarIcon()
        }
        .menuBarExtraStyle(.window)
    }
}

enum RuntimeHolder {
    @MainActor
    static func makeRuntime() -> HostRuntime {
        do {
            return try HostRuntime()
        } catch {
            fatalError("Failed to initialize HostRuntime: \(error)")
        }
    }
}

// MARK: - Content View

struct ContentView: View {
    @ObservedObject var runtime: HostRuntime
    let openSettingsWindow: () -> Void
    @State private var copiedPairingCode = false
    @State private var copiedURL = false
    @State private var openAIApiKeyInput = ""
    @State private var apiKeySaveMessage: String?

    private var allPermissionsGranted: Bool {
        runtime.permissions.screenRecording == .granted
            && runtime.permissions.accessibility == .granted
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()
                .padding(.horizontal, 16)

            ScrollView {
                VStack(spacing: 16) {
                    pairingSection
                        .padding(.horizontal, 20)

                    if !allPermissionsGranted {
                        permissionsRow
                            .padding(.horizontal, 20)
                    }

                    Divider()
                        .padding(.horizontal, 16)

                    computerUseSection
                        .padding(.horizontal, 20)

                    Divider()
                        .padding(.horizontal, 16)

                    windowsSection
                        .padding(.horizontal, 20)

                    if !runtime.traces.isEmpty {
                        Divider()
                            .padding(.horizontal, 16)

                        activitySection
                            .padding(.horizontal, 20)
                    }
                }
                .padding(.vertical, 12)
            }

            Divider()
                .padding(.horizontal, 16)

            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("RemoteOS")
                    .font(.headline)
                Text(runtime.configuration.deviceName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            connectionBadge
        }
    }

    private var connectionBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(runtime.hostStatus.online ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(runtime.hostStatus.online ? "Connected" : "Connecting")
                .font(.caption.weight(.medium))
                .foregroundStyle(runtime.hostStatus.online ? .primary : .secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.5), in: Capsule())
    }

    // MARK: Pairing

    private var pairingSection: some View {
        VStack(spacing: 12) {
            if let enrollment = runtime.pendingEnrollment {
                VStack(spacing: 12) {
                    if enrollment.status == .expired {
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: 28))
                            .foregroundStyle(.orange)

                        Text("Request Expired")
                            .font(.headline)

                        Text("Start enrollment again from this Mac to generate a new sign-in link.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .font(.system(size: 28))
                            .foregroundStyle(.blue)

                        Text("Sign in to authorize this Mac")
                            .font(.headline)

                        Text("Open your browser, sign in with Google, and approve this Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        Button {
                            runtime.openPendingEnrollmentInBrowser()
                        } label: {
                            Label("Open sign-in page", systemImage: "safari")
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)

                        Text("Expires \(formatTimestamp(enrollment.expiresAt))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(height: 160)
            } else if let pairing = runtime.pairingSession {
                QRCodeView(text: pairing.pairingUrl)
                    .frame(width: 160, height: 160)

                Button {
                    copyToClipboard(pairing.pairingCode)
                    copiedPairingCode = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copiedPairingCode = false
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(formatPairingCode(pairing.pairingCode))
                            .font(.title2.monospaced().weight(.bold))
                        Image(systemName: copiedPairingCode ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(copiedPairingCode ? .green : .secondary)
                    }
                }
                .buttonStyle(.plain)
                .help("Click to copy pairing code")

                Button {
                    copyToClipboard(pairing.pairingUrl)
                    copiedURL = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copiedURL = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copiedURL ? "checkmark" : "link")
                            .font(.caption2)
                        Text(copiedURL ? "Copied!" : pairing.pairingUrl)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .foregroundStyle(copiedURL ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help("Click to copy pairing URL")

                Button {
                    runtime.createPairingSession()
                } label: {
                    Label("New pairing code", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Connecting this Mac...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(height: 160)
            }

            if let lastConnectionError = runtime.lastConnectionError {
                Text(lastConnectionError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Permissions

    private var permissionsRow: some View {
        HStack(spacing: 10) {
            permissionPill(
                "Screen Recording",
                icon: "record.circle",
                status: runtime.permissions.screenRecording,
                action: { runtime.requestScreenRecordingPermission() }
            )
            permissionPill(
                "Accessibility",
                icon: "accessibility",
                status: runtime.permissions.accessibility,
                action: { runtime.requestAccessibilityPermission() }
            )
        }
    }

    private func permissionPill(
        _ label: String,
        icon: String,
        status: PermissionStatus,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Image(
                systemName: status == .granted
                    ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(status == .granted ? .green : .orange)
            Text(label)
                .font(.caption)
                .lineLimit(1)
            if status != .granted {
                Button("Enable", action: action)
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.medium))
                    .controlSize(.mini)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Windows

    private var computerUseSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Computer Use", systemImage: "cursorarrow.click")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            if runtime.openAIAPIKeyConfigured {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text("OpenAI API key configured")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") {
                        runtime.clearOpenAIAPIKey()
                        openAIApiKeyInput = ""
                        apiKeySaveMessage = nil
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.red)
                }
            } else {
                Text("Enter your OpenAI API key for GPT-5.4 computer use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    SecureField("sk-...", text: $openAIApiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    Button("Save") {
                        let trimmed = openAIApiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        runtime.updateOpenAIAPIKey(trimmed)
                        openAIApiKeyInput = ""
                        apiKeySaveMessage = "API key saved."
                    }
                    .controlSize(.small)
                }

                if let apiKeySaveMessage {
                    Text(apiKeySaveMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var windowsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Windows", systemImage: "macwindow.on.rectangle")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    runtime.refreshWindows()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Refresh windows")
            }

            if runtime.windows.isEmpty {
                Text("No windows detected yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 2) {
                    ForEach(runtime.windows.prefix(5)) { window in
                        let isSelected = window.id == runtime.selectedWindowID
                        HStack(spacing: 8) {
                            Image(systemName: appIcon(for: window.ownerName))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(
                                    window.title.isEmpty
                                        ? window.ownerName : window.title
                                )
                                .font(.caption)
                                .lineLimit(1)
                                if !window.title.isEmpty {
                                    Text(window.ownerName)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            if isSelected {
                                Image(systemName: "scope")
                                    .font(.caption2)
                                    .foregroundStyle(.blue)
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(
                            isSelected
                                ? Color.accentColor.opacity(0.08)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                    }
                }
            }
        }
    }

    // MARK: Activity

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Recent Activity", systemImage: "clock.arrow.circlepath")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(runtime.traces.prefix(5)) { trace in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: traceIcon(for: trace.level))
                            .font(.caption2)
                            .foregroundStyle(traceColor(for: trace.level))
                            .frame(width: 14, alignment: .center)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(trace.kind)
                                .font(.caption.weight(.medium))
                            Text(trace.message)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if let task = runtime.agentTurn {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(task.status.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop") {
                        runtime.hardStop()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
                }
            } else {
                Text(runtime.hostStatus.deviceId)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.quaternary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(runtime.hostStatus.codex.state.rawValue.replacingOccurrences(of: "_", with: " "))
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button {
                openSettingsWindow()
            } label: {
                Image(systemName: "gearshape")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings")

            Button {
                runtime.stop()
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Quit RemoteOS")
        }
    }

    // MARK: Helpers

    private func appIcon(for ownerName: String) -> String {
        let name = ownerName.lowercased()
        if name.contains("safari") { return "safari" }
        if name.contains("finder") { return "folder" }
        if name.contains("terminal") { return "terminal" }
        if name.contains("mail") { return "envelope" }
        if name.contains("message") { return "message" }
        if name.contains("note") { return "note.text" }
        if name.contains("music") || name.contains("spotify") { return "music.note" }
        if name.contains("code") || name.contains("xcode") {
            return "chevron.left.forwardslash.chevron.right"
        }
        if name.contains("slack") || name.contains("discord") || name.contains("teams") {
            return "bubble.left.and.bubble.right"
        }
        return "macwindow"
    }

    private func traceIcon(for level: String) -> String {
        switch level {
        case "error": return "xmark.circle.fill"
        case "warn": return "exclamationmark.triangle.fill"
        case "info": return "info.circle.fill"
        default: return "circle.fill"
        }
    }

    private func traceColor(for level: String) -> Color {
        switch level {
        case "error": return .red
        case "warn": return .orange
        case "info": return .blue
        default: return .secondary
        }
    }

    private func formatPairingCode(_ code: String) -> String {
        if code.count > 3 {
            let mid = code.index(code.startIndex, offsetBy: code.count / 2)
            return "\(code[code.startIndex..<mid]) \(code[mid..<code.endIndex])"
        }
        return code
    }

    private func formatTimestamp(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: value) else {
            return value
        }

        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let appUpdater: AppUpdater
    private let foregroundSessionCoordinator: ForegroundSessionCoordinator
    private let runtime: HostRuntime
    private var window: NSWindow?

    init(
        runtime: HostRuntime,
        appUpdater: AppUpdater,
        foregroundSessionCoordinator: ForegroundSessionCoordinator
    ) {
        self.appUpdater = appUpdater
        self.foregroundSessionCoordinator = foregroundSessionCoordinator
        self.runtime = runtime
    }

    func show() {
        let sourceWindow = NSApp.keyWindow
        sourceWindow?.orderOut(nil)
        foregroundSessionCoordinator.beginForegroundSession(reason: .settingsWindow)
        NSApp.activate(ignoringOtherApps: true)

        let window = makeWindowIfNeeded()
        window.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows])

        DispatchQueue.main.async {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            if let firstResponder = window.initialFirstResponder {
                window.makeFirstResponder(firstResponder)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        foregroundSessionCoordinator.endForegroundSession(reason: .settingsWindow)
    }

    private func makeWindowIfNeeded() -> NSWindow {
        if let window {
            return window
        }

        let contentView = SettingsView(appUpdater: appUpdater, runtime: runtime)
            .frame(width: 520, height: 620)
            .padding(24)
        let hostingController = NSHostingController(rootView: contentView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "RemoteOS Settings"
        window.setContentSize(NSSize(width: 520, height: 620))
        window.styleMask = NSWindow.StyleMask([.titled, .closable, .miniaturizable])
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level.normal
        window.collectionBehavior = NSWindow.CollectionBehavior([.moveToActiveSpace])
        window.delegate = self
        window.center()
        window.identifier = NSUserInterfaceItemIdentifier("RemoteOSSettingsWindow")
        self.window = window
        return window
    }
}

struct SettingsView: View {
    let appUpdater: AppUpdater
    @ObservedObject var runtime: HostRuntime
    @State private var controlPlaneURL = ""
    @State private var deviceName = ""
    @State private var codexModel = ""
    @State private var hostMode: HostMode = .hosted
    @State private var launchAtLogin = false
    @State private var saveMessage: String?

    private var controlPlaneAuthStatus: String {
        guard let mode = runtime.controlPlaneAuthMode else {
            return "Checking"
        }
        return mode == .required ? "Required" : "Disabled"
    }

    private var canLogOutHostedDevice: Bool {
        hostMode == .hosted
            && runtime.controlPlaneAuthMode == .required
            && (runtime.configuration.deviceID != nil || runtime.pendingEnrollment != nil)
    }

    var body: some View {
        Form {
            Section("Connection") {
                TextField("Control-plane URL", text: $controlPlaneURL)
                TextField("Device name", text: $deviceName)
                Picker("Mode", selection: $hostMode) {
                    Text("Hosted").tag(HostMode.hosted)
                    Text("Direct").tag(HostMode.direct)
                }
                .pickerStyle(.segmented)

                Text("The app loads its default connection from the bundled configuration file. Saving here overrides it for this Mac until you reset it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if hostMode == .hosted {
                Section("Authentication") {
                    HStack {
                        Text("Status")
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(
                                    runtime.controlPlaneAuthMode == .required
                                        ? Color.green : Color.secondary
                                )
                                .frame(width: 6, height: 6)
                            Text(controlPlaneAuthStatus)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(
                        "Hosted mode requires a one-time browser sign-in to authorize this Mac."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if canLogOutHostedDevice {
                        Button("Log out this Mac", role: .destructive) {
                            runtime.logOutHostedDevice()
                        }
                    }
                }
            }

            Section("Codex") {
                TextField("Codex model", text: $codexModel)
                Text("RemoteOS uses the locally installed `codex` CLI and checks it on first use or when you explicitly refresh it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Check Codex now") {
                    runtime.refreshCodexStatus()
                }
                HStack {
                    Text("Runtime state")
                    Spacer()
                    Text(runtime.hostStatus.codex.state.rawValue.replacingOccurrences(of: "_", with: " "))
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Auth mode")
                    Spacer()
                    Text(runtime.hostStatus.codex.authMode ?? "unknown")
                        .foregroundStyle(.secondary)
                }
            }

            if appUpdater.isAvailable {
                Section("Updates") {
                    HStack {
                        Text("Installed version")
                        Spacer()
                        Text(appUpdater.currentVersionDescription)
                            .foregroundStyle(.secondary)
                    }

                    Button("Check for Updates…") {
                        appUpdater.checkForUpdates()
                    }
                }
            } else if appUpdater.isConfiguredButFailed {
                Section("Updates") {
                    HStack {
                        Text("Installed version")
                        Spacer()
                        Text(appUpdater.currentVersionDescription)
                            .foregroundStyle(.secondary)
                    }
                    Text("Auto-update is unavailable. Check Console logs (category: AppUpdater) for details.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Launch") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, value in
                        do {
                            if value {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = false
                        }
                    }
            }

            HStack {
                Button("Save settings") {
                    saveMessage = nil
                    runtime.updateConfiguration(
                        baseURL: controlPlaneURL,
                        mode: hostMode,
                        deviceName: deviceName,
                        codexModel: codexModel
                    )
                    saveMessage = "Saved settings."
                }

                Button("Reset connection to app defaults") {
                    saveMessage = nil
                    runtime.resetConnectionConfigurationToDefaults()
                    syncFieldsFromRuntime()
                    saveMessage = "Reset connection to app defaults."
                }
            }

            if let saveMessage {
                Text(saveMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            syncFieldsFromRuntime()
        }
    }

    private func syncFieldsFromRuntime() {
        controlPlaneURL = runtime.configuration.controlPlaneBaseURL
        deviceName = runtime.configuration.deviceName
        codexModel = runtime.configuration.codexModel
        hostMode = runtime.configuration.hostMode
    }
}

struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = generateQRCode(text: text) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 16))
        } else {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.secondary.opacity(0.2))
        }
    }

    private func generateQRCode(text: String) -> NSImage? {
        let data = Data(text.utf8)
        guard
            let filter = CIFilter(name: "CIQRCodeGenerator")
        else {
            return nil
        }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let outputImage = filter.outputImage else {
            return nil
        }
        let transformed = outputImage.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let rep = NSCIImageRep(ciImage: transformed)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
