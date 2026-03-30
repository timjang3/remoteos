import Foundation

public struct PairingLinkPayload: Equatable, Sendable {
    public var pairingCode: String
    public var controlPlaneBaseURL: String
    public var pairingURL: URL

    public init(pairingCode: String, controlPlaneBaseURL: String, pairingURL: URL) {
        self.pairingCode = pairingCode
        self.controlPlaneBaseURL = controlPlaneBaseURL
        self.pairingURL = pairingURL
    }
}

public enum PairingLinkParser {
    public static func parse(_ rawValue: String) throws -> PairingLinkPayload {
        guard let url = URL(string: rawValue) else {
            throw AppCoreError.invalidPayload("Invalid pairing URL")
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw AppCoreError.invalidPayload("Invalid pairing URL")
        }

        let queryPairs: [(String, String)] = components.queryItems?.compactMap { item in
            guard let value = item.value else {
                return nil
            }
            return (item.name, value)
        } ?? []
        let queryItems = Dictionary(uniqueKeysWithValues: queryPairs)

        guard let pairingCode = queryItems["code"]?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines), pairingCode.isEmpty == false else {
            throw AppCoreError.invalidPayload("Missing pairing code")
        }
        guard let controlPlaneBaseURL = queryItems["api"]?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines), controlPlaneBaseURL.isEmpty == false else {
            throw AppCoreError.invalidPayload("Missing control plane base URL")
        }

        guard let controlPlaneURL = URL(string: controlPlaneBaseURL),
              let scheme = controlPlaneURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw AppCoreError.invalidPayload("Invalid control plane base URL")
        }

        let normalizedBaseURL = controlPlaneBaseURL.replacingOccurrences(
            of: "/$",
            with: "",
            options: String.CompareOptions.regularExpression
        )
        return PairingLinkPayload(
            pairingCode: pairingCode.uppercased(),
            controlPlaneBaseURL: normalizedBaseURL,
            pairingURL: url
        )
    }
}
