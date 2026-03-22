import CoreGraphics
import Foundation

public enum AppCoreError: Error, LocalizedError {
    case invalidResponse
    case missingWindow
    case missingDisplay
    case invalidPayload(String)
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

func anyDictionary(from data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw AppCoreError.invalidResponse
    }
    return object
}

func dataFromJSONObject(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [])
}

func stringDictionary(_ value: Any?) -> [String: Any] {
    value as? [String: Any] ?? [:]
}
