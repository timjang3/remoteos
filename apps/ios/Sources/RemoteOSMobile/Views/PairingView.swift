import SwiftUI
import VisionKit

struct PairingView: View {
    let store: RemoteOSAppStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("RemoteOS")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                    Text("Pair your iPhone with the Mac control plane, then use the same live stream, prompts, and agent controls you already have on the web.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 16) {
                    labeledField(
                        title: "Control plane URL",
                        text: Binding(
                            get: { store.pairing.controlPlaneBaseURL },
                            set: { store.pairing.controlPlaneBaseURL = $0 }
                        ),
                        placeholder: "https://control.remoteos.app"
                    )

                    labeledField(
                        title: "Pairing code",
                        text: Binding(
                            get: { store.pairing.pairingCode },
                            set: { store.pairing.pairingCode = $0.uppercased() }
                        ),
                        placeholder: "ABC123"
                    )
                    .textInputAutocapitalization(.characters)

                    labeledField(
                        title: "Client name",
                        text: Binding(
                            get: { store.pairing.clientName },
                            set: { store.pairing.clientName = $0 }
                        ),
                        placeholder: "iPhone"
                    )
                }
                .padding(20)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))

                if let health = store.pairing.health {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            health.authMode == .required
                                ? (store.pairing.isAuthenticated ? "Hosted sign-in is ready." : "This control plane requires sign-in.")
                                : "Direct pairing is available.",
                            systemImage: health.authMode == .required ? "person.badge.key" : "bolt.horizontal"
                        )
                        .font(.headline)

                        if (health.googleAuthEnabled ?? false) && health.authMode == .required {
                            Text(store.pairing.isAuthenticated ? (store.pairing.signedInEmail ?? "Signed in with a bearer token.") : "Use the native Google sign-in flow before claiming the pairing code.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(18)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }

                VStack(spacing: 12) {
                    Button {
                        store.pairing.isScannerPresented = true
                    } label: {
                        Label("Scan pairing QR", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        Task {
                            await store.refreshHealth()
                        }
                    } label: {
                        Label(store.pairing.isCheckingHealth ? "Checking…" : "Check server", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.pairing.isCheckingHealth)

                    if store.requiresAuthentication {
                        Button {
                            Task {
                                await store.signIn()
                            }
                        } label: {
                            Label(
                                store.pairing.isAuthenticating ? "Signing in…" : (store.pairing.isAuthenticated ? "Signed in" : "Continue with Google"),
                                systemImage: "person.crop.circle.badge.checkmark"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(store.pairing.isAuthenticating || store.pairing.isAuthenticated)
                    }

                    Button {
                        Task {
                            await store.pair()
                        }
                    } label: {
                        Text(store.pairing.isPairing ? "Connecting…" : "Connect")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.canPair)
                }

                if let errorMessage = store.pairing.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .padding(24)
        }
        .sheet(
            isPresented: Binding(
                get: { store.pairing.isScannerPresented },
                set: { store.pairing.isScannerPresented = $0 }
            )
        ) {
            PairingScannerView(
                onCode: { value in
                    Task {
                        await store.applyScannedPairingLink(value)
                    }
                },
                onClose: {
                    store.pairing.isScannerPresented = false
                }
            )
        }
    }

    private func labeledField(
        title: String,
        text: Binding<String>,
        placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

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
                        Text("QR scanning is only available on supported iPhone hardware.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onClose)
                }
            }
            .navigationTitle("Scan Pairing QR")
            .navigationBarTitleDisplayMode(.inline)
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
            guard let item = addedItems.first else {
                return
            }
            if case let .barcode(barcode) = item, let payload = barcode.payloadStringValue {
                onCode(payload)
            }
        }
    }
}
