// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RemoteOSHost",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "../../swift-packages/AppCore"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.0")
    ],
    targets: [
        .executableTarget(
            name: "RemoteOSHost",
            dependencies: [
                .product(name: "AppCore", package: "AppCore"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "RemoteOSHostTests",
            dependencies: [
                "RemoteOSHost"
            ]
        )
    ]
)
