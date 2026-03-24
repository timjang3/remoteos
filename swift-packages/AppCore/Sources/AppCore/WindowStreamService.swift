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

    private let outputQueue = DispatchQueue(label: "remoteos.window-stream.output")
    private let imageContext = CIContext()

    private var stream: SCStream?
    private var currentWindowID: Int?
    private var currentTopologyVersion = 0
    private var fallbackSourceRect = CGRect.zero
    private var fallbackPointPixelScale = 1.0
    private static let maxStreamLongEdgePixels = 1280

    public override init() {
        super.init()
    }

    public func start(windowID: Int, topologyVersion: Int) async throws {
        try await stop()

        let content = try await SCShareableContent.current
        guard let window = content.windows.first(where: { Int($0.windowID) == windowID }) else {
            throw AppCoreError.missingWindow
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let info = SCShareableContent.info(for: filter)
        let sourceWidth = max(Int(window.frame.width * CGFloat(info.pointPixelScale)), 1)
        let sourceHeight = max(Int(window.frame.height * CGFloat(info.pointPixelScale)), 1)
        let configuration = Self.streamConfiguration(sourceWidth: sourceWidth, sourceHeight: sourceHeight)

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

    public func stop() async throws {
        guard let stream else {
            return
        }

        self.stream = nil
        currentWindowID = nil
        try await stream.stopCapture()
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

    static func streamConfiguration(sourceWidth: Int, sourceHeight: Int) -> SCStreamConfiguration {
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
        if #available(macOS 14.0, *) {
            configuration.ignoreShadowsSingleWindow = true
        }
        return configuration
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
