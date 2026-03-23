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

@Test func globalPointMapsImagePixelsThroughCapturedContentRect() throws {
    let injector = InputEventInjector()
    let frame = makeCapturedFrame(
        width: 1000,
        height: 800,
        sourceRectPoints: WindowBounds(x: 100, y: 200, width: 800, height: 600),
        contentRectPixels: WindowBounds(x: 100, y: 50, width: 800, height: 600)
    )

    let point = try injector.globalPoint(frame: frame, x: 500, y: 350)

    #expect(point == CGPoint(x: 500, y: 500))
}

@Test func globalPointRejectsPixelsOutsideVisibleCapturedContent() {
    let injector = InputEventInjector()
    let frame = makeCapturedFrame(
        width: 1000,
        height: 800,
        sourceRectPoints: WindowBounds(x: 100, y: 200, width: 800, height: 600),
        contentRectPixels: WindowBounds(x: 100, y: 50, width: 800, height: 600)
    )

    do {
        _ = try injector.globalPoint(frame: frame, x: 80, y: 350)
        Issue.record("Expected pixels outside the visible content to fail.")
    } catch AppCoreError.invalidPayload(let message) {
        #expect(message.contains("outside the visible captured content"))
    } catch {
        Issue.record("Unexpected error: \(error.localizedDescription)")
    }
}
