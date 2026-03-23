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
