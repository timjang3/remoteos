import Foundation
import OSLog

public enum RemoteOSLogs {
    public static let broker = RemoteOSLogger(category: "Broker")
    public static let controlPlane = RemoteOSLogger(category: "ControlPlane")
    public static let session = RemoteOSLogger(category: "Session")
    public static let auth = RemoteOSLogger(category: "Auth")
    public static let stream = RemoteOSLogger(category: "Stream")
}

public struct RemoteOSLogger: Sendable {
    public enum Level: String, Sendable {
        case debug = "DEBUG"
        case info = "INFO"
        case notice = "NOTICE"
        case warning = "WARN"
        case error = "ERROR"

        var osLogType: OSLogType {
            switch self {
            case .debug:
                return .debug
            case .info:
                return .info
            case .notice:
                return .default
            case .warning:
                return .error
            case .error:
                return .fault
            }
        }
    }

    public let category: String
    private let logger: Logger

    public init(subsystem: String = "com.remoteos.core", category: String) {
        self.category = category
        self.logger = Logger(subsystem: subsystem, category: category)
    }

    public func debug(_ message: @autoclosure () -> String) {
        emit(.debug, message())
    }

    public func info(_ message: @autoclosure () -> String) {
        emit(.info, message())
    }

    public func notice(_ message: @autoclosure () -> String) {
        emit(.notice, message())
    }

    public func warning(_ message: @autoclosure () -> String) {
        emit(.warning, message())
    }

    public func error(_ message: @autoclosure () -> String) {
        emit(.error, message())
    }

    private func emit(_ level: Level, _ message: String) {
        logger.log(level: level.osLogType, "\(message, privacy: .private)")
    }
}

public func logDuration(_ duration: Duration) -> String {
    let components = duration.components
    let milliseconds = Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    return String(format: "%.1fms", milliseconds)
}
