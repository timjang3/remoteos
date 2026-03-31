import SwiftUI
import RemoteOSCore

// MARK: - Theme

extension Color {
    static let roBackground = Color(red: 0.035, green: 0.035, blue: 0.043)
    static let roSurface = Color(red: 0.094, green: 0.094, blue: 0.106)
    static let roSurfaceRaised = Color(red: 0.153, green: 0.153, blue: 0.165)
    static let roText = Color(red: 0.980, green: 0.980, blue: 0.980)
    static let roTextSecondary = Color(red: 0.631, green: 0.631, blue: 0.667)
    static let roTextTertiary = Color(red: 0.443, green: 0.443, blue: 0.478)
    static let roAccent = Color(red: 0.910, green: 0.769, blue: 0.722)
    static let roSuccess = Color(red: 0.290, green: 0.871, blue: 0.502)
    static let roDanger = Color(red: 0.973, green: 0.443, blue: 0.443)
    static let roBorder = Color.white.opacity(0.06)
    static let roBorderActive = Color.white.opacity(0.12)
}

// MARK: - Session View

struct SessionView: View {
    let store: RemoteOSAppStore

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                sessionHeader

                if store.session.selectedWindowID != nil {
                    StreamPreviewView(store: store, maxHeight: geometry.size.height * 0.5)
                    Color.roBorder.frame(height: 1)
                }

                chatArea

                chatComposer

                if let bannerText = disconnectedBannerText {
                    disconnectionBanner(bannerText)
                }
            }
        }
        .background(Color.roBackground)
        .sheet(
            isPresented: Binding(
                get: { store.session.isWindowSheetPresented },
                set: { store.session.isWindowSheetPresented = $0 }
            )
        ) {
            WindowPickerSheet(store: store)
                .presentationBackground(Color.roSurface)
                .presentationCornerRadius(24)
                .presentationDragIndicator(.visible)
                .presentationDetents([.medium, .large])
        }
        .sheet(
            isPresented: Binding(
                get: { store.session.isSettingsPresented },
                set: { store.session.isSettingsPresented = $0 }
            )
        ) {
            SettingsSheet(store: store)
                .presentationBackground(Color.roSurface)
                .presentationCornerRadius(24)
                .presentationDragIndicator(.visible)
                .presentationDetents([.medium, .large])
        }
        .sheet(
            isPresented: Binding(
                get: { store.session.isTextEntryPresented },
                set: { store.session.isTextEntryPresented = $0 }
            )
        ) {
            TextEntrySheet(store: store)
                .presentationBackground(Color.roSurface)
                .presentationCornerRadius(24)
                .presentationDragIndicator(.visible)
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: - Header

    private var sessionHeader: some View {
        HStack(spacing: 10) {
            Circle()
                .fill((store.session.hostStatus?.online ?? false) ? Color.roSuccess : Color.roTextTertiary)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(store.selectedWindow?.title ?? "RemoteOS")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.roText)
                    .lineLimit(1)
                Text(store.storeStatusLine)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.roTextSecondary)
            }

            Spacer()

            modelMenu

            Button {
                store.session.isWindowSheetPresented = true
            } label: {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.roTextSecondary)
                    .frame(width: 34, height: 34)
                    .background(Color.roSurfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            Button {
                store.session.isSettingsPresented = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.roTextSecondary)
                    .frame(width: 34, height: 34)
                    .background(Color.roSurfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.roSurface)
        .overlay(alignment: .bottom) {
            Color.roBorder.frame(height: 1)
        }
    }

    private var modelMenu: some View {
        Menu {
            ForEach(RemoteOSAppStore.availableModels) { model in
                Button(action: {
                    Task { await store.selectModel(model.id) }
                }) {
                    if store.session.codexStatus?.model == model.id {
                        Label(model.name, systemImage: "checkmark")
                    } else {
                        Text(model.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .medium))
                Text(store.currentModelDisplayName)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Color.roTextSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.roSurfaceRaised, in: Capsule())
        }
    }

    // MARK: - Chat Area

    private var chatArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if store.agent.items.isEmpty && store.agent.pendingPrompt == nil {
                        emptyState
                            .padding(.top, 40)
                    } else {
                        ForEach(store.agent.items) { item in
                            transcriptBubble(item: item)
                                .id(item.id)
                        }

                        if let pendingPrompt = store.agent.pendingPrompt {
                            HStack {
                                Spacer(minLength: 60)
                                Text(pendingPrompt.body)
                                    .font(.body)
                                    .foregroundStyle(Color.roBackground)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(
                                        Color.roAccent.opacity(0.6),
                                        in: UnevenRoundedRectangle(
                                            topLeadingRadius: 18,
                                            bottomLeadingRadius: 18,
                                            bottomTrailingRadius: 4,
                                            topTrailingRadius: 18
                                        )
                                    )
                            }
                            .id("pending")
                        }

                        if store.agent.turn?.status == .running {
                            TypingIndicator()
                                .id("typing")
                        }
                    }

                    if let error = store.agent.errorMessage ?? store.session.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(Color.roDanger)
                            .padding(.horizontal, 4)
                    }

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
                        .id("prompt-\(prompt.id)")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: store.agent.items.count) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: store.agent.pendingPrompt?.id) { _, _ in
                scrollToBottom(proxy: proxy)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if store.session.selectedWindowID == nil {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(Color.roTextTertiary)
                Text("Select a window")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.roText)
                Text("Choose a Mac window to start streaming and controlling.")
                    .font(.subheadline)
                    .foregroundStyle(Color.roTextSecondary)
                    .multilineTextAlignment(.center)
                Button {
                    store.session.isWindowSheetPresented = true
                } label: {
                    Text("Browse Windows")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.roBackground)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Color.roAccent, in: Capsule())
                }
                .padding(.top, 4)
            } else {
                Image(systemName: "text.bubble")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(Color.roTextTertiary)
                Text("What can I help with?")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.roText)
                Text("Ask the agent to perform actions on your Mac, or tap the stream to interact directly.")
                    .font(.subheadline)
                    .foregroundStyle(Color.roTextSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private func transcriptBubble(item: AgentItemPayload) -> some View {
        switch item.kind {
        case .userMessage:
            HStack {
                Spacer(minLength: 60)
                Text(item.body ?? item.title)
                    .font(.body)
                    .foregroundStyle(Color.roBackground)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        Color.roAccent,
                        in: UnevenRoundedRectangle(
                            topLeadingRadius: 18,
                            bottomLeadingRadius: 18,
                            bottomTrailingRadius: 4,
                            topTrailingRadius: 18
                        )
                    )
            }
        case .assistantMessage:
            HStack {
                Text(item.body ?? item.title)
                    .font(.body)
                    .foregroundStyle(Color.roText)
                    .textSelection(.enabled)
                Spacer(minLength: 60)
            }
        default:
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.roTextTertiary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.roText)
                    if let body = item.body, !body.isEmpty {
                        Text(body)
                            .font(.footnote)
                            .foregroundStyle(Color.roTextSecondary)
                    }
                }
                Spacer()
            }
            .padding(12)
            .background(Color.roSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.roBorder, lineWidth: 1)
            )
        }
    }

    // MARK: - Composer

    private var chatComposer: some View {
        VStack(spacing: 0) {
            Color.roBorder.frame(height: 1)

            HStack(alignment: .bottom, spacing: 6) {
                TextEditor(text: Binding(
                    get: { store.agent.draftPrompt },
                    set: { store.agent.draftPrompt = $0 }
                ))
                .font(.body)
                .foregroundStyle(Color.roText)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 20, maxHeight: 100)
                .padding(.leading, 12)
                .padding(.vertical, 6)

                if store.agent.turn?.status == .running {
                    Button {
                        Task { await store.cancelActiveTurn() }
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Color.roDanger, in: Circle())
                    }
                    .padding(.trailing, 4)
                    .padding(.bottom, 4)
                } else {
                    HStack(spacing: 2) {
                        if store.session.speechCapabilities?.transcriptionAvailable ?? false {
                            Button {
                                Task { await store.toggleDictation() }
                            } label: {
                                Image(systemName: store.agent.dictationState == .recording ? "stop.circle.fill" : "mic.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(store.agent.dictationState == .recording ? Color.roDanger : Color.roTextTertiary)
                                    .frame(width: 28, height: 28)
                            }
                        }

                        Button {
                            Task { await store.sendPrompt() }
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(canSend ? Color.roBackground : Color.roTextTertiary)
                                .frame(width: 28, height: 28)
                                .background(canSend ? Color.roAccent : Color.roSurfaceRaised, in: Circle())
                        }
                        .disabled(!canSend)
                    }
                    .padding(.trailing, 4)
                    .padding(.bottom, 4)
                }
            }
            .background(Color.roBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.roBorder, lineWidth: 1))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.roSurface)
        }
    }

    private var canSend: Bool {
        store.isAgentReady && !store.agent.draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Disconnection Banner

    private func disconnectionBanner(_ text: String) -> some View {
        VStack(spacing: 8) {
            Text(text)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color.roText)
            if store.session.connectionState == .error {
                Button("Retry") {
                    Task { await store.refreshHealth() }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.roBackground)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color.roAccent, in: Capsule())
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color.roSurfaceRaised)
    }

    private var disconnectedBannerText: String? {
        switch store.session.connectionState {
        case .bootstrapping:
            return "Connecting to your Mac\u{2026}"
        case .connecting:
            return "Establishing live stream\u{2026}"
        case .error:
            return store.session.errorMessage ?? "Session failed."
        case .idle where store.hasPersistedClientSession:
            return "Disconnected"
        default:
            return nil
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        let target: String? = {
            if store.agent.turn?.status == .running { return "typing" }
            if store.agent.pendingPrompt != nil { return "pending" }
            if let last = store.agent.prompts.last { return "prompt-\(last.id)" }
            return store.agent.items.last?.id
        }()
        if let target {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(target, anchor: .bottom)
            }
        }
    }
}

// MARK: - Typing Indicator

private struct TypingIndicator: View {
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.roTextTertiary)
                    .frame(width: 6, height: 6)
                    .offset(y: isAnimating ? -4 : 0)
                    .animation(
                        .easeInOut(duration: 0.4)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: isAnimating
                    )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.roSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { isAnimating = true }
    }
}

// MARK: - Stream Preview

private struct StreamPreviewView: View {
    let store: RemoteOSAppStore
    let maxHeight: CGFloat

    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @State private var lastPanOffset: CGSize = .zero
    @State private var lastScrollTranslation: CGSize = .zero
    @State private var isPinching = false
    @State private var isDragMode = false

    var body: some View {
        streamBody
            .frame(maxWidth: .infinity, maxHeight: maxHeight)
            .clipped()
            // Gesture layer — GeometryReader only for coordinate capture, not sizing
            .overlay {
                GeometryReader { geometry in
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(pinchGesture)
                        .simultaneousGesture(dragGesture(in: geometry.size))
                        .simultaneousGesture(doubleTapGesture(in: geometry.size))
                        .simultaneousGesture(tapGesture(in: geometry.size))
                }
            }
            // Close button — top trailing
            .overlay(alignment: .topTrailing) {
                Button {
                    Task { await store.deselectWindow() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.roText.opacity(0.9))
                        .frame(width: 24, height: 24)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .padding(8)
            }
            // Bottom toolbar
            .overlay(alignment: .bottom) {
                HStack {
                    interactionToggle

                    Spacer()

                    if zoom > 1.05 {
                        Text(String(format: "%.1f\u{00D7}", zoom))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.roText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.ultraThinMaterial, in: Capsule())
                    }

                    Button {
                        store.session.isTextEntryPresented = true
                    } label: {
                        Image(systemName: "keyboard")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.roText.opacity(0.9))
                            .frame(width: 26, height: 26)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
            .onChange(of: store.session.selectedWindowID) { _, _ in
                zoom = 1
                lastZoom = 1
                panOffset = .zero
                lastPanOffset = .zero
            }
    }

    @ViewBuilder
    private var streamBody: some View {
        if let previewImage = store.selectedPreviewImage {
            previewImage
                .resizable()
                .aspectRatio(contentMode: .fit)
                .scaleEffect(zoom)
                .offset(panOffset)
        } else {
            Color.roBackground
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay { ProgressView().tint(Color.roTextTertiary) }
        }
    }

    private var interactionToggle: some View {
        Menu {
            Button {
                isDragMode = false
            } label: {
                if !isDragMode {
                    Label("Scroll", systemImage: "checkmark")
                } else {
                    Text("Scroll")
                }
            }
            Button {
                isDragMode = true
            } label: {
                if isDragMode {
                    Label("Drag", systemImage: "checkmark")
                } else {
                    Text("Drag")
                }
            }
        } label: {
            Image(systemName: isDragMode ? "hand.draw" : "arrow.up.arrow.down")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.roText.opacity(0.9))
                .frame(width: 26, height: 26)
                .background(.ultraThinMaterial, in: Circle())
        }
    }

    // MARK: - Gestures

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                isPinching = true
                zoom = max(1, lastZoom * value)
            }
            .onEnded { value in
                isPinching = false
                zoom = max(1, lastZoom * value)
                lastZoom = zoom
                if zoom < 1.15 {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        zoom = 1
                        lastZoom = 1
                        panOffset = .zero
                        lastPanOffset = .zero
                    }
                }
            }
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard !isPinching else { return }
                if zoom > 1 {
                    panOffset = CGSize(
                        width: lastPanOffset.width + value.translation.width,
                        height: lastPanOffset.height + value.translation.height
                    )
                } else if isDragMode {
                    // Drag mode: nothing on change, we send on end
                } else {
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
            }
            .onEnded { value in
                if isPinching {
                    lastScrollTranslation = .zero
                    return
                }
                if zoom > 1 {
                    lastPanOffset = panOffset
                } else if isDragMode {
                    guard let currentFrame = store.session.currentFrame else {
                        lastScrollTranslation = .zero
                        return
                    }
                    let imageSize = CGSize(
                        width: currentFrame.payload.width,
                        height: currentFrame.payload.height
                    )
                    if let startPt = normalizedPoint(value.startLocation, in: size, imageSize: imageSize),
                       let endPt = normalizedPoint(value.location, in: size, imageSize: imageSize) {
                        Task {
                            await store.handleDrag(from: startPt, to: endPt)
                        }
                    }
                }
                lastScrollTranslation = .zero
            }
    }

    private func tapGesture(in size: CGSize) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                guard let currentFrame = store.session.currentFrame else { return }
                let imageSize = CGSize(
                    width: currentFrame.payload.width,
                    height: currentFrame.payload.height
                )
                let adjustedPt = adjustPoint(value.location, in: size)
                guard let normalPt = normalizedPoint(adjustedPt, in: size, imageSize: imageSize) else { return }
                Task {
                    await store.handleTap(normalizedX: normalPt.x, normalizedY: normalPt.y, clickCount: 1)
                }
            }
    }

    private func doubleTapGesture(in size: CGSize) -> some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { value in
                guard let currentFrame = store.session.currentFrame else { return }
                let imageSize = CGSize(
                    width: currentFrame.payload.width,
                    height: currentFrame.payload.height
                )
                let adjustedPt = adjustPoint(value.location, in: size)
                guard let normalPt = normalizedPoint(adjustedPt, in: size, imageSize: imageSize) else { return }
                Task {
                    await store.handleTap(normalizedX: normalPt.x, normalizedY: normalPt.y, clickCount: 2)
                }
            }
    }

    // MARK: - Coordinate Helpers

    private func adjustPoint(_ point: CGPoint, in containerSize: CGSize) -> CGPoint {
        guard zoom > 1 else { return point }
        let center = CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)
        return CGPoint(
            x: center.x + (point.x - center.x - panOffset.width) / zoom,
            y: center.y + (point.y - center.y - panOffset.height) / zoom
        )
    }

    private func normalizedPoint(_ point: CGPoint, in containerSize: CGSize, imageSize: CGSize) -> CGPoint? {
        guard containerSize.width > 0, containerSize.height > 0,
              imageSize.width > 0, imageSize.height > 0 else { return nil }

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

        guard point.x >= origin.x, point.y >= origin.y,
              point.x <= origin.x + drawSize.width,
              point.y <= origin.y + drawSize.height else { return nil }

        return CGPoint(
            x: min(max((point.x - origin.x) / drawSize.width, 0), 0.999_999),
            y: min(max((point.y - origin.y) / drawSize.height, 0), 0.999_999)
        )
    }
}

// MARK: - Prompt Card

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
                    Text(prompt.source == .computerUse ? "COMPUTER USE" : "CODEX")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.roAccent)
                    Text(prompt.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.roText)
                }
                Spacer()
                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.roAccent)
                }
            }

            if let body = prompt.body, !body.isEmpty {
                Text(body)
                    .font(.subheadline)
                    .foregroundStyle(Color.roTextSecondary)
            }

            if !prompt.questions.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(prompt.questions, id: \.id) { question in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(question.header)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.roTextSecondary)
                            Text(question.question)
                                .font(.subheadline)
                                .foregroundStyle(Color.roText)

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
                                .tint(Color.roAccent)
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
                                .font(.body)
                                .foregroundStyle(Color.roText)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(Color.roBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(Color.roBorderActive, lineWidth: 1)
                                )
                            }
                        }
                    }

                    if let validationError {
                        Text(validationError)
                            .font(.footnote)
                            .foregroundStyle(Color.roDanger)
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
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.roBackground)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.roAccent, in: Capsule())
                    .disabled(isSubmitting)
                    .opacity(isSubmitting ? 0.6 : 1)
                }
            }

            if let choices = prompt.choices, !choices.isEmpty {
                HStack(spacing: 8) {
                    ForEach(choices, id: \.id) { choice in
                        if choice.id == "accept" {
                            Button(choice.label) {
                                guard let action = AgentPromptResponseAction(rawValue: choice.id) else { return }
                                onSubmit(action, [:])
                            }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.roBackground)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Color.roAccent, in: Capsule())
                            .disabled(isSubmitting)
                            .opacity(isSubmitting ? 0.6 : 1)
                        } else {
                            Button(choice.label) {
                                guard let action = AgentPromptResponseAction(rawValue: choice.id) else { return }
                                onSubmit(action, [:])
                            }
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.roText)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Color.roSurfaceRaised, in: Capsule())
                            .disabled(isSubmitting)
                            .opacity(isSubmitting ? 0.6 : 1)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [Color.roAccent.opacity(0.06), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            ),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.roAccent.opacity(0.3), Color.roAccent.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
    }

    private func buildAnswers() -> [String: AgentPromptAnswerPayload] {
        var answers: [String: AgentPromptAnswerPayload] = [:]
        for question in prompt.questions {
            let selectedValue = selectedOptions[question.id]
            let typedValue = textAnswers[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let resolvedValue = (selectedValue == "__other__" || selectedValue?.isEmpty != false) ? typedValue : (selectedValue ?? "")
            guard !resolvedValue.isEmpty else { return [:] }
            answers[question.id] = AgentPromptAnswerPayload(answers: [resolvedValue])
        }
        return answers
    }
}

// MARK: - Window Picker Sheet

private struct WindowPickerSheet: View {
    let store: RemoteOSAppStore

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(store.session.windows) { window in
                        Button {
                            Task { await store.selectWindow(window) }
                        } label: {
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.roSurfaceRaised)
                                    .overlay {
                                        if let snapshot = store.session.snapshots[window.id] {
                                            snapshot.resizable().scaledToFill()
                                        } else {
                                            Image(systemName: "macwindow")
                                                .foregroundStyle(Color.roTextTertiary)
                                        }
                                    }
                                    .frame(width: 64, height: 48)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(window.ownerName)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(Color.roText)
                                    Text(window.title)
                                        .font(.system(size: 13))
                                        .foregroundStyle(Color.roTextSecondary)
                                        .lineLimit(2)
                                }

                                Spacer()

                                if store.session.selectedWindowID == window.id {
                                    Circle()
                                        .fill(Color.roSuccess)
                                        .frame(width: 8, height: 8)
                                }
                            }
                            .padding(12)
                            .background(Color.roSurfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .background(Color.roSurface)
            .navigationTitle("Windows")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        store.session.isWindowSheetPresented = false
                    }
                    .foregroundStyle(Color.roAccent)
                }
            }
        }
    }
}

// MARK: - Settings Sheet

private struct SettingsSheet: View {
    let store: RemoteOSAppStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    settingsSection("Connection") {
                        settingsRow("Control plane", value: store.pairing.controlPlaneBaseURL)
                        Color.roBorder.frame(height: 1).padding(.horizontal, 16)
                        settingsRow("Client", value: store.pairing.clientName)
                        Color.roBorder.frame(height: 1).padding(.horizontal, 16)
                        settingsRow("Auth", value: store.pairing.isAuthenticated ? (store.pairing.signedInEmail ?? "Signed in") : "Not signed in")
                    }

                    settingsSection("Streaming") {
                        settingsRow("Profile", value: store.currentStreamProfile.rawValue)
                        Color.roBorder.frame(height: 1).padding(.horizontal, 16)
                        HStack {
                            Text("Low data mode")
                                .font(.subheadline)
                                .foregroundStyle(Color.roText)
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { store.settings.lowDataMode },
                                set: { store.settings.lowDataMode = $0 }
                            ))
                            .tint(Color.roAccent)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }

                    settingsSection("Actions") {
                        Button {
                            Task { await store.resetThread() }
                        } label: {
                            HStack {
                                Image(systemName: "plus.message")
                                    .font(.system(size: 14))
                                Text("New Chat")
                                    .font(.subheadline)
                                Spacer()
                            }
                            .foregroundStyle(Color.roAccent)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                    }

                    if !store.session.traceEvents.isEmpty {
                        settingsSection("Recent Traces") {
                            ForEach(store.session.traceEvents.prefix(6)) { event in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(event.kind)
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Color.roTextTertiary)
                                    Text(event.message)
                                        .font(.system(size: 13))
                                        .foregroundStyle(Color.roTextSecondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                            }
                        }
                    }

                    Button {
                        Task { await store.disconnect(clearAuthToken: store.requiresAuthentication) }
                    } label: {
                        Text(store.requiresAuthentication ? "Sign Out" : "Disconnect")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.roDanger)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.roDanger.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.vertical, 8)
            }
            .background(Color.roSurface)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        store.session.isSettingsPresented = false
                    }
                    .foregroundStyle(Color.roAccent)
                }
            }
        }
    }

    private func settingsSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.roTextTertiary)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            VStack(spacing: 0) {
                content()
            }
            .background(Color.roSurfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 16)
        }
    }

    private func settingsRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Color.roTextSecondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(Color.roText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Text Entry Sheet

private struct TextEntrySheet: View {
    let store: RemoteOSAppStore

    private let specialKeys = [
        "return", "tab", "escape", "delete",
        "up", "down", "left", "right",
        "command", "control", "option", "shift"
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                TextEditor(text: Binding(
                    get: { store.session.textEntryValue },
                    set: { store.session.textEntryValue = $0 }
                ))
                .font(.body)
                .foregroundStyle(Color.roText)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 120)
                .padding(14)
                .background(Color.roBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.roBorderActive, lineWidth: 1)
                )

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 8)], spacing: 8) {
                    ForEach(specialKeys, id: \.self) { key in
                        Button(key.capitalized) {
                            Task { await store.sendSpecialKey(key) }
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.roText)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(Color.roSurfaceRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }

                Button {
                    Task { await store.submitTextEntry() }
                } label: {
                    Text("Send Text")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.roBackground)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.roAccent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                Spacer()
            }
            .padding(20)
            .background(Color.roSurface)
            .navigationTitle("Keyboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        store.session.isTextEntryPresented = false
                    }
                    .foregroundStyle(Color.roAccent)
                }
            }
        }
    }
}

// MARK: - Helpers

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
            return "Bootstrapping\u{2026}"
        case .connecting:
            return "Connecting\u{2026}"
        case .error:
            return "Error"
        case .idle:
            return "Idle"
        }
    }
}
