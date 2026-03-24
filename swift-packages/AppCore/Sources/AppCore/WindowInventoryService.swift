import AppKit
import Foundation
import ScreenCaptureKit

public final class WindowInventoryService: @unchecked Sendable {
    private let permissionCoordinator: PermissionCoordinator

    public init(permissionCoordinator: PermissionCoordinator) {
        self.permissionCoordinator = permissionCoordinator
    }

    public func listWindows() async -> [WindowDescriptor] {
        let permissions = permissionCoordinator.snapshot()

        do {
            let content = try await SCShareableContent.current
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

                return WindowDescriptor(
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
