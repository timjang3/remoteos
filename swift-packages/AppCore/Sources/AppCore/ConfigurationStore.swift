import Foundation

private enum ConfigurationDefaultsKey {
    static let controlPlaneBaseURL = "controlPlaneBaseURL"
    static let hostMode = "hostMode"
    static let deviceID = "deviceID"
    static let deviceName = "deviceName"
    static let codexModel = "codexModel"
    static let codexThreadID = "codexThreadID"
}

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
        let deviceName = defaults.string(forKey: ConfigurationDefaultsKey.deviceName) ?? Host.current().localizedName ?? "RemoteOS Mac"
        defaults.removeObject(forKey: ConfigurationDefaultsKey.codexThreadID)
        return HostConfiguration(
            controlPlaneBaseURL: defaults.string(forKey: ConfigurationDefaultsKey.controlPlaneBaseURL) ?? "http://localhost:8787",
            hostMode: HostMode(rawValue: defaults.string(forKey: ConfigurationDefaultsKey.hostMode) ?? HostMode.hosted.rawValue) ?? .hosted,
            deviceID: defaults.string(forKey: ConfigurationDefaultsKey.deviceID),
            deviceSecret: nil,
            deviceName: deviceName,
            codexModel: defaults.string(forKey: ConfigurationDefaultsKey.codexModel) ?? ProcessInfo.processInfo.environment["REMOTEOS_CODEX_MODEL"] ?? "gpt-5.4-mini",
            codexThreadID: nil
        )
    }

    public func save(_ configuration: HostConfiguration) {
        defaults.set(configuration.controlPlaneBaseURL, forKey: ConfigurationDefaultsKey.controlPlaneBaseURL)
        defaults.set(configuration.hostMode.rawValue, forKey: ConfigurationDefaultsKey.hostMode)
        defaults.set(configuration.deviceID, forKey: ConfigurationDefaultsKey.deviceID)
        defaults.set(configuration.deviceName, forKey: ConfigurationDefaultsKey.deviceName)
        defaults.set(configuration.codexModel, forKey: ConfigurationDefaultsKey.codexModel)
        defaults.removeObject(forKey: ConfigurationDefaultsKey.codexThreadID)
    }

    public func resetConnectionOverrides() {
        defaults.removeObject(forKey: ConfigurationDefaultsKey.controlPlaneBaseURL)
        defaults.removeObject(forKey: ConfigurationDefaultsKey.hostMode)
    }
}
