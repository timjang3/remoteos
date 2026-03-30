import SwiftUI
import RemoteOSCore

struct SessionView: View {
    let store: RemoteOSAppStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(spacing: 18) {
                    streamSection
                    transcriptSection
                    promptSection
                }
                .padding(20)
            }

            composer

            if let bannerText = disconnectedBannerText {
                VStack(spacing: 10) {
                    Text(bannerText)
                        .font(.footnote.weight(.medium))
                    if store.session.connectionState == .error {
                        Button("Retry") {
                            Task {
                                await store.refreshHealth()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(.thinMaterial)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .sheet(
            isPresented: Binding(
                get: { store.session.isWindowSheetPresented },
                set: { store.session.isWindowSheetPresented = $0 }
            )
        ) {
            WindowPickerSheet(store: store)
        }
        .sheet(
            isPresented: Binding(
                get: { store.session.isModelSheetPresented },
                set: { store.session.isModelSheetPresented = $0 }
            )
        ) {
            ModelPickerSheet(store: store)
        }
        .sheet(
            isPresented: Binding(
                get: { store.session.isSettingsPresented },
                set: { store.session.isSettingsPresented = $0 }
            )
        ) {
            SettingsSheet(store: store)
        }
        .sheet(
            isPresented: Binding(
                get: { store.session.isTextEntryPresented },
                set: { store.session.isTextEntryPresented = $0 }
            )
        ) {
            TextEntrySheet(store: store)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Circle()
                .fill((store.session.hostStatus?.online ?? false) ? Color.green : Color.orange)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 4) {
                Text(store.selectedWindow?.title ?? "RemoteOS")
                    .font(.headline)
                Text(store.storeStatusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                store.session.isModelSheetPresented = true
            } label: {
                Label(store.currentModelDisplayName, systemImage: "wand.and.stars")
            }
            .buttonStyle(.bordered)

            Button {
                store.session.isWindowSheetPresented = true
            } label: {
                Image(systemName: "rectangle.on.rectangle")
            }
            .buttonStyle(.bordered)

            Button {
                store.session.isSettingsPresented = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var streamSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            StreamPreviewView(store: store)
                .frame(minHeight: 260, maxHeight: 380)

            Picker("Input mode", selection: Binding(
                get: { store.settings.inputMode },
                set: { store.settings.inputMode = $0 }
            )) {
                ForEach(RemoteInputMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if let semanticSummary = store.session.semanticSnapshot?.summary ?? store.selectedWindow?.semanticSummary {
                Text(semanticSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.agent.items.isEmpty && store.agent.pendingPrompt == nil {
                VStack(alignment: .leading, spacing: 10) {
                    Text(store.selectedWindow == nil ? "Select a window to get started." : "Ask the agent to do something on your Mac.")
                        .font(.headline)
                    Text(store.selectedWindow == nil ? "Use the windows sheet to choose a live window, then stream and control it here." : "Commentary, prompt cards, and final answers appear here in the same order as the web client.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(store.agent.items) { item in
                        transcriptBubble(item: item)
                    }

                    if let pendingPrompt = store.agent.pendingPrompt {
                        HStack {
                            Spacer()
                            Text(pendingPrompt.body)
                                .padding(12)
                                .foregroundStyle(.white)
                                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                    }
                }
            }

            if let error = store.agent.errorMessage ?? store.session.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private var promptSection: some View {
        VStack(spacing: 12) {
            ForEach(store.agent.prompts) { prompt in
                PromptCardView(
                    prompt: prompt,
                    isSubmitting: store.agent.submittingPromptIDs.contains(prompt.id),
                    onSubmit: { action, answers in
                        Task {
                            await store.respondToPrompt(promptID: prompt.id, action: action, answers: answers)
                        }
                    }
                )
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 12) {
            Divider()
            HStack(alignment: .bottom, spacing: 12) {
                TextEditor(text: Binding(
                    get: { store.agent.draftPrompt },
                    set: { store.agent.draftPrompt = $0 }
                ))
                .frame(minHeight: 44, maxHeight: 120)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                if store.agent.turn?.status == .running {
                    Button {
                        Task {
                            await store.cancelActiveTurn()
                        }
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    if store.session.speechCapabilities?.transcriptionAvailable ?? false {
                        Button {
                            Task {
                                await store.toggleDictation()
                            }
                        } label: {
                            Image(systemName: store.agent.dictationState == .recording ? "stop.circle.fill" : "mic.fill")
                        }
                        .buttonStyle(.bordered)
                        .tint(store.agent.dictationState == .recording ? .red : .accentColor)
                    }

                    Button {
                        Task {
                            await store.sendPrompt()
                        }
                    } label: {
                        Image(systemName: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.isAgentReady || store.agent.draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .background(.ultraThinMaterial)
    }

    private var disconnectedBannerText: String? {
        switch store.session.connectionState {
        case .bootstrapping:
            return "Connecting to your Mac…"
        case .connecting:
            return "Establishing the live stream…"
        case .error:
            return store.session.errorMessage ?? "The RemoteOS session failed."
        case .idle where store.hasPersistedClientSession:
            return "Disconnected"
        default:
            return nil
        }
    }

    @ViewBuilder
    private func transcriptBubble(item: AgentItemPayload) -> some View {
        switch item.kind {
        case .userMessage:
            HStack {
                Spacer()
                Text(item.body ?? item.title)
                    .padding(12)
                    .foregroundStyle(.white)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        case .assistantMessage:
            HStack {
                Text(item.body ?? item.title)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Spacer(minLength: 32)
            }
        default:
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                    if let body = item.body, !body.isEmpty {
                        Text(body)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(14)
            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

private struct StreamPreviewView: View {
    let store: RemoteOSAppStore

    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastScrollTranslation: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.08, green: 0.11, blue: 0.16),
                                Color(red: 0.14, green: 0.17, blue: 0.24)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                if let previewImage = store.selectedPreviewImage {
                    previewImage
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(store.settings.inputMode == .view ? zoom : 1)
                        .offset(store.settings.inputMode == .view ? offset : .zero)
                        .contentShape(Rectangle())
                        .gesture(viewModeGestures)
                        .simultaneousGesture(tapGesture(in: geometry.size))
                        .simultaneousGesture(doubleTapGesture(in: geometry.size))
                        .simultaneousGesture(scrollGesture(in: geometry.size))
                        .simultaneousGesture(dragGesture(in: geometry.size))
                        .padding(12)
                } else if store.selectedWindow == nil {
                    VStack(spacing: 10) {
                        Image(systemName: "rectangle.stack.badge.plus")
                            .font(.system(size: 34))
                        Text("Select a window")
                            .font(.headline)
                        Text("Choose a live Mac window from the windows sheet to start streaming.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(24)
                } else {
                    ProgressView("Waiting for the live frame…")
                }

                if store.settings.inputMode == .keyboard, store.session.currentFrame != nil {
                    VStack {
                        Spacer()
                        Button {
                            store.session.isTextEntryPresented = true
                        } label: {
                            Label("Text input", systemImage: "keyboard")
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 16)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if store.selectedWindow != nil {
                Button {
                    Task {
                        await store.deselectWindow()
                    }
                } label: {
                    Image(systemName: "xmark")
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .padding(14)
            }
        }
    }

    private var viewModeGestures: some Gesture {
        SimultaneousGesture(
            MagnificationGesture()
                .onChanged { value in
                    guard store.settings.inputMode == .view else { return }
                    zoom = max(1, value)
                },
            DragGesture()
                .onChanged { value in
                    guard store.settings.inputMode == .view else { return }
                    offset = value.translation
                }
                .onEnded { _ in
                    if store.settings.inputMode == .view {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            offset = .zero
                        }
                    }
                }
        )
    }

    private func tapGesture(in size: CGSize) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                guard store.settings.inputMode == .tap,
                      let currentFrame = store.session.currentFrame,
                      let normalizedPoint = normalizedPoint(
                        value.location,
                        in: size,
                        imageSize: CGSize(
                            width: currentFrame.payload.width,
                            height: currentFrame.payload.height
                        )
                      ) else {
                    return
                }

                Task {
                    await store.handleTap(
                        normalizedX: normalizedPoint.x,
                        normalizedY: normalizedPoint.y,
                        clickCount: 1
                    )
                }
            }
    }

    private func doubleTapGesture(in size: CGSize) -> some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { value in
                guard store.settings.inputMode == .tap,
                      let currentFrame = store.session.currentFrame,
                      let normalizedPoint = normalizedPoint(
                        value.location,
                        in: size,
                        imageSize: CGSize(
                            width: currentFrame.payload.width,
                            height: currentFrame.payload.height
                        )
                      ) else {
                    return
                }

                Task {
                    await store.handleTap(
                        normalizedX: normalizedPoint.x,
                        normalizedY: normalizedPoint.y,
                        clickCount: 2
                    )
                }
            }
    }

    private func scrollGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard store.settings.inputMode == .scroll else { return }
                let delta = CGSize(
                    width: value.translation.width - lastScrollTranslation.width,
                    height: value.translation.height - lastScrollTranslation.height
                )
                lastScrollTranslation = value.translation

                Task {
                    await store.handleScroll(
                        deltaX: Double(delta.width * 1.5),
                        deltaY: Double(delta.height * 1.5)
                    )
                }
            }
            .onEnded { _ in
                lastScrollTranslation = .zero
            }
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onEnded { value in
                guard store.settings.inputMode == .drag,
                      let currentFrame = store.session.currentFrame,
                      let startPoint = normalizedPoint(
                        value.startLocation,
                        in: size,
                        imageSize: CGSize(
                            width: currentFrame.payload.width,
                            height: currentFrame.payload.height
                        )
                      ),
                      let endPoint = normalizedPoint(
                        value.location,
                        in: size,
                        imageSize: CGSize(
                            width: currentFrame.payload.width,
                            height: currentFrame.payload.height
                        )
                      ) else {
                    return
                }

                Task {
                    await store.handleDrag(from: startPoint, to: endPoint)
                }
            }
    }

    private func normalizedPoint(_ point: CGPoint, in containerSize: CGSize, imageSize: CGSize) -> CGPoint? {
        guard containerSize.width > 0, containerSize.height > 0, imageSize.width > 0, imageSize.height > 0 else {
            return nil
        }

        let imageAspect = imageSize.width / imageSize.height
        let containerAspect = containerSize.width / containerSize.height

        let drawSize: CGSize
        if imageAspect > containerAspect {
            drawSize = CGSize(width: containerSize.width, height: containerSize.width / imageAspect)
        } else {
            drawSize = CGSize(width: containerSize.height * imageAspect, height: containerSize.height)
        }

        let origin = CGPoint(
            x: (containerSize.width - drawSize.width) / 2,
            y: (containerSize.height - drawSize.height) / 2
        )

        guard point.x >= origin.x,
              point.y >= origin.y,
              point.x <= origin.x + drawSize.width,
              point.y <= origin.y + drawSize.height else {
            return nil
        }

        let x = (point.x - origin.x) / drawSize.width
        let y = (point.y - origin.y) / drawSize.height
        return CGPoint(
            x: min(max(x, 0), 0.999_999),
            y: min(max(y, 0), 0.999_999)
        )
    }
}

private struct PromptCardView: View {
    let prompt: AgentPromptPayload
    let isSubmitting: Bool
    let onSubmit: (AgentPromptResponseAction, [String: AgentPromptAnswerPayload]) -> Void

    @State private var selectedOptions: [String: String] = [:]
    @State private var textAnswers: [String: String] = [:]
    @State private var validationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(prompt.source == .computerUse ? "Computer Use" : "Codex")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(prompt.title)
                        .font(.headline)
                }

                Spacer()

                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let body = prompt.body, !body.isEmpty {
                Text(body)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !prompt.questions.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(prompt.questions, id: \.id) { question in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(question.header)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(question.question)
                                .font(.subheadline)

                            if let options = question.options, !options.isEmpty {
                                Picker(question.header, selection: Binding(
                                    get: { selectedOptions[question.id] ?? "" },
                                    set: { selectedOptions[question.id] = $0 }
                                )) {
                                    Text("Select").tag("")
                                    ForEach(options, id: \.label) { option in
                                        Text(option.label).tag(option.label)
                                    }
                                    if question.isOther {
                                        Text("Other").tag("__other__")
                                    }
                                }
                                .pickerStyle(.menu)
                            }

                            let selectedValue = selectedOptions[question.id] ?? ""
                            let showTextField = question.options?.isEmpty != false || selectedValue == "__other__"
                            if showTextField {
                                TextField(
                                    question.isSecret ? "Enter a secret value" : "Enter your answer",
                                    text: Binding(
                                        get: { textAnswers[question.id] ?? "" },
                                        set: { textAnswers[question.id] = $0 }
                                    )
                                )
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .textFieldStyle(.roundedBorder)
                            }
                        }
                    }

                    if let validationError {
                        Text(validationError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    Button("Continue") {
                        let answers = buildAnswers()
                        if answers.isEmpty && !prompt.questions.isEmpty {
                            validationError = "Answer every prompt before continuing."
                            return
                        }
                        validationError = nil
                        onSubmit(.submit, answers)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSubmitting)
                }
            }

            if let choices = prompt.choices, !choices.isEmpty {
                HStack {
                    ForEach(choices, id: \.id) { choice in
                        if choice.id == "accept" {
                            Button(choice.label) {
                                guard let action = AgentPromptResponseAction(rawValue: choice.id) else {
                                    return
                                }
                                onSubmit(action, [:])
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isSubmitting)
                        } else {
                            Button(choice.label) {
                                guard let action = AgentPromptResponseAction(rawValue: choice.id) else {
                                    return
                                }
                                onSubmit(action, [:])
                            }
                            .buttonStyle(.bordered)
                            .disabled(isSubmitting)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func buildAnswers() -> [String: AgentPromptAnswerPayload] {
        var answers: [String: AgentPromptAnswerPayload] = [:]

        for question in prompt.questions {
            let selectedValue = selectedOptions[question.id]
            let typedValue = textAnswers[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let resolvedValue = (selectedValue == "__other__" || selectedValue?.isEmpty != false) ? typedValue : (selectedValue ?? "")

            guard !resolvedValue.isEmpty else {
                return [:]
            }

            answers[question.id] = AgentPromptAnswerPayload(answers: [resolvedValue])
        }

        return answers
    }
}

private struct WindowPickerSheet: View {
    let store: RemoteOSAppStore

    var body: some View {
        NavigationStack {
            List(store.session.windows) { window in
                Button {
                    Task {
                        await store.selectWindow(window)
                    }
                } label: {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemGroupedBackground))
                            .overlay {
                                if let snapshot = store.session.snapshots[window.id] {
                                    snapshot
                                        .resizable()
                                        .scaledToFill()
                                } else {
                                    Image(systemName: "macwindow")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 72, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(window.ownerName)
                                .font(.headline)
                            Text(window.title)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Spacer()

                        if store.session.selectedWindowID == window.id {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .foregroundStyle(.green)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Windows")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        store.session.isWindowSheetPresented = false
                    }
                }
            }
        }
    }
}

private struct ModelPickerSheet: View {
    let store: RemoteOSAppStore

    var body: some View {
        NavigationStack {
            List(RemoteOSAppStore.availableModels) { model in
                Button {
                    Task {
                        await store.selectModel(model.id)
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.name)
                                .font(.headline)
                            Text(model.description)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if store.session.codexStatus?.model == model.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Model")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        store.session.isModelSheetPresented = false
                    }
                }
            }
        }
    }
}

private struct SettingsSheet: View {
    let store: RemoteOSAppStore

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    LabeledContent("Control plane", value: store.pairing.controlPlaneBaseURL)
                    LabeledContent("Client name", value: store.pairing.clientName)
                    LabeledContent("Authentication", value: store.pairing.isAuthenticated ? (store.pairing.signedInEmail ?? "Signed in") : "Not signed in")
                }

                Section("Streaming") {
                    LabeledContent("Recommended profile", value: store.currentStreamProfile.rawValue)
                    Toggle("Low data mode", isOn: Binding(
                        get: { store.settings.lowDataMode },
                        set: { store.settings.lowDataMode = $0 }
                    ))
                }

                if !store.session.traceEvents.isEmpty {
                    Section("Recent traces") {
                        ForEach(store.session.traceEvents.prefix(8)) { event in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(event.kind)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(event.message)
                                    .font(.footnote)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section {
                    Button(store.requiresAuthentication ? "Sign out" : "Disconnect", role: .destructive) {
                        Task {
                            await store.disconnect(clearAuthToken: store.requiresAuthentication)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        store.session.isSettingsPresented = false
                    }
                }
            }
        }
    }
}

private struct TextEntrySheet: View {
    let store: RemoteOSAppStore

    private let specialKeys = [
        "return",
        "tab",
        "escape",
        "delete",
        "up",
        "down",
        "left",
        "right",
        "command",
        "control",
        "option",
        "shift"
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                TextEditor(text: Binding(
                    get: { store.session.textEntryValue },
                    set: { store.session.textEntryValue = $0 }
                ))
                .frame(minHeight: 160)
                .padding(12)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                    ForEach(specialKeys, id: \.self) { key in
                        Button(key.replacingOccurrences(of: "_", with: " ").capitalized) {
                            Task {
                                await store.sendSpecialKey(key)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Button("Send text") {
                    Task {
                        await store.submitTextEntry()
                    }
                }
                .buttonStyle(.borderedProminent)

                Spacer()
            }
            .padding(20)
            .navigationTitle("Keyboard")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        store.session.isTextEntryPresented = false
                    }
                }
            }
        }
    }
}

private extension RemoteOSAppStore {
    var currentModelDisplayName: String {
        if let modelID = session.codexStatus?.model,
           let model = Self.availableModels.first(where: { $0.id == modelID }) {
            return model.name
        }
        return session.codexStatus?.model ?? "Model"
    }

    var storeStatusLine: String {
        switch session.connectionState {
        case .connected:
            return (session.hostStatus?.online ?? false) ? "Connected" : "Mac offline"
        case .bootstrapping:
            return "Bootstrapping"
        case .connecting:
            return "Connecting"
        case .error:
            return "Error"
        case .idle:
            return "Idle"
        }
    }
}
