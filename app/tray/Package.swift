// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FederationTray",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "FederationTray",
            path: "Sources/FederationTray"
        )
    ]
)
