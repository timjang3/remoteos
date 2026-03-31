import Foundation

public enum URLQueryParameterParser {
    public static func uniqueValues(from queryItems: [URLQueryItem]) throws -> [String: String] {
        var values: [String: String] = [:]
        values.reserveCapacity(queryItems.count)

        for item in queryItems {
            guard let value = item.value else {
                continue
            }
            if values[item.name] != nil {
                throw AppCoreError.invalidPayload("Duplicate query parameter \(item.name)")
            }
            values[item.name] = value
        }

        return values
    }
}
