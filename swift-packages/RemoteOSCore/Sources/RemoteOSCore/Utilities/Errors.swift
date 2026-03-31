import CoreGraphics
import Foundation

public enum AppCoreError: Error, LocalizedError, Sendable {
    case invalidResponse
    case missingWindow
    case missingDisplay
    case invalidPayload(String)
    case rateLimited(String, retryAfter: Duration?)
    case missingConfiguration(String)
    case transportUnavailable
    case staleFrame
    case focusFailed
    case codexUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The broker returned an invalid response."
        case .missingWindow:
            return "The selected window is no longer available."
        case .missingDisplay:
            return "No display is available for capture."
        case let .invalidPayload(message):
            return message
        case let .rateLimited(message, _):
            return message
        case let .missingConfiguration(message):
            return message
        case .transportUnavailable:
            return "The broker transport is unavailable."
        case .staleFrame:
            return "The selected frame is stale. Capture the window again before acting."
        case .focusFailed:
            return "Failed to focus the selected window before sending input."
        case let .codexUnavailable(message):
            return message
        }
    }
}

public func isoNow() -> String {
    ISO8601DateFormatter().string(from: Date())
}

public extension CGRect {
    var asWindowBounds: WindowBounds {
        WindowBounds(
            x: origin.x,
            y: origin.y,
            width: size.width,
            height: size.height
        )
    }

    var area: CGFloat {
        guard !isNull, !isEmpty else {
            return 0
        }
        return width * height
    }
}

public extension WindowBounds {
    var asCGRect: CGRect {
        CGRect(
            x: x,
            y: y,
            width: width,
            height: height
        )
    }

    var logDescription: String {
        "x=\(Int(x.rounded())) y=\(Int(y.rounded())) width=\(Int(width.rounded())) height=\(Int(height.rounded()))"
    }
}

public extension CGPoint {
    var logDescription: String {
        "x=\(Int(x.rounded())) y=\(Int(y.rounded()))"
    }
}
