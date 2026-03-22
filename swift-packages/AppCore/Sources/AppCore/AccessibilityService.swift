@preconcurrency import ApplicationServices
import AppKit
import Foundation

public final class AccessibilityService: @unchecked Sendable {
    public init() {}

    public func snapshot(for window: WindowDescriptor) -> SemanticSnapshot {
        guard let windowElement = windowElement(for: window) else {
            return SemanticSnapshot(
                windowId: window.id,
                focused: nil,
                elements: [],
                summary: "No accessibility content was available for this window.",
                generatedAt: isoNow()
            )
        }

        let focused = focusedElement(for: window).flatMap(readElement)
        var elements: [SemanticElement] = []
        collectElements(in: windowElement, into: &elements, limit: 40)

        let summaryParts = elements.prefix(6).map { element in
            [element.role, element.title, element.value]
                .compactMap { $0 }
                .joined(separator: ": ")
        }

        return SemanticSnapshot(
            windowId: window.id,
            focused: focused,
            elements: elements,
            summary: summaryParts.isEmpty ? "No accessibility content was available for this window." : summaryParts.joined(separator: " • "),
            generatedAt: isoNow()
        )
    }

    public func press(label: String, in window: WindowDescriptor) -> Bool {
        guard let windowElement = windowElement(for: window) else {
            return false
        }
        return performAction(in: windowElement, matching: label, action: kAXPressAction as CFString)
    }

    public func type(text: String, into label: String, in window: WindowDescriptor) -> Bool {
        guard let windowElement = windowElement(for: window) else {
            return false
        }
        guard let element = findElement(in: windowElement, matching: label) else {
            return false
        }
        return AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef) == .success
    }

    @discardableResult
    public func focus(window: WindowDescriptor) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid_t(window.ownerPid)) else {
            return false
        }

        app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])

        if let windowElement = windowElement(for: window) {
            let appElement = AXUIElementCreateApplication(pid_t(window.ownerPid))
            _ = AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, windowElement)
            _ = AXUIElementSetAttributeValue(windowElement, kAXMainAttribute as CFString, kCFBooleanTrue)
            _ = AXUIElementSetAttributeValue(windowElement, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            _ = AXUIElementPerformAction(windowElement, kAXRaiseAction as CFString)
        }

        return isFocused(window: window)
    }

    public func isFocused(window: WindowDescriptor) -> Bool {
        guard let focused = focusedWindowElement(for: window.ownerPid) else {
            return false
        }
        if let expected = windowElement(for: window) {
            return CFEqual(focused, expected)
        }
        return matches(windowElement: focused, descriptor: window)
    }

    public func focusedWindowDescriptor(pid: Int, knownWindows: [WindowDescriptor]) -> WindowDescriptor? {
        guard let focused = focusedWindowElement(for: pid) else {
            return nil
        }
        return knownWindows.first(where: { $0.ownerPid == pid && matches(windowElement: focused, descriptor: $0) })
    }

    /// Returns the window's bounds from the Accessibility API (always correct,
    /// even when ScreenCaptureKit can't capture the window).  Coordinates are
    /// in the Quartz display coordinate space.
    public func windowBounds(for window: WindowDescriptor) -> CGRect? {
        guard let element = windowElement(for: window) else { return nil }
        guard let position = pointAttribute(kAXPositionAttribute as CFString, element: element),
              let size = sizeAttribute(kAXSizeAttribute as CFString, element: element) else { return nil }
        return CGRect(x: position.x, y: position.y, width: size.width, height: size.height)
    }

    public func windowElement(for window: WindowDescriptor) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid_t(window.ownerPid))
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success else {
            return nil
        }

        let windows = (windowsValue as? [AXUIElement]) ?? []
        return windows.first(where: { matches(windowElement: $0, descriptor: window) })
    }

    private func focusedElement(for window: WindowDescriptor) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid_t(window.ownerPid))
        var focusedElementValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElementValue) == .success else {
            return nil
        }
        guard let element = focusedElementValue else {
            return nil
        }
        let axElement = unsafeDowncast(element, to: AXUIElement.self)
        guard let windowElement = windowElement(for: window) else {
            return nil
        }
        guard isDescendant(axElement, of: windowElement) || matches(windowElement: axElement, descriptor: window) else {
            return nil
        }
        return axElement
    }

    private func focusedWindowElement(for pid: Int) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid_t(pid))
        var focusedWindowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindowValue) == .success else {
            return nil
        }
        guard let focusedWindowValue else {
            return nil
        }
        return unsafeDowncast(focusedWindowValue, to: AXUIElement.self)
    }

    private func performAction(in element: AXUIElement, matching label: String, action: CFString) -> Bool {
        if matches(element: element, label: label) {
            return AXUIElementPerformAction(element, action) == .success
        }

        var childrenValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
        let children = (childrenValue as? [AXUIElement]) ?? []
        for child in children {
            if performAction(in: child, matching: label, action: action) {
                return true
            }
        }
        return false
    }

    private func findElement(in element: AXUIElement, matching label: String) -> AXUIElement? {
        if matches(element: element, label: label) {
            return element
        }

        var childrenValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
        let children = (childrenValue as? [AXUIElement]) ?? []
        for child in children {
            if let match = findElement(in: child, matching: label) {
                return match
            }
        }
        return nil
    }

    private func collectElements(in element: AXUIElement, into elements: inout [SemanticElement], limit: Int) {
        guard elements.count < limit else {
            return
        }
        if let descriptor = readElement(element) {
            elements.append(descriptor)
        }

        var childrenValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
        let children = (childrenValue as? [AXUIElement]) ?? []
        for child in children {
            guard elements.count < limit else {
                return
            }
            collectElements(in: child, into: &elements, limit: limit)
        }
    }

    private func matches(windowElement element: AXUIElement, descriptor window: WindowDescriptor) -> Bool {
        let title = stringAttribute(kAXTitleAttribute as CFString, element: element)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedWindowTitle = window.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if let title, !title.isEmpty, title == normalizedWindowTitle {
            return true
        }

        guard
            let position = pointAttribute(kAXPositionAttribute as CFString, element: element),
            let size = sizeAttribute(kAXSizeAttribute as CFString, element: element)
        else {
            return false
        }

        let positionDelta = abs(position.x - window.bounds.x) + abs(position.y - window.bounds.y)
        let sizeDelta = abs(size.width - window.bounds.width) + abs(size.height - window.bounds.height)
        return positionDelta <= 12 && sizeDelta <= 12
    }

    private func matches(element: AXUIElement, label: String) -> Bool {
        let lowered = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else {
            return false
        }

        let candidates = [
            stringAttribute(kAXTitleAttribute as CFString, element: element),
            stringAttribute(kAXDescriptionAttribute as CFString, element: element),
            stringAttribute(kAXHelpAttribute as CFString, element: element),
            stringAttribute(kAXValueAttribute as CFString, element: element)
        ]

        return candidates
            .compactMap { $0?.lowercased() }
            .contains(where: { $0.contains(lowered) })
    }

    private func isDescendant(_ element: AXUIElement, of ancestor: AXUIElement) -> Bool {
        var currentElement: AXUIElement? = element
        while let candidate = currentElement {
            if CFEqual(candidate, ancestor) {
                return true
            }
            var parentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(candidate, kAXParentAttribute as CFString, &parentValue) == .success,
                  let parentValue
            else {
                return false
            }
            currentElement = unsafeDowncast(parentValue, to: AXUIElement.self)
        }
        return false
    }

    private func readElement(_ element: AXUIElement) -> SemanticElement? {
        let role = stringAttribute(kAXRoleAttribute as CFString, element: element) ?? "unknown"
        let title = stringAttribute(kAXTitleAttribute as CFString, element: element)
        let value = stringAttribute(kAXValueAttribute as CFString, element: element)
        let help = stringAttribute(kAXHelpAttribute as CFString, element: element)
        let enabled = boolAttribute(kAXEnabledAttribute as CFString, element: element)

        return SemanticElement(role: role, title: title, value: value, help: help, enabled: enabled)
    }

    private func stringAttribute(_ key: CFString, element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key, &value) == .success else {
            return nil
        }
        if let stringValue = value as? String {
            return stringValue
        }
        if let numberValue = value as? NSNumber {
            return numberValue.stringValue
        }
        return nil
    }

    private func boolAttribute(_ key: CFString, element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key, &value) == .success else {
            return nil
        }
        return value as? Bool
    }

    private func pointAttribute(_ key: CFString, element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key, &value) == .success,
              let axValue = value,
              CFGetTypeID(axValue) == AXValueGetTypeID()
        else {
            return nil
        }

        var point = CGPoint.zero
        return AXValueGetValue((axValue as! AXValue), .cgPoint, &point) ? point : nil
    }

    private func sizeAttribute(_ key: CFString, element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key, &value) == .success,
              let axValue = value,
              CFGetTypeID(axValue) == AXValueGetTypeID()
        else {
            return nil
        }

        var size = CGSize.zero
        return AXValueGetValue((axValue as! AXValue), .cgSize, &size) ? size : nil
    }
}
