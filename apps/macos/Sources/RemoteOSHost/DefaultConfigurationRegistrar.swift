import AppCore
import Foundation

enum DefaultConfigurationRegistrar {
    private static let migrationFlagKey = "didMigrateHostedDefaultsV1"
    private static let domainMigrationFlagKey = "didMigrateBundleDefaultsDomainV1"
    private static let sourceBuildResetFlagKey = "didResetHostedSourceDefaultsV1"
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
        resetAccidentalHostedSourceOverridesIfNeeded(
            userDefaults: userDefaults,
            bundledDefaults: defaults
        )
        importLegacyOverridesIfNeeded(userDefaults: userDefaults)
        migrateLegacyLocalOverridesIfNeeded(
            userDefaults: userDefaults,
            bundledDefaults: defaults
        )
    }

    private static func resetAccidentalHostedSourceOverridesIfNeeded(
        userDefaults: UserDefaults,
        bundledDefaults: [String: Any]
    ) {
        guard !userDefaults.bool(forKey: sourceBuildResetFlagKey) else {
            return
        }

        defer {
            userDefaults.set(true, forKey: sourceBuildResetFlagKey)
        }

        guard Bundle.main.bundleURL.pathExtension != "app" else {
            return
        }

        let bundledBaseURL = bundledDefaults["controlPlaneBaseURL"] as? String ?? legacyLocalBaseURL
        guard bundledBaseURL == legacyLocalBaseURL else {
            return
        }

        let domainName = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        guard let persistentDomain = userDefaults.persistentDomain(forName: domainName) else {
            return
        }

        let storedBaseURL = persistentDomain["controlPlaneBaseURL"] as? String
        let storedHostMode = persistentDomain["hostMode"] as? String ?? legacyLocalHostMode
        guard
            let storedBaseURL,
            shouldResetHostedSourceOverride(baseURL: storedBaseURL, hostMode: storedHostMode)
        else {
            return
        }

        userDefaults.removeObject(forKey: "controlPlaneBaseURL")
        userDefaults.removeObject(forKey: "hostMode")
    }

    private static func importLegacyOverridesIfNeeded(userDefaults: UserDefaults) {
        guard !userDefaults.bool(forKey: domainMigrationFlagKey) else {
            return
        }

        defer {
            userDefaults.set(true, forKey: domainMigrationFlagKey)
        }

        guard let bundleIdentifier = Bundle.main.bundleIdentifier, !bundleIdentifier.isEmpty else {
            return
        }
        guard userDefaults.persistentDomain(forName: bundleIdentifier) == nil else {
            return
        }

        let candidateDomains = [ProcessInfo.processInfo.processName]

        for candidate in candidateDomains where candidate != bundleIdentifier {
            guard var legacyDomain = userDefaults.persistentDomain(forName: candidate) else {
                continue
            }

            legacyDomain.removeValue(forKey: domainMigrationFlagKey)
            userDefaults.setPersistentDomain(legacyDomain, forName: bundleIdentifier)
            return
        }
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
    }

    private static func shouldResetHostedSourceOverride(baseURL: String, hostMode: String) -> Bool {
        guard hostMode == legacyLocalHostMode else {
            return false
        }
        guard
            let url = URL(string: baseURL),
            let scheme = url.scheme?.lowercased(),
            let host = url.host?.lowercased()
        else {
            return false
        }
        guard scheme == "https", url.path.isEmpty || url.path == "/" else {
            return false
        }

        switch host {
        case "localhost", "127.0.0.1", "::1":
            return false
        default:
            return true
        }
    }
}
