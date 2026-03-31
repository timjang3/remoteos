import Foundation
import RemoteOSCore

enum AppLogs {
    static let hostRuntime = AppLogger(subsystem: "com.remoteos.host", category: "HostRuntime")
    static let codex = AppLogger(subsystem: "com.remoteos.host", category: "Codex")
    static let broker = AppLogger(subsystem: "com.remoteos.host", category: "Broker")
    static let screenshot = AppLogger(subsystem: "com.remoteos.host", category: "Screenshot")
    static let accessibility = AppLogger(subsystem: "com.remoteos.host", category: "Accessibility")
    static let input = AppLogger(subsystem: "com.remoteos.host", category: "Input")
}

typealias AppLogger = RemoteOSLogger

func logDuration(_ duration: Duration) -> String {
    RemoteOSCore.logDuration(duration)
}
