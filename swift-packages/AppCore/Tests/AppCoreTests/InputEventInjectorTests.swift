import CoreGraphics
import Foundation
import Testing
@testable import AppCore

private func makeCapturedFrame(
    width: Int = 800,
    height: Int = 600,
    sourceRectPoints: WindowBounds = WindowBounds(x: -1728, y: 25, width: 1440, height: 900)
) -> CapturedFrame {
    CapturedFrame(
        windowId: 42,
        frameId: "frame_1",
        capturedAt: "2026-03-20T17:10:00Z",
        mimeType: "image/png",
        dataBase64: "ZmFrZQ==",
        width: width,
        height: height,
        displayID: 1,
        sourceRectPoints: sourceRectPoints,
        pointPixelScale: 2,
        topologyVersion: 1
    )
}

@Test func globalPointMapsImagePixelsIntoDisplayCoordinates() throws {
    let injector = InputEventInjector()
    let frame = makeCapturedFrame()

    let point = try injector.globalPoint(frame: frame, x: 400, y: 300)

    #expect(point == CGPoint(x: -1008, y: 475))
}

@Test func globalPointRejectsCoordinatesOutsideTheCapturedWindow() {
    let injector = InputEventInjector()
    let frame = makeCapturedFrame()

    do {
        _ = try injector.globalPoint(frame: frame, x: 800, y: 300)
        Issue.record("Expected out-of-bounds coordinates to fail.")
    } catch AppCoreError.invalidPayload(let message) {
        #expect(message.contains("outside the captured window bounds"))
    } catch {
        Issue.record("Unexpected error: \(error.localizedDescription)")
    }
}
