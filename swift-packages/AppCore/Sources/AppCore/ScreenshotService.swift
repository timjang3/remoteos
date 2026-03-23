import AppKit
import CoreImage
import CoreMedia
import Foundation
import ImageIO
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

public final class ScreenshotService: @unchecked Sendable {
    private let gate = CaptureGate()
    private let captureTimeout: Duration
    private let imageContext = CIContext()
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
                let capturedFrame: CapturedFrame
                do {
                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    let info = SCShareableContent.info(for: filter)
                    let configuration = Self.singleWindowConfiguration(
                        width: max(Int(info.contentRect.width * CGFloat(info.pointPixelScale)), 1),
                        height: max(Int(info.contentRect.height * CGFloat(info.pointPixelScale)), 1)
                    )

                    let captured = try await self.withTimeout(
                        duration: self.captureTimeout,
                        errorMessage: "Timed out capturing window \(windowID)."
                    ) {
                        try await self.captureFrame(
                            windowID: Int(window.windowID),
                            topologyVersion: topologyVersion,
                            filter: filter,
                            configuration: configuration,
                            windowBounds: (accessibilityBounds ?? window.frame),
                            fallbackSourceRect: info.contentRect,
                            fallbackScale: Double(info.pointPixelScale),
                            displays: content.displays
                        )
                    }
                    capturedFrame = captured
                } catch {
                    if shouldLogLifecycle {
                        self.log.warning("Per-window capture failed for \(windowID), trying display-region fallback: \(error.localizedDescription)")
                    }
                    // Use accessibility bounds (always correct) when available;
                    // SCWindow.frame can return wrong values for windows that
                    // ScreenCaptureKit can't capture per-window.
                    let fallbackRect = accessibilityBounds ?? window.frame
                    let result = try await self.captureDisplayRegion(
                        windowID: Int(window.windowID),
                        topologyVersion: topologyVersion,
                        windowRect: fallbackRect,
                        displays: content.displays
                    )
                    capturedFrame = result
                }

                return capturedFrame
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
        windowID: Int,
        topologyVersion: Int,
        windowRect: CGRect,
        displays: [SCDisplay]
    ) async throws -> CapturedFrame {
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
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.sourceRect = regionInDisplay
        configuration.width = max(Int(windowRect.width * scale), 1)
        configuration.height = max(Int(windowRect.height * scale), 1)
        configuration.showsCursor = true
        configuration.capturesAudio = false

        return try await withTimeout(
            duration: captureTimeout,
            errorMessage: "Timed out capturing display region for window."
        ) {
            try await self.captureFrame(
                windowID: windowID,
                topologyVersion: topologyVersion,
                filter: filter,
                configuration: configuration,
                windowBounds: windowRect,
                fallbackSourceRect: windowRect,
                fallbackScale: scale,
                displays: displays
            )
        }
    }

    private func captureFrame(
        windowID: Int,
        topologyVersion: Int,
        filter: SCContentFilter,
        configuration: SCStreamConfiguration,
        windowBounds: CGRect,
        fallbackSourceRect: CGRect,
        fallbackScale: Double,
        displays: [SCDisplay]
    ) async throws -> CapturedFrame {
        let sampleBuffer = try await captureSampleBuffer(filter: filter, configuration: configuration)
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw AppCoreError.invalidResponse
        }

        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        guard let cgImage = imageContext.createCGImage(ciImage, from: ciImage.extent) else {
            throw AppCoreError.invalidResponse
        }

        let geometry = Self.frameGeometry(
            attachments: Self.frameAttachments(from: sampleBuffer),
            fallbackSourceRect: fallbackSourceRect,
            fallbackScale: fallbackScale
        )
        let encoded = try encode(image: cgImage)
        let displayID = bestDisplayID(for: geometry.screenRect, displays: displays)
        let contentRectPixels = Self.contentRectPixels(
            contentRectInSurface: geometry.contentRectInSurface,
            scaleFactor: geometry.scaleFactor,
            imageWidth: cgImage.width,
            imageHeight: cgImage.height
        )

        return CapturedFrame(
            windowId: windowID,
            frameId: UUID().uuidString,
            capturedAt: isoNow(),
            mimeType: "image/jpeg",
            dataBase64: encoded.dataBase64,
            width: cgImage.width,
            height: cgImage.height,
            displayID: displayID,
            sourceRectPoints: geometry.screenRect.asWindowBounds,
            contentRectPixels: contentRectPixels?.asWindowBounds,
            pointPixelScale: geometry.scaleFactor,
            windowBoundsPoints: windowBounds.asWindowBounds,
            topologyVersion: topologyVersion
        )
    }

    private func captureSampleBuffer(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CMSampleBuffer {
        let box: UncheckedSendableBox<CMSampleBuffer> = try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: configuration) { sampleBuffer, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let sampleBuffer {
                    continuation.resume(returning: UncheckedSendableBox(value: sampleBuffer))
                } else {
                    continuation.resume(throwing: AppCoreError.invalidResponse)
                }
            }
        }
        return box.value
    }

    private func encode(image: CGImage) throws -> (dataBase64: String, width: Int, height: Int) {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw AppCoreError.invalidResponse
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw AppCoreError.invalidResponse
        }

        return (
            dataBase64: data.base64EncodedString(),
            width: image.width,
            height: image.height
        )
    }

    static func singleWindowConfiguration(width: Int, height: Int) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.width = max(width, 1)
        configuration.height = max(height, 1)
        configuration.showsCursor = true
        configuration.capturesAudio = false
        if #available(macOS 14.2, *) {
            configuration.includeChildWindows = true
        }
        return configuration
    }

    static func frameAttachments(from sampleBuffer: CMSampleBuffer) -> [SCStreamFrameInfo: Any] {
        guard
            let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let attachments = attachmentsArray.first
        else {
            return [:]
        }

        return attachments
    }

    struct FrameGeometry: Equatable {
        var screenRect: CGRect
        var contentRectInSurface: CGRect?
        var scaleFactor: Double
    }

    static func frameGeometry(
        attachments: [SCStreamFrameInfo: Any],
        fallbackSourceRect: CGRect,
        fallbackScale: Double
    ) -> FrameGeometry {
        let scaleFactor = attachments[.scaleFactor]
            .flatMap { ($0 as? NSNumber)?.doubleValue }
            ?? fallbackScale
        return FrameGeometry(
            screenRect: rectAttachment(attachments[.screenRect]) ?? fallbackSourceRect,
            contentRectInSurface: rectAttachment(attachments[.contentRect]),
            scaleFactor: scaleFactor
        )
    }

    static func contentRectPixels(
        contentRectInSurface: CGRect?,
        scaleFactor: Double,
        imageWidth: Int,
        imageHeight: Int
    ) -> CGRect? {
        guard
            let contentRectInSurface,
            contentRectInSurface.width > 0,
            contentRectInSurface.height > 0,
            scaleFactor > 0,
            imageWidth > 0,
            imageHeight > 0
        else {
            return nil
        }

        let scaledRect = CGRect(
            x: contentRectInSurface.origin.x * scaleFactor,
            y: contentRectInSurface.origin.y * scaleFactor,
            width: contentRectInSurface.width * scaleFactor,
            height: contentRectInSurface.height * scaleFactor
        )
        let imageBounds = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        let clampedRect = scaledRect.intersection(imageBounds)

        guard !clampedRect.isNull, !clampedRect.isEmpty else {
            return nil
        }
        if clampedRect.equalTo(imageBounds) {
            return nil
        }
        return clampedRect
    }

    private static func rectAttachment(_ value: Any?) -> CGRect? {
        if let value = value as? NSValue {
            return value.rectValue
        }
        if let dictionary = value as? NSDictionary {
            return CGRect(dictionaryRepresentation: dictionary)
        }
        return nil
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
