// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RemoteOSHost",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "../../swift-packages/AppCore")
    ],
    targets: [
        .executableTarget(
            name: "RemoteOSHost",
            dependencies: [
                .product(name: "AppCore", package: "AppCore")
            ]
        )
    ]
)
