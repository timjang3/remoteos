import Foundation

public final class OpenAIAPIKeyStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "openai-api-key"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> String? {
        defaults.string(forKey: key)
    }

    public func save(_ apiKey: String?) {
        let trimmed = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(trimmed, forKey: key)
        }
    }
}
