import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

public final class WindowStreamService: NSObject, @unchecked Sendable {
    public var onFrame: (@Sendable (CapturedFrame) async -> Void)?
    public var onError: (@Sendable (Error) async -> Void)?

    private let log = AppLogs.screenshot
    private let outputQueue = DispatchQueue(label: "remoteos.window-stream.output")
    private let imageContext = CIContext()

    private var stream: SCStream?
    private var currentWindowID: Int?
    private var currentTopologyVersion = 0
    private var fallbackSourceRect = CGRect.zero
    private var fallbackPointPixelScale = 1.0
    static let maxStreamLongEdgePixels = 1280

    public override init() {
        super.init()
    }

    public func start(windowID: Int, topologyVersion: Int, windowBounds: CGRect? = nil) async throws {
        try await stop()

        let content = try await SCShareableContent.current
        guard let window = content.windows.first(where: { Int($0.windowID) == windowID }) else {
            throw AppCoreError.missingWindow
        }
        let preferredBounds = windowBounds ?? window.frame

        do {
            try await startSingleWindowCapture(
                window: window,
                preferredBounds: preferredBounds,
                windowID: windowID,
                topologyVersion: topologyVersion
            )
        } catch {
            log.warning("Per-window stream capture failed for \(windowID), using display-region fallback: \(error.localizedDescription)")
            try await startDisplayRegionCapture(
                windowID: windowID,
                topologyVersion: topologyVersion,
                windowRect: preferredBounds,
                displays: content.displays
            )
        }
    }

    public func stop() async throws {
        guard let stream else {
            return
        }

        self.stream = nil
        currentWindowID = nil
        try await stream.stopCapture()
    }

    private func startSingleWindowCapture(
        window: SCWindow,
        preferredBounds: CGRect,
        windowID: Int,
        topologyVersion: Int
    ) async throws {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let info = SCShareableContent.info(for: filter)
        let sourceWidth = max(Int(preferredBounds.width * CGFloat(info.pointPixelScale)), 1)
        let sourceHeight = max(Int(preferredBounds.height * CGFloat(info.pointPixelScale)), 1)
        let configuration = Self.streamConfiguration(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            ignoreSingleWindowShadows: true
        )

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)

        currentWindowID = windowID
        currentTopologyVersion = topologyVersion
        fallbackSourceRect = info.contentRect
        fallbackPointPixelScale = Double(info.pointPixelScale)
        self.stream = stream

        do {
            try await stream.startCapture()
        } catch {
            self.stream = nil
            currentWindowID = nil
            throw error
        }
    }

    private func startDisplayRegionCapture(
        windowID: Int,
        topologyVersion: Int,
        windowRect: CGRect,
        displays: [SCDisplay]
    ) async throws {
        guard let display = displays.max(by: {
            windowRect.intersection($0.frame).area
                < windowRect.intersection($1.frame).area
        }) else {
            throw AppCoreError.invalidPayload("No display found for window region.")
        }

        let pointPixelScale = Self.pointPixelScale(forDisplayID: CGDirectDisplayID(display.displayID))
        let regionInDisplay = Self.displayRegion(windowRect: windowRect, displayFrame: display.frame)
        let sourceWidth = max(Int(windowRect.width * CGFloat(pointPixelScale)), 1)
        let sourceHeight = max(Int(windowRect.height * CGFloat(pointPixelScale)), 1)
        let configuration = Self.streamConfiguration(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            ignoreSingleWindowShadows: false
        )
        configuration.sourceRect = regionInDisplay

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)

        currentWindowID = windowID
        currentTopologyVersion = topologyVersion
        fallbackSourceRect = windowRect
        fallbackPointPixelScale = pointPixelScale
        self.stream = stream

        do {
            try await stream.startCapture()
        } catch {
            self.stream = nil
            currentWindowID = nil
            throw error
        }
    }

    private func makeCapturedFrame(from sampleBuffer: CMSampleBuffer) -> CapturedFrame? {
        guard
            let windowID = currentWindowID,
            let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else {
            return nil
        }

        let attachments = frameAttachments(from: sampleBuffer)
        guard frameStatus(from: attachments).map({ $0 == .complete || $0 == .started }) ?? false else {
            return nil
        }

        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        guard let cgImage = imageContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        let geometry = ScreenshotService.frameGeometry(
            attachments: attachments,
            fallbackSourceRect: fallbackSourceRect,
            fallbackScale: fallbackPointPixelScale
        )
        let contentRectPixels = ScreenshotService.contentRectPixels(
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
            dataBase64: data.base64EncodedString(),
            width: cgImage.width,
            height: cgImage.height,
            displayID: bestDisplayID(for: geometry.screenRect),
            sourceRectPoints: geometry.screenRect.asWindowBounds,
            contentRectPixels: contentRectPixels?.asWindowBounds,
            pointPixelScale: geometry.scaleFactor,
            topologyVersion: currentTopologyVersion
        )
    }

    private func frameAttachments(from sampleBuffer: CMSampleBuffer) -> [SCStreamFrameInfo: Any] {
        guard
            let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let attachments = attachmentsArray.first
        else {
            return [:]
        }

        return attachments
    }

    private func frameStatus(from attachments: [SCStreamFrameInfo: Any]) -> SCFrameStatus? {
        guard let rawValue = (attachments[.status] as? NSNumber)?.intValue else {
            return nil
        }
        return SCFrameStatus(rawValue: rawValue)
    }

    private func bestDisplayID(for frame: CGRect) -> Int? {
        var activeDisplayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &activeDisplayCount) == .success, activeDisplayCount > 0 else {
            return nil
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(activeDisplayCount))
        guard CGGetActiveDisplayList(activeDisplayCount, &displays, &activeDisplayCount) == .success else {
            return nil
        }

        let best = displays.prefix(Int(activeDisplayCount)).max { lhs, rhs in
            frame.intersection(CGDisplayBounds(lhs)).area < frame.intersection(CGDisplayBounds(rhs)).area
        }

        return best.map(Int.init)
    }

    static func streamPixelSize(width: Int, height: Int, maxLongEdge: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0, maxLongEdge > 0 else {
            return (max(width, 1), max(height, 1))
        }

        let longEdge = max(width, height)
        guard longEdge > maxLongEdge else {
            return (width, height)
        }

        let scale = Double(maxLongEdge) / Double(longEdge)
        return (
            width: max(Int((Double(width) * scale).rounded()), 1),
            height: max(Int((Double(height) * scale).rounded()), 1)
        )
    }

    static func streamConfiguration(
        sourceWidth: Int,
        sourceHeight: Int,
        ignoreSingleWindowShadows: Bool = true
    ) -> SCStreamConfiguration {
        let streamSize = streamPixelSize(
            width: sourceWidth,
            height: sourceHeight,
            maxLongEdge: max(maxStreamLongEdgePixels, 1)
        )
        let configuration = SCStreamConfiguration()
        configuration.width = streamSize.width
        configuration.height = streamSize.height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 4)
        configuration.showsCursor = true
        configuration.capturesAudio = false
        if #available(macOS 14.0, *), ignoreSingleWindowShadows {
            configuration.ignoreShadowsSingleWindow = true
        }
        return configuration
    }

    static func displayRegion(windowRect: CGRect, displayFrame: CGRect) -> CGRect {
        CGRect(
            x: windowRect.origin.x - displayFrame.origin.x,
            y: windowRect.origin.y - displayFrame.origin.y,
            width: windowRect.width,
            height: windowRect.height
        )
    }

    private static func pointPixelScale(forDisplayID displayID: CGDirectDisplayID) -> Double {
        if let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == displayID
        }) {
            return Double(screen.backingScaleFactor)
        }
        return 1.0
    }
}

extension WindowStreamService: SCStreamOutput, SCStreamDelegate {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, self.stream === stream, let frame = makeCapturedFrame(from: sampleBuffer) else {
            return
        }

        Task { [onFrame] in
            await onFrame?(frame)
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard self.stream === stream else {
            return
        }

        self.stream = nil
        currentWindowID = nil

        Task { [onError] in
            await onError?(error)
        }
    }
}
