import ScreenCaptureKit
import Testing
@testable import AppCore

@Test func singleWindowScreenshotConfigurationIncludesChildWindows() {
    let configuration = ScreenshotService.singleWindowConfiguration(width: 1440, height: 900)
    #expect(configuration.width == 1440)
    #expect(configuration.height == 900)
    if #available(macOS 14.2, *) {
        #expect(configuration.includeChildWindows == true)
    }
}
