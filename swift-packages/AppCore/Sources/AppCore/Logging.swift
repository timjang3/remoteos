import Foundation
import OSLog

enum AppLogs {
    static let hostRuntime = AppLogger(category: "HostRuntime")
    static let codex = AppLogger(category: "Codex")
    static let broker = AppLogger(category: "Broker")
    static let screenshot = AppLogger(category: "Screenshot")
    static let accessibility = AppLogger(category: "Accessibility")
    static let input = AppLogger(category: "Input")
}

struct AppLogger: Sendable {
    enum Level: String, Sendable {
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

    private static let subsystem = "com.remoteos.host"
    let category: String
    private let logger: Logger

    init(category: String) {
        self.category = category
        self.logger = Logger(subsystem: Self.subsystem, category: category)
    }

    func debug(_ message: @autoclosure () -> String) {
        emit(.debug, message())
    }

    func info(_ message: @autoclosure () -> String) {
        emit(.info, message())
    }

    func notice(_ message: @autoclosure () -> String) {
        emit(.notice, message())
    }

    func warning(_ message: @autoclosure () -> String) {
        emit(.warning, message())
    }

    func error(_ message: @autoclosure () -> String) {
        emit(.error, message())
    }

    private func emit(_ level: Level, _ message: String) {
        logger.log(level: level.osLogType, "\(message, privacy: .private)")
    }
}

func logDuration(_ duration: Duration) -> String {
    let components = duration.components
    let milliseconds = Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    return String(format: "%.1fms", milliseconds)
}
