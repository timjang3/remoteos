import Foundation

enum TestSupport {
    static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            url.deleteLastPathComponent()
        }
        return url
    }()

    static let contractsFixturesURL = repoRoot.appending(path: "packages/contracts/fixtures", directoryHint: .isDirectory)

    static func fixtureData(named name: String) throws -> Data {
        try Data(contentsOf: contractsFixturesURL.appending(path: name))
    }

    static func jsonObjectData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
