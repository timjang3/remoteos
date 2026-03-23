import CoreGraphics
import Foundation

public enum InputMouseButton: String, Sendable {
    case left
    case right
    case middle
}

public final class InputEventInjector: @unchecked Sendable {
    public init() {}

    public func tap(frame: CapturedFrame, normalizedX: Double, normalizedY: Double, clickCount: Int) {
        click(
            frame: frame,
            normalizedX: normalizedX,
            normalizedY: normalizedY,
            button: .left,
            clickCount: clickCount
        )
    }

    public func drag(frame: CapturedFrame, fromX: Double, fromY: Double, toX: Double, toY: Double) {
        let fromPoint = CGPoint(
            x: min(max(fromX, 0), 0.999_999_999_999) * Double(frame.width),
            y: min(max(fromY, 0), 0.999_999_999_999) * Double(frame.height)
        )
        let toPoint = CGPoint(
            x: min(max(toX, 0), 0.999_999_999_999) * Double(frame.width),
            y: min(max(toY, 0), 0.999_999_999_999) * Double(frame.height)
        )
        guard
            let globalFrom = try? globalPoint(frame: frame, x: fromPoint.x, y: fromPoint.y),
            let globalTo = try? globalPoint(frame: frame, x: toPoint.x, y: toPoint.y)
        else {
            return
        }
        drag(globalPath: [globalFrom, globalTo], button: .left)
    }

    public func scroll(frame: CapturedFrame, deltaX: Double, deltaY: Double) {
        scroll(point: centerPoint(for: frame), deltaX: deltaX, deltaY: deltaY)
    }

    public func move(frame: CapturedFrame, x: Double, y: Double) throws {
        let point = try globalPoint(frame: frame, x: x, y: y)
        moveCursor(to: point)
    }

    public func click(
        frame: CapturedFrame,
        x: Double,
        y: Double,
        button: InputMouseButton = .left,
        clickCount: Int = 1
    ) throws {
        let point = try globalPoint(frame: frame, x: x, y: y)
        click(globalPoint: point, button: button, clickCount: clickCount)
    }

    public func click(
        frame: CapturedFrame,
        normalizedX: Double,
        normalizedY: Double,
        button: InputMouseButton = .left,
        clickCount: Int = 1
    ) {
        let clampedX = min(max(normalizedX, 0), 0.999_999_999_999)
        let clampedY = min(max(normalizedY, 0), 0.999_999_999_999)
        let imageX = clampedX * Double(frame.width)
        let imageY = clampedY * Double(frame.height)
        guard let point = try? globalPoint(frame: frame, x: imageX, y: imageY) else {
            return
        }
        click(globalPoint: point, button: button, clickCount: clickCount)
    }

    public func drag(
        frame: CapturedFrame,
        path: [CGPoint],
        button: InputMouseButton = .left
    ) throws {
        let globalPath = try path.map { point in
            try globalPoint(frame: frame, x: point.x, y: point.y)
        }
        drag(globalPath: globalPath, button: button)
    }

    public func scroll(
        frame: CapturedFrame,
        x: Double,
        y: Double,
        deltaX: Double,
        deltaY: Double
    ) throws {
        let point = try globalPoint(frame: frame, x: x, y: y)
        scroll(point: point, deltaX: deltaX, deltaY: deltaY)
    }

    public func type(text: String) {
        for scalar in text.utf16 {
            var buffer = [UniChar(scalar)]
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &buffer)
            down?.post(tap: .cghidEventTap)

            let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &buffer)
            up?.post(tap: .cghidEventTap)
        }
    }

    public func key(named key: String) -> Bool {
        keypress(keys: [key])
    }

    public func keypress(keys: [String]) -> Bool {
        let normalizedKeys = keys
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalizedKeys.isEmpty else {
            return false
        }

        let modifierFlags = normalizedKeys.dropLast().compactMap(Self.modifierFlag(for:))
        let flags = modifierFlags.reduce(CGEventFlags()) { partial, flag in
            partial.union(flag)
        }
        let finalKey = normalizedKeys.last ?? ""

        if let finalModifier = Self.modifierFlag(for: finalKey) {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
            event?.flags = flags.union(finalModifier)
            event?.post(tap: .cghidEventTap)

            let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            keyUp?.flags = flags
            keyUp?.post(tap: .cghidEventTap)
            return true
        }

        guard let keyCode = Self.keyCode(for: finalKey) else {
            return false
        }

        let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)

        let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
        return true
    }

    public func normalizedPoint(frame: CapturedFrame, x: Double, y: Double) -> (Double, Double) {
        let contentRect = contentRectPixels(for: frame)
        let normalizedX = (x - contentRect.x) / contentRect.width
        let normalizedY = (y - contentRect.y) / contentRect.height
        return (normalizedX, normalizedY)
    }

    public func globalPoint(frame: CapturedFrame, x: Double, y: Double) throws -> CGPoint {
        guard x >= 0, y >= 0, x < Double(frame.width), y < Double(frame.height) else {
            throw AppCoreError.invalidPayload(
                "Coordinates (\(Int(x.rounded())), \(Int(y.rounded()))) are outside the captured window bounds."
            )
        }
        let normalized = normalizedPoint(frame: frame, x: x, y: y)
        guard normalized.0 >= 0, normalized.1 >= 0, normalized.0 <= 1, normalized.1 <= 1 else {
            throw AppCoreError.invalidPayload(
                "Coordinates (\(Int(x.rounded())), \(Int(y.rounded()))) are outside the visible captured content."
            )
        }
        return point(for: frame, normalizedX: normalized.0, normalizedY: normalized.1)
    }

    private func point(for frame: CapturedFrame, normalizedX: Double, normalizedY: Double) -> CGPoint {
        CGPoint(
            x: frame.sourceRectPoints.x + (frame.sourceRectPoints.width * normalizedX),
            y: frame.sourceRectPoints.y + (frame.sourceRectPoints.height * normalizedY)
        )
    }

    private func centerPoint(for frame: CapturedFrame) -> CGPoint {
        let contentRect = contentRectPixels(for: frame)
        let imagePoint = CGPoint(
            x: contentRect.x + (contentRect.width / 2),
            y: contentRect.y + (contentRect.height / 2)
        )
        return (try? globalPoint(frame: frame, x: imagePoint.x, y: imagePoint.y))
            ?? point(for: frame, normalizedX: 0.5, normalizedY: 0.5)
    }

    private func contentRectPixels(for frame: CapturedFrame) -> WindowBounds {
        let fullImageBounds = WindowBounds(
            x: 0,
            y: 0,
            width: Double(frame.width),
            height: Double(frame.height)
        )
        guard
            let contentRect = frame.contentRectPixels,
            contentRect.width > 0,
            contentRect.height > 0
        else {
            return fullImageBounds
        }
        return contentRect
    }

    private func moveCursor(to point: CGPoint) {
        // Use CGWarpMouseCursorPosition for reliable absolute positioning
        // across displays (especially external monitors at negative coords).
        CGWarpMouseCursorPosition(point)
        // Re-associate the physical mouse with the new cursor position so
        // subsequent physical movements start from the warped location.
        CGAssociateMouseAndMouseCursorPosition(1)
        // Also post a mouseMoved event so applications receive the
        // notification and update hover/tracking state.
        guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
            return
        }
        event.post(tap: .cghidEventTap)
    }

    private func click(globalPoint: CGPoint, button: InputMouseButton, clickCount: Int) {
        moveCursor(to: globalPoint)
        let mouseButton = Self.cgMouseButton(for: button)
        for type in Self.clickEventTypes(for: button) {
            guard let event = CGEvent(
                mouseEventSource: nil,
                mouseType: type,
                mouseCursorPosition: globalPoint,
                mouseButton: mouseButton
            ) else {
                continue
            }
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
            event.post(tap: .cghidEventTap)
        }
    }

    private func drag(globalPath: [CGPoint], button: InputMouseButton) {
        guard let first = globalPath.first, globalPath.count >= 2 else {
            return
        }

        let mouseButton = Self.cgMouseButton(for: button)
        moveCursor(to: first)
        guard let downEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: Self.mouseDownType(for: button),
            mouseCursorPosition: first,
            mouseButton: mouseButton
        ) else {
            return
        }
        downEvent.post(tap: .cghidEventTap)

        for point in globalPath.dropFirst() {
            guard let draggedEvent = CGEvent(
                mouseEventSource: nil,
                mouseType: Self.mouseDraggedType(for: button),
                mouseCursorPosition: point,
                mouseButton: mouseButton
            ) else {
                continue
            }
            draggedEvent.post(tap: .cghidEventTap)
        }

        if let last = globalPath.last {
            guard let upEvent = CGEvent(
                mouseEventSource: nil,
                mouseType: Self.mouseUpType(for: button),
                mouseCursorPosition: last,
                mouseButton: mouseButton
            ) else {
                return
            }
            upEvent.post(tap: .cghidEventTap)
        }
    }

    private func scroll(point: CGPoint, deltaX: Double, deltaY: Double) {
        moveCursor(to: point)
        guard let scrollEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(deltaY.rounded()),
            wheel2: Int32(deltaX.rounded()),
            wheel3: 0
        ) else {
            return
        }
        scrollEvent.post(tap: .cghidEventTap)
    }

    private static func cgMouseButton(for button: InputMouseButton) -> CGMouseButton {
        switch button {
        case .left:
            return .left
        case .right:
            return .right
        case .middle:
            return .center
        }
    }

    private static func clickEventTypes(for button: InputMouseButton) -> [CGEventType] {
        [mouseDownType(for: button), mouseUpType(for: button)]
    }

    private static func mouseDownType(for button: InputMouseButton) -> CGEventType {
        switch button {
        case .left:
            return .leftMouseDown
        case .right:
            return .rightMouseDown
        case .middle:
            return .otherMouseDown
        }
    }

    private static func mouseUpType(for button: InputMouseButton) -> CGEventType {
        switch button {
        case .left:
            return .leftMouseUp
        case .right:
            return .rightMouseUp
        case .middle:
            return .otherMouseUp
        }
    }

    private static func mouseDraggedType(for button: InputMouseButton) -> CGEventType {
        switch button {
        case .left:
            return .leftMouseDragged
        case .right:
            return .rightMouseDragged
        case .middle:
            return .otherMouseDragged
        }
    }

    private static func modifierFlag(for key: String) -> CGEventFlags? {
        switch key.lowercased() {
        case "command", "cmd", "meta":
            return .maskCommand
        case "control", "ctrl":
            return .maskControl
        case "option", "alt":
            return .maskAlternate
        case "shift":
            return .maskShift
        case "function", "fn":
            return .maskSecondaryFn
        default:
            return nil
        }
    }

    private static func keyCode(for key: String) -> CGKeyCode? {
        switch key.lowercased() {
        case "a":
            return 0
        case "s":
            return 1
        case "d":
            return 2
        case "f":
            return 3
        case "h":
            return 4
        case "g":
            return 5
        case "z":
            return 6
        case "x":
            return 7
        case "c":
            return 8
        case "v":
            return 9
        case "b":
            return 11
        case "q":
            return 12
        case "w":
            return 13
        case "e":
            return 14
        case "r":
            return 15
        case "y":
            return 16
        case "t":
            return 17
        case "1":
            return 18
        case "2":
            return 19
        case "3":
            return 20
        case "4":
            return 21
        case "6":
            return 22
        case "5":
            return 23
        case "=":
            return 24
        case "9":
            return 25
        case "7":
            return 26
        case "-":
            return 27
        case "8":
            return 28
        case "0":
            return 29
        case "]":
            return 30
        case "o":
            return 31
        case "u":
            return 32
        case "[":
            return 33
        case "i":
            return 34
        case "p":
            return 35
        case "enter", "return":
            return 36
        case "l":
            return 37
        case "j":
            return 38
        case "'":
            return 39
        case "k":
            return 40
        case ";":
            return 41
        case "\\":
            return 42
        case ",":
            return 43
        case "/":
            return 44
        case "n":
            return 45
        case "m":
            return 46
        case ".":
            return 47
        case "tab":
            return 48
        case "space":
            return 49
        case "`":
            return 50
        case "delete", "backspace":
            return 51
        case "escape", "esc":
            return 53
        case "command", "cmd", "meta":
            return 55
        case "shift":
            return 56
        case "caps_lock":
            return 57
        case "option", "alt":
            return 58
        case "control", "ctrl":
            return 59
        case "right_shift":
            return 60
        case "right_option":
            return 61
        case "right_control":
            return 62
        case "function", "fn":
            return 63
        case "volume_up":
            return 72
        case "volume_down":
            return 73
        case "mute":
            return 74
        case "home":
            return 115
        case "page_up":
            return 116
        case "forward_delete":
            return 117
        case "end":
            return 119
        case "page_down":
            return 121
        case "left":
            return 123
        case "right":
            return 124
        case "down":
            return 125
        case "up":
            return 126
        default:
            return nil
        }
    }
}
