import ScreenCaptureKit
import Testing
@testable import AppCore

@Test func singleWindowScreenshotConfigurationIgnoresShadows() {
    let configuration = ScreenshotService.singleWindowConfiguration(width: 1440, height: 900)
    #expect(configuration.width == 1440)
    #expect(configuration.height == 900)
    if #available(macOS 14.0, *) {
        #expect(configuration.ignoreShadowsSingleWindow == true)
    }
}

@Test func screenshotFrameGeometryPrefersCapturedScreenRectMetadata() {
    let screenRect = CGRect(x: 120, y: 240, width: 900, height: 700)
    let contentRect = CGRect(x: 16, y: 24, width: 884, height: 676)
    let attachments: [SCStreamFrameInfo: Any] = [
        .screenRect: screenRect.dictionaryRepresentation,
        .contentRect: contentRect.dictionaryRepresentation,
        .scaleFactor: NSNumber(value: 2.0)
    ]

    let geometry = ScreenshotService.frameGeometry(
        attachments: attachments,
        fallbackSourceRect: CGRect(x: 10, y: 20, width: 300, height: 200),
        fallbackScale: 1.0
    )

    #expect(geometry.screenRect == screenRect)
    #expect(geometry.contentRectInSurface == contentRect)
    #expect(geometry.scaleFactor == 2.0)
}

@Test func screenshotFrameGeometryFallsBackWhenMetadataIsMissing() {
    let geometry = ScreenshotService.frameGeometry(
        attachments: [:],
        fallbackSourceRect: CGRect(x: 10, y: 20, width: 300, height: 200),
        fallbackScale: 1.5
    )

    #expect(geometry.screenRect == CGRect(x: 10, y: 20, width: 300, height: 200))
    #expect(geometry.contentRectInSurface == nil)
    #expect(geometry.scaleFactor == 1.5)
}

@Test func screenshotFrameGeometryDoesNotTreatSurfaceContentRectAsGlobalScreenRect() {
    let surfaceContentRect = CGRect(x: 24, y: 36, width: 640, height: 480)
    let geometry = ScreenshotService.frameGeometry(
        attachments: [
            .contentRect: surfaceContentRect.dictionaryRepresentation,
            .scaleFactor: NSNumber(value: 2.0)
        ],
        fallbackSourceRect: CGRect(x: 300, y: 180, width: 640, height: 480),
        fallbackScale: 1.0
    )

    #expect(geometry.screenRect == CGRect(x: 300, y: 180, width: 640, height: 480))
    #expect(geometry.contentRectInSurface == surfaceContentRect)
}

@Test func screenshotContentRectPixelsScalesSurfaceCoordinatesIntoImagePixels() {
    let contentRectPixels = ScreenshotService.contentRectPixels(
        contentRectInSurface: CGRect(x: 12, y: 18, width: 400, height: 300),
        scaleFactor: 2.0,
        imageWidth: 900,
        imageHeight: 700
    )

    #expect(contentRectPixels == CGRect(x: 24, y: 36, width: 800, height: 600))
}

@Test func screenshotContentRectPixelsMapsPointSpaceWindowBoundsIntoImagePixels() {
    let contentRectPixels = ScreenshotService.contentRectPixels(
        contentRectPoints: CGRect(x: 136, y: 264, width: 884, height: 676),
        sourceRectPoints: CGRect(x: 120, y: 240, width: 900, height: 700),
        imageWidth: 1800,
        imageHeight: 1400
    )

    #expect(contentRectPixels == CGRect(x: 32, y: 48, width: 1768, height: 1352))
}
