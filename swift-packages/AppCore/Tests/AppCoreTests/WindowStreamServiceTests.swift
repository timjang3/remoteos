import ScreenCaptureKit
import Testing
@testable import AppCore

@Test func streamPixelSizePreservesSmallerWindows() {
    let size = WindowStreamService.streamPixelSize(width: 960, height: 600, maxLongEdge: 1280)
    #expect(size.width == 960)
    #expect(size.height == 600)
}

@Test func streamPixelSizeClampsLargeWindowsToTheConfiguredLongEdge() {
    let size = WindowStreamService.streamPixelSize(width: 2880, height: 1800, maxLongEdge: 1280)
    #expect(size.width == 1280)
    #expect(size.height == 800)
}

@Test func streamConfigurationIgnoresShadowsForSingleWindowCapture() {
    let configuration = WindowStreamService.streamConfiguration(sourceWidth: 1440, sourceHeight: 900)
    #expect(configuration.width == 1280)
    #expect(configuration.height == 800)
    if #available(macOS 14.0, *) {
        #expect(configuration.ignoreShadowsSingleWindow == true)
    }
}

@Test func displayRegionTranslatesWindowIntoDisplayCoordinates() {
    let region = WindowStreamService.displayRegion(
        windowRect: CGRect(x: 320, y: 240, width: 960, height: 600),
        displayFrame: CGRect(x: 100, y: 200, width: 1600, height: 900)
    )

    #expect(region.origin.x == 220)
    #expect(region.origin.y == 40)
    #expect(region.width == 960)
    #expect(region.height == 600)
}
