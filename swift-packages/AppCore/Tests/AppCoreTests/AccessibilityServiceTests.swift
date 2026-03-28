import Testing
@testable import AppCore

private let inaccessibleWindow = WindowDescriptor(
    id: 42,
    ownerPid: 999,
    ownerName: "Test App",
    appBundleId: "com.example.test",
    title: "Test Window",
    bounds: WindowBounds(x: 10, y: 20, width: 400, height: 300),
    isOnScreen: true,
    capabilities: [.pixelFallback],
    semanticSummary: nil
)

@Test func accessibilityServiceFailsClosedWithoutTrust() {
    let service = AccessibilityService(isTrustedProvider: { false })

    let snapshot = service.snapshot(for: inaccessibleWindow)

    #expect(snapshot.windowId == inaccessibleWindow.id)
    #expect(snapshot.focused == nil)
    #expect(snapshot.elements.isEmpty)
    #expect(snapshot.summary == "No accessibility content was available for this window.")
    #expect(service.press(label: "Open", in: inaccessibleWindow) == false)
    #expect(service.type(text: "hello", into: "Name", in: inaccessibleWindow) == false)
    #expect(service.focus(window: inaccessibleWindow) == false)
    #expect(service.isFocused(window: inaccessibleWindow) == false)
    #expect(service.focusedWindowDescriptor(pid: inaccessibleWindow.ownerPid, knownWindows: [inaccessibleWindow]) == nil)
    #expect(service.windowBounds(for: inaccessibleWindow) == nil)
    #expect(service.windowElement(for: inaccessibleWindow) == nil)
}
