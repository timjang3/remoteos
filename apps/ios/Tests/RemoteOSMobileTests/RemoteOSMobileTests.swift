import XCTest
@testable import RemoteOSMobile

final class RemoteOSMobileTests: XCTestCase {
    @MainActor
    func testAvailableModelsStayInSyncWithTheWebClientList() {
        XCTAssertEqual(RemoteOSAppStore.availableModels.count, 8)
        XCTAssertEqual(RemoteOSAppStore.availableModels.first?.id, "gpt-5.4")
    }
}
