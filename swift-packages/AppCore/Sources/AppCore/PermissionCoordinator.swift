@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation

public struct PermissionSnapshot: Sendable {
    public var screenRecording: PermissionStatus
    public var accessibility: PermissionStatus

    public init(screenRecording: PermissionStatus, accessibility: PermissionStatus) {
        self.screenRecording = screenRecording
        self.accessibility = accessibility
    }
}

public final class PermissionCoordinator: @unchecked Sendable {
    public init() {}

    public func snapshot() -> PermissionSnapshot {
        PermissionSnapshot(
            screenRecording: CGPreflightScreenCaptureAccess() ? .granted : .needsPrompt,
            accessibility: AXIsProcessTrusted() ? .granted : .needsPrompt
        )
    }

    @discardableResult
    public func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    @discardableResult
    public func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
