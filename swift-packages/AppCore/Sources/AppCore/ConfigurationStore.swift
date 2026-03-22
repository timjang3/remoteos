import Foundation

public struct HostConfiguration: Sendable {
    public var controlPlaneBaseURL: String
    public var hostMode: HostMode
    public var deviceID: String?
    public var deviceSecret: String?
    public var deviceName: String
    public var codexModel: String
    public var codexThreadID: String?

    public init(
        controlPlaneBaseURL: String,
        hostMode: HostMode,
        deviceID: String?,
        deviceSecret: String?,
        deviceName: String,
        codexModel: String,
        codexThreadID: String?
    ) {
        self.controlPlaneBaseURL = controlPlaneBaseURL
        self.hostMode = hostMode
        self.deviceID = deviceID
        self.deviceSecret = deviceSecret
        self.deviceName = deviceName
        self.codexModel = codexModel
        self.codexThreadID = codexThreadID
    }
}

public final class ConfigurationStore: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> HostConfiguration {
        let deviceName = defaults.string(forKey: "deviceName") ?? Host.current().localizedName ?? "RemoteOS Mac"
        defaults.removeObject(forKey: "codexThreadID")
        return HostConfiguration(
            controlPlaneBaseURL: defaults.string(forKey: "controlPlaneBaseURL") ?? "http://localhost:8787",
            hostMode: HostMode(rawValue: defaults.string(forKey: "hostMode") ?? HostMode.hosted.rawValue) ?? .hosted,
            deviceID: defaults.string(forKey: "deviceID"),
            deviceSecret: nil,
            deviceName: deviceName,
            codexModel: defaults.string(forKey: "codexModel") ?? ProcessInfo.processInfo.environment["REMOTEOS_CODEX_MODEL"] ?? "gpt-5.4-mini",
            codexThreadID: nil
        )
    }

    public func save(_ configuration: HostConfiguration) {
        defaults.set(configuration.controlPlaneBaseURL, forKey: "controlPlaneBaseURL")
        defaults.set(configuration.hostMode.rawValue, forKey: "hostMode")
        defaults.set(configuration.deviceID, forKey: "deviceID")
        defaults.set(configuration.deviceName, forKey: "deviceName")
        defaults.set(configuration.codexModel, forKey: "codexModel")
        defaults.removeObject(forKey: "codexThreadID")
    }
}
