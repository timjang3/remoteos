import AppKit
import Foundation
@preconcurrency import Sparkle

enum ForegroundSessionReason: Hashable {
    case settingsWindow
    case sparkleUpdate
}

final class ForegroundSessionCoordinator {
    private let applyPolicy: (NSApplication.ActivationPolicy) -> Void
    private(set) var activeReasons: Set<ForegroundSessionReason> = []

    init(applyPolicy: @escaping (NSApplication.ActivationPolicy) -> Void) {
        self.applyPolicy = applyPolicy
    }

    func beginForegroundSession(reason: ForegroundSessionReason) {
        let inserted = activeReasons.insert(reason).inserted
        if inserted && activeReasons.count == 1 {
            applyPolicy(.regular)
        }
    }

    func endForegroundSession(reason: ForegroundSessionReason) {
        let removed = activeReasons.remove(reason) != nil
        if removed && activeReasons.isEmpty {
            applyPolicy(.accessory)
        }
    }
}

final class AppUpdater: NSObject, SPUStandardUserDriverDelegate {
    private let foregroundSessionCoordinator: ForegroundSessionCoordinator
    private var updaterController: SPUStandardUpdaterController?

    @MainActor
    init(foregroundSessionCoordinator: ForegroundSessionCoordinator) {
        self.foregroundSessionCoordinator = foregroundSessionCoordinator
        super.init()

        if Self.isSparkleConfigured {
            updaterController = SPUStandardUpdaterController(
                updaterDelegate: nil,
                userDriverDelegate: self
            )
        }
    }

    @MainActor
    var isAvailable: Bool {
        updaterController != nil
    }

    @MainActor
    var currentVersionDescription: String {
        let bundle = Bundle.main
        let shortVersion =
            (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "Unknown"
        let buildNumber = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        guard let buildNumber, !buildNumber.isEmpty else {
            return shortVersion
        }

        return "\(shortVersion) (\(buildNumber))"
    }

    @MainActor
    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        foregroundSessionCoordinator.beginForegroundSession(reason: .sparkleUpdate)
    }

    func standardUserDriverWillFinishUpdateSession() {
        foregroundSessionCoordinator.endForegroundSession(reason: .sparkleUpdate)
    }

    private static var isSparkleConfigured: Bool {
        let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        return !(feedURL?.isEmpty ?? true) && !(publicKey?.isEmpty ?? true)
    }
}
