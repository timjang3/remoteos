import AppCore
import Foundation

enum DefaultConfigurationRegistrar {
    private static let migrationFlagKey = "didMigrateHostedDefaultsV1"
    private static let legacyLocalBaseURL = "http://localhost:8787"
    private static let legacyLocalHostMode = "hosted"

    static func register() {
        guard
            let url = Bundle.module.url(forResource: "DefaultConfiguration", withExtension: "plist"),
            let defaults = NSDictionary(contentsOf: url) as? [String: Any]
        else {
            return
        }

        let userDefaults = UserDefaults.standard
        userDefaults.register(defaults: defaults)
        migrateLegacyLocalOverridesIfNeeded(
            userDefaults: userDefaults,
            bundledDefaults: defaults
        )
    }

    private static func migrateLegacyLocalOverridesIfNeeded(
        userDefaults: UserDefaults,
        bundledDefaults: [String: Any]
    ) {
        guard !userDefaults.bool(forKey: migrationFlagKey) else {
            return
        }

        defer {
            userDefaults.set(true, forKey: migrationFlagKey)
        }

        let domainName = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        guard let persistentDomain = userDefaults.persistentDomain(forName: domainName) else {
            return
        }

        let bundledBaseURL = bundledDefaults["controlPlaneBaseURL"] as? String ?? legacyLocalBaseURL
        let storedBaseURL = persistentDomain["controlPlaneBaseURL"] as? String
        let storedHostMode = persistentDomain["hostMode"] as? String ?? legacyLocalHostMode
        guard bundledBaseURL != legacyLocalBaseURL else {
            return
        }
        guard storedBaseURL == legacyLocalBaseURL, storedHostMode == legacyLocalHostMode else {
            return
        }

        userDefaults.removeObject(forKey: "controlPlaneBaseURL")
        userDefaults.removeObject(forKey: "hostMode")
        userDefaults.removeObject(forKey: "deviceID")
        userDefaults.removeObject(forKey: "deviceSecret")
        KeychainTokenStore().save(nil, for: .deviceSecret)
    }
}
