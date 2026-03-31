import XCTest

final class RemoteOSMobileUITests: XCTestCase {
    @MainActor
    func testLaunches() {
        let app = XCUIApplication()
        app.launch()
    }
}
