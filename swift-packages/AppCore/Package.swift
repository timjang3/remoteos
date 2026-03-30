// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "AppCore",
            targets: ["AppCore"]
        )
    ],
    dependencies: [
        .package(path: "../RemoteOSCore")
    ],
    targets: [
        .target(
            name: "AppCore",
            dependencies: ["RemoteOSCore"],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "AppCoreTests",
            dependencies: ["AppCore", "RemoteOSCore"]
        )
    ]
)
