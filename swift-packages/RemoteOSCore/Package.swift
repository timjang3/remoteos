// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RemoteOSCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "RemoteOSCore",
            targets: ["RemoteOSCore"]
        )
    ],
    targets: [
        .target(
            name: "RemoteOSCore"
        ),
        .testTarget(
            name: "RemoteOSCoreTests",
            dependencies: ["RemoteOSCore"]
        )
    ]
)
