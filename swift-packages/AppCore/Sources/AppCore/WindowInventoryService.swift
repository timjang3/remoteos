import AppKit
import Foundation
import ScreenCaptureKit

public final class WindowInventoryService: @unchecked Sendable {
    private let permissionSnapshotProvider: @Sendable () -> PermissionSnapshot
    private let accessibilityService: AccessibilityService
    private let shareableContentProvider: @Sendable () async throws -> SCShareableContent

    public init(permissionCoordinator: PermissionCoordinator) {
        self.permissionSnapshotProvider = { permissionCoordinator.snapshot() }
        self.accessibilityService = AccessibilityService()
        self.shareableContentProvider = {
            try await SCShareableContent.current
        }
    }

    init(
        permissionSnapshotProvider: @escaping @Sendable () -> PermissionSnapshot,
        accessibilityService: AccessibilityService = AccessibilityService(),
        shareableContentProvider: @escaping @Sendable () async throws -> SCShareableContent = {
            try await SCShareableContent.current
        }
    ) {
        self.permissionSnapshotProvider = permissionSnapshotProvider
        self.accessibilityService = accessibilityService
        self.shareableContentProvider = shareableContentProvider
    }

    public func listWindows() async -> [WindowDescriptor] {
        let permissions = permissionSnapshotProvider()
        guard permissions.screenRecording == .granted else {
            return []
        }

        do {
            let content = try await shareableContentProvider()
            return content.windows.compactMap { window in
                guard
                    window.windowLayer == 0,
                    window.isOnScreen,
                    window.frame.width > 100,
                    window.frame.height > 80,
                    let owner = window.owningApplication
                else {
                    return nil
                }

                let runningApp = NSRunningApplication(processIdentifier: owner.processID)

                // Only include windows from regular (user-facing) applications.
                // Helper processes (autofill, spell-check, etc.) use .accessory
                // or .prohibited and should not appear in the window list.
                guard runningApp?.activationPolicy == .regular else {
                    return nil
                }

                let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                let ownerName = owner.applicationName
                let bundleID = runningApp?.bundleIdentifier ?? owner.bundleIdentifier

                var capabilities: [WindowCapability] = [.pixelFallback]
                if permissions.accessibility == .granted {
                    capabilities.append(.axRead)
                    capabilities.append(.axWrite)
                }
                if bundleID.localizedCaseInsensitiveContains("electron") {
                    capabilities.append(.genericElectron)
                }

                var descriptor = WindowDescriptor(
                    id: Int(window.windowID),
                    ownerPid: Int(owner.processID),
                    ownerName: ownerName,
                    appBundleId: bundleID,
                    title: title?.isEmpty == false ? title! : ownerName,
                    bounds: window.frame.asWindowBounds,
                    isOnScreen: window.isOnScreen,
                    capabilities: Array(Set(capabilities)).sorted { $0.rawValue < $1.rawValue },
                    semanticSummary: nil
                )

                if permissions.accessibility == .granted,
                   let axRect = accessibilityService.windowBounds(for: descriptor)
                {
                    descriptor.bounds = axRect.asWindowBounds
                }

                return descriptor
            }
            .sorted { lhs, rhs in
                if lhs.ownerName != rhs.ownerName {
                    return lhs.ownerName < rhs.ownerName
                }
                return lhs.title < rhs.title
            }
        } catch {
            return []
        }
    }
}
