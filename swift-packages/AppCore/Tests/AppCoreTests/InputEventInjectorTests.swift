import CoreGraphics
import Foundation
import Testing
@testable import AppCore

private func makeCapturedFrame(
    width: Int = 800,
    height: Int = 600,
    sourceRectPoints: WindowBounds = WindowBounds(x: -1728, y: 25, width: 1440, height: 900),
    contentRectPixels: WindowBounds? = nil
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
        contentRectPixels: contentRectPixels,
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

@Test func globalPointUsesFullImageCoordinatesEvenWhenContentRectMetadataExists() throws {
    let injector = InputEventInjector()
    let frame = makeCapturedFrame(
        width: 1000,
        height: 800,
        sourceRectPoints: WindowBounds(x: 100, y: 200, width: 800, height: 600),
        contentRectPixels: WindowBounds(x: 100, y: 50, width: 800, height: 600)
    )

    let point = try injector.globalPoint(frame: frame, x: 100, y: 100)

    #expect(point == CGPoint(x: 180, y: 275))
}

@Test func globalPointAcceptsPixelsInPaddedRegionsOfTheSentImage() throws {
    let injector = InputEventInjector()
    let frame = makeCapturedFrame(
        width: 1000,
        height: 800,
        sourceRectPoints: WindowBounds(x: 100, y: 200, width: 800, height: 600),
        contentRectPixels: WindowBounds(x: 100, y: 50, width: 800, height: 600)
    )

    let point = try injector.globalPoint(frame: frame, x: 80, y: 350)

    #expect(point == CGPoint(x: 164, y: 462.5))
}

@Test func globalPointPrefersWindowBoundsWhenAvailable() throws {
    let injector = InputEventInjector()
    let frame = CapturedFrame(
        windowId: 42,
        frameId: "frame_1",
        capturedAt: "2026-03-20T17:10:00Z",
        mimeType: "image/png",
        dataBase64: "ZmFrZQ==",
        width: 1000,
        height: 800,
        displayID: 1,
        sourceRectPoints: WindowBounds(x: 100, y: 200, width: 820, height: 660),
        pointPixelScale: 2,
        windowBoundsPoints: WindowBounds(x: 120, y: 240, width: 800, height: 600),
        topologyVersion: 1
    )

    let point = try injector.globalPoint(frame: frame, x: 500, y: 400)

    #expect(point == CGPoint(x: 520, y: 540))
}

@Test func globalPointMapsImageTopToWindowTopInQuartzCoordinates() throws {
    let injector = InputEventInjector()
    let frame = makeCapturedFrame(
        width: 1600,
        height: 1200,
        sourceRectPoints: WindowBounds(x: 240, y: 260, width: 800, height: 600)
    )

    let point = try injector.globalPoint(frame: frame, x: 100, y: 100)

    #expect(point == CGPoint(x: 290, y: 310))
}
