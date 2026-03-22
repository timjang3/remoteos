import AppKit
import Foundation
@preconcurrency import ScreenCaptureKit

public final class ScreenshotService: @unchecked Sendable {
    private let gate = CaptureGate()
    private let captureTimeout: Duration
    private let log = AppLogs.screenshot

    public init(captureTimeout: Duration = .seconds(8)) {
        self.captureTimeout = captureTimeout
    }

    public func capture(windowID: Int, topologyVersion: Int, reason: String = "capture", accessibilityBounds: CGRect? = nil) async throws -> CapturedFrame {
        let clock = ContinuousClock()
        let requestedAt = clock.now
        let shouldLogLifecycle = reason != "deck_snapshot"
        if shouldLogLifecycle {
            log.info("Capture requested windowId=\(windowID) reason=\(reason)")
        }

        do {
            let frame = try await gate.withPermit {
                let waitDuration = requestedAt.duration(to: clock.now)
                if shouldLogLifecycle {
                    self.log.info("Capture started windowId=\(windowID) reason=\(reason) wait=\(logDuration(waitDuration))")
                }

                let content = try await self.withTimeout(
                    duration: self.captureTimeout,
                    errorMessage: "Timed out loading shareable content for window \(windowID)."
                ) {
                    try await SCShareableContent.current
                }
                guard let window = content.windows.first(where: { Int($0.windowID) == windowID }) else {
                    throw AppCoreError.missingWindow
                }

                // Try per-window capture first; fall back to display-region
                // capture if ScreenCaptureKit rejects the window (e.g.
                // after permission changes or for certain app types).
                let (image, sourceRect, scale): (CGImage, CGRect, Double)
                do {
                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    let info = SCShareableContent.info(for: filter)
                    let configuration = SCStreamConfiguration()
                    configuration.width = max(Int(info.contentRect.width * CGFloat(info.pointPixelScale)), 1)
                    configuration.height = max(Int(info.contentRect.height * CGFloat(info.pointPixelScale)), 1)
                    configuration.showsCursor = true
                    configuration.capturesAudio = false

                    let captured = try await self.withTimeout(
                        duration: self.captureTimeout,
                        errorMessage: "Timed out capturing window \(windowID)."
                    ) {
                        try await self.captureImage(filter: filter, configuration: configuration)
                    }
                    image = captured
                    sourceRect = info.contentRect
                    scale = Double(info.pointPixelScale)
                } catch {
                    if shouldLogLifecycle {
                        self.log.warning("Per-window capture failed for \(windowID), trying display-region fallback: \(error.localizedDescription)")
                    }
                    // Use accessibility bounds (always correct) when available;
                    // SCWindow.frame can return wrong values for windows that
                    // ScreenCaptureKit can't capture per-window.
                    let fallbackRect = accessibilityBounds ?? window.frame
                    let result = try await self.captureDisplayRegion(
                        windowRect: fallbackRect,
                        displays: content.displays
                    )
                    image = result.image
                    sourceRect = result.sourceRect
                    scale = result.scale
                }

                let encoded = try self.encode(image: image)
                let bestRect = accessibilityBounds ?? window.frame
                let displayID = self.bestDisplayID(for: bestRect, displays: content.displays)

                return CapturedFrame(
                    windowId: Int(window.windowID),
                    frameId: UUID().uuidString,
                    capturedAt: isoNow(),
                    mimeType: "image/jpeg",
                    dataBase64: encoded.dataBase64,
                    width: image.width,
                    height: image.height,
                    displayID: displayID,
                    sourceRectPoints: sourceRect.asWindowBounds,
                    pointPixelScale: scale,
                    topologyVersion: topologyVersion
                )
            }

            if shouldLogLifecycle {
                log.info(
                    "Capture completed windowId=\(windowID) reason=\(reason) frameId=\(frame.frameId) size=\(frame.width)x\(frame.height) elapsed=\(logDuration(requestedAt.duration(to: clock.now)))"
                )
            }
            return frame
        } catch {
            if shouldLogLifecycle {
                log.error(
                    "Capture failed windowId=\(windowID) reason=\(reason) elapsed=\(logDuration(requestedAt.duration(to: clock.now))) error=\(error.localizedDescription)"
                )
            }
            throw error
        }
    }

    /// Captures a region of the display where the window is located and crops
    /// to the window bounds.  Used as a fallback when per-window capture fails.
    private func captureDisplayRegion(
        windowRect: CGRect,
        displays: [SCDisplay]
    ) async throws -> (image: CGImage, sourceRect: CGRect, scale: Double) {
        guard let display = displays.max(by: {
            windowRect.intersection($0.frame).area
                < windowRect.intersection($1.frame).area
        }) else {
            throw AppCoreError.invalidPayload("No display found for window region.")
        }

        let displayBounds = display.frame
        let scale = Double(NSScreen.screens
            .first(where: { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 == CGDirectDisplayID(display.displayID) })?
            .backingScaleFactor ?? 1.0)

        // Compute the window region relative to the display origin
        let regionInDisplay = CGRect(
            x: windowRect.origin.x - displayBounds.origin.x,
            y: windowRect.origin.y - displayBounds.origin.y,
            width: windowRect.width,
            height: windowRect.height
        )

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = regionInDisplay
        configuration.width = max(Int(windowRect.width * scale), 1)
        configuration.height = max(Int(windowRect.height * scale), 1)
        configuration.showsCursor = true
        configuration.capturesAudio = false

        let image = try await withTimeout(
            duration: captureTimeout,
            errorMessage: "Timed out capturing display region for window."
        ) {
            try await self.captureImage(filter: filter, configuration: configuration)
        }

        return (image: image, sourceRect: windowRect, scale: scale)
    }

    private func captureImage(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: AppCoreError.invalidResponse)
                }
            }
        }
    }

    private func encode(image: CGImage) throws -> (dataBase64: String, width: Int, height: Int) {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.78]) else {
            throw AppCoreError.invalidResponse
        }

        return (
            dataBase64: data.base64EncodedString(),
            width: image.width,
            height: image.height
        )
    }

    private func bestDisplayID(for frame: CGRect, displays: [SCDisplay]) -> Int? {
        let bestDisplay = displays.max { lhs, rhs in
            frame.intersection(lhs.frame).area < frame.intersection(rhs.frame).area
        }
        return bestDisplay.map { Int($0.displayID) }
    }

    private func withTimeout<T>(
        duration: Duration,
        errorMessage: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let box: UncheckedSendableBox<T> = try await withCheckedThrowingContinuation { continuation in
            let state = TimedOperationState(continuation)

            let operationTask = Task {
                do {
                    let value = try await operation()
                    state.resume(returning: UncheckedSendableBox(value: value))
                } catch {
                    state.resume(throwing: error)
                }
            }

            Task {
                try? await Task.sleep(for: duration)
                operationTask.cancel()
                state.resume(throwing: AppCoreError.invalidPayload(errorMessage))
            }
        }
        return box.value
    }
}

private actor CaptureGate {
    private var available = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withPermit<T>(_ operation: @Sendable () async throws -> T) async throws -> T {
        if available {
            available = false
        } else {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        defer {
            if waiters.isEmpty {
                available = true
            } else {
                waiters.removeFirst().resume()
            }
        }

        return try await operation()
    }
}

private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
}

private final class TimedOperationState<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}
