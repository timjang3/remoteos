import Foundation
import Testing
@testable import RemoteOSCore

@Test func urlQueryParameterParserRejectsDuplicateNames() throws {
    #expect(throws: Error.self) {
        _ = try URLQueryParameterParser.uniqueValues(from: [
            URLQueryItem(name: "code", value: "ABC123"),
            URLQueryItem(name: "code", value: "DEF456")
        ])
    }
}
