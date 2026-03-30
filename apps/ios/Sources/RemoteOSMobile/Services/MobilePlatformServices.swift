import AuthenticationServices
import AVFoundation
import Foundation
import Network
import Observation
import RemoteOSCore
import UIKit

struct DecodedFrame: Identifiable, @unchecked Sendable {
    let payload: WindowFramePayload
    let image: UIImage

    var id: String {
        payload.frameId
    }
}

struct DecodedSnapshot: @unchecked Sendable {
    let windowID: Int
    let image: UIImage
}

actor FramePipeline {
    func decodeFrame(_ payload: WindowFramePayload) async -> DecodedFrame? {
        await Task.detached(priority: .userInitiated) {
            guard let data = Data(base64Encoded: payload.dataBase64),
                  let image = UIImage(data: data) else {
                return nil
            }

            return DecodedFrame(payload: payload, image: image)
        }.value
    }

    func decodeSnapshot(_ payload: WindowSnapshotPayload) async -> DecodedSnapshot? {
        await Task.detached(priority: .utility) {
            guard let data = Data(base64Encoded: payload.dataBase64),
                  let image = UIImage(data: data) else {
                return nil
            }

            return DecodedSnapshot(windowID: payload.window.id, image: image)
        }.value
    }
}

@MainActor
@Observable
final class NetworkPathService {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.remoteos.mobile.network-monitor")

    var isExpensive = false
    var isConstrained = false
    var isConnected = true

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.isConnected = path.status == .satisfied
                self?.isExpensive = path.isExpensive
                self?.isConstrained = path.isConstrained
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    var recommendedProfile: StreamProfile {
        if isConstrained {
            return .lowData
        }
        if isExpensive {
            return .balanced
        }
        return .full
    }
}

@MainActor
final class MobileAuthCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        return window ?? ASPresentationAnchor()
    }

    func authenticate(
        startURL: URL,
        callbackScheme: String
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: startURL,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                    return
                }

                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume(throwing: AppCoreError.invalidPayload("Authentication was cancelled"))
            }

            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            if !session.start() {
                continuation.resume(throwing: AppCoreError.invalidPayload("Unable to start authentication"))
            }
        }
    }
}

struct RecordedAudio: Sendable {
    let data: Data
    let mimeType: String
    let filename: String
    let durationMs: Int
}

@MainActor
final class DictationRecorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var startedAt: Date?

    func start() async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)

        let permissionGranted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        guard permissionGranted else {
            throw AppCoreError.invalidPayload("Microphone permission was denied")
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        recorder.prepareToRecord()
        guard recorder.record() else {
            throw AppCoreError.invalidPayload("Failed to start audio recording")
        }

        self.recorder = recorder
        self.fileURL = url
        self.startedAt = Date()
    }

    func stop() async throws -> RecordedAudio {
        guard let recorder, let fileURL else {
            throw AppCoreError.invalidPayload("Recording has not started")
        }

        recorder.stop()
        self.recorder = nil
        self.fileURL = nil

        let data = try Data(contentsOf: fileURL)
        let durationMs = Int((Date().timeIntervalSince(startedAt ?? Date())) * 1000)
        try? FileManager.default.removeItem(at: fileURL)
        try AVAudioSession.sharedInstance().setActive(false)

        return RecordedAudio(
            data: data,
            mimeType: "audio/mp4",
            filename: "dictation.m4a",
            durationMs: durationMs
        )
    }

    func cancel() {
        recorder?.stop()
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        recorder = nil
        fileURL = nil
        startedAt = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }
}
