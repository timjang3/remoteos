import AppKit
import XCTest
@testable import RemoteOSHost

@MainActor
final class ForegroundSessionCoordinatorTests: XCTestCase {
    func testMultipleForegroundSessionsKeepAccessoryUntilLastReasonEnds() {
        var appliedPolicies: [NSApplication.ActivationPolicy] = []
        let coordinator = ForegroundSessionCoordinator { policy in
            appliedPolicies.append(policy)
        }

        coordinator.beginForegroundSession(reason: .settingsWindow)
        XCTAssertEqual(appliedPolicies, [.regular])
        XCTAssertEqual(coordinator.activeReasons, [.settingsWindow])

        coordinator.beginForegroundSession(reason: .sparkleUpdate)
        XCTAssertEqual(appliedPolicies, [.regular])
        XCTAssertEqual(
            coordinator.activeReasons,
            [.settingsWindow, .sparkleUpdate]
        )

        coordinator.endForegroundSession(reason: .settingsWindow)
        XCTAssertEqual(appliedPolicies, [.regular])
        XCTAssertEqual(coordinator.activeReasons, [.sparkleUpdate])

        coordinator.endForegroundSession(reason: .sparkleUpdate)
        XCTAssertEqual(appliedPolicies, [.regular, .accessory])
        XCTAssertTrue(coordinator.activeReasons.isEmpty)
    }
}
