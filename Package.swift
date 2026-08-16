// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ExplorerMac",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ExplorerMac",
            path: "Sources/ExplorerMac",
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        )
    ]
)
