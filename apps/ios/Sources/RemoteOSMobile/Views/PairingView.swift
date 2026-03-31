import SwiftUI
import RemoteOSCore
import VisionKit

struct PairingView: View {
    let store: RemoteOSAppStore

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Logo & header
                VStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.roSurface, Color.roBackground],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 72, height: 72)
                        .overlay(
                            Image(systemName: "desktopcomputer")
                                .font(.system(size: 28, weight: .light))
                                .foregroundStyle(Color.roAccent)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )

                    Text("RemoteOS")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Color.roText)

                    Text("Pair with your Mac control plane to stream, prompt, and control remotely.")
                        .font(.subheadline)
                        .foregroundStyle(Color.roTextSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
                .padding(.top, 32)

                // Input card
                VStack(spacing: 16) {
                    fieldGroup(
                        label: "Control plane URL",
                        text: Binding(
                            get: { store.pairing.controlPlaneBaseURL },
                            set: { store.pairing.controlPlaneBaseURL = $0 }
                        ),
                        placeholder: "https://control.remoteos.app"
                    )

                    fieldGroup(
                        label: "Pairing code",
                        text: Binding(
                            get: { store.pairing.pairingCode },
                            set: { store.pairing.pairingCode = $0.uppercased() }
                        ),
                        placeholder: "ABC123"
                    )
                    .textInputAutocapitalization(.characters)

                    fieldGroup(
                        label: "Client name",
                        text: Binding(
                            get: { store.pairing.clientName },
                            set: { store.pairing.clientName = $0 }
                        ),
                        placeholder: "iPhone"
                    )
                }
                .padding(20)
                .background(Color.roSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.roBorder, lineWidth: 1)
                )

                // Health status
                if let health = store.pairing.health {
                    healthCard(health)
                }

                // Action buttons
                VStack(spacing: 10) {
                    Button {
                        store.pairing.isScannerPresented = true
                    } label: {
                        Label("Scan Pairing QR", systemImage: "qrcode.viewfinder")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.roBackground)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(Color.roAccent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    Button {
                        Task { await store.refreshHealth() }
                    } label: {
                        Label(
                            store.pairing.isCheckingHealth ? "Checking\u{2026}" : "Check Server",
                            systemImage: "arrow.clockwise"
                        )
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.roText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Color.roSurfaceRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .disabled(store.pairing.isCheckingHealth)
                    .opacity(store.pairing.isCheckingHealth ? 0.6 : 1)

                    if store.requiresAuthentication {
                        Button {
                            Task { await store.signIn() }
                        } label: {
                            Label(
                                store.pairing.isAuthenticating ? "Signing in\u{2026}" : (store.pairing.isAuthenticated ? "Signed In" : "Continue with Google"),
                                systemImage: "person.crop.circle.badge.checkmark"
                            )
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color.roText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(Color.roSurfaceRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .disabled(store.pairing.isAuthenticating || store.pairing.isAuthenticated)
                        .opacity((store.pairing.isAuthenticating || store.pairing.isAuthenticated) ? 0.6 : 1)
                    }

                    Button {
                        Task { await store.pair() }
                    } label: {
                        Text(store.pairing.isPairing ? "Connecting\u{2026}" : "Connect")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.roBackground)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(Color.roAccent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .disabled(!store.canPair)
                    .opacity(store.canPair ? 1 : 0.5)
                }

                // Error
                if let errorMessage = store.pairing.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(Color.roDanger)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .background(
            ZStack {
                Color.roBackground
                RadialGradient(
                    colors: [Color.roAccent.opacity(0.08), Color.clear],
                    center: .top,
                    startRadius: 0,
                    endRadius: 400
                )
            }
        )
        .sheet(
            isPresented: Binding(
                get: { store.pairing.isScannerPresented },
                set: { store.pairing.isScannerPresented = $0 }
            )
        ) {
            PairingScannerView(
                onCode: { value in
                    Task { await store.applyScannedPairingLink(value) }
                },
                onClose: {
                    store.pairing.isScannerPresented = false
                }
            )
        }
    }

    // MARK: - Components

    private func fieldGroup(label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.roTextSecondary)
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body)
                .foregroundStyle(Color.roText)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color.roBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.roBorder, lineWidth: 1)
                )
        }
    }

    private func healthCard(_ health: ControlPlaneHealthPayload) -> some View {
        HStack(spacing: 12) {
            Image(systemName: health.authMode == .required ? "person.badge.key" : "bolt.horizontal")
                .font(.system(size: 20))
                .foregroundStyle(Color.roAccent)

            VStack(alignment: .leading, spacing: 4) {
                Text(
                    health.authMode == .required
                        ? (store.pairing.isAuthenticated ? "Sign-in ready" : "Sign-in required")
                        : "Direct pairing available"
                )
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.roText)

                if (health.googleAuthEnabled ?? false) && health.authMode == .required {
                    Text(
                        store.pairing.isAuthenticated
                            ? (store.pairing.signedInEmail ?? "Authenticated")
                            : "Sign in with Google to continue"
                    )
                    .font(.system(size: 13))
                    .foregroundStyle(Color.roTextSecondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.roSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.roBorder, lineWidth: 1)
        )
    }
}

// MARK: - Scanner

private struct PairingScannerView: View {
    let onCode: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    QRScannerRepresentable(onCode: onCode)
                        .ignoresSafeArea()
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.metering.unknown")
                            .font(.system(size: 40))
                            .foregroundStyle(Color.roTextTertiary)
                        Text("QR scanning requires supported hardware.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Color.roTextSecondary)
                    }
                    .padding()
                }
            }
            .background(Color.roBackground)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onClose)
                        .foregroundStyle(Color.roAccent)
                }
            }
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }
}

private struct QRScannerRepresentable: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didTapOn item: RecognizedItem
        ) {
            if case let .barcode(barcode) = item, let payload = barcode.payloadStringValue {
                onCode(payload)
            }
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard let item = addedItems.first else { return }
            if case let .barcode(barcode) = item, let payload = barcode.payloadStringValue {
                onCode(payload)
            }
        }
    }
}
