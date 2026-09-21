// swift-tools-version:5.10
//
// The federation node, in Swift. A second implementation of src/*.ts on the
// same wire: macOS only, one binary, no Bun. Linux nodes stay on Bun.
//
// Language mode 5 on purpose: Hummingbird 2 is fully async and the node's
// state lives in actors, but strict-concurrency-as-error would turn every
// Foundation edge case into a build failure before the port has parity.

import PackageDescription

let package = Package(
    name: "FederationNode",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FederationNode", targets: ["FederationNode"]),
        .executable(name: "herdr-federation-node", targets: ["herdr-federation-node"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.24.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.7.0"),
    ],
    targets: [
        .target(
            name: "FederationNode",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
            ],
            path: "Sources/FederationNode"
        ),
        .executableTarget(
            name: "herdr-federation-node",
            dependencies: ["FederationNode"],
            path: "Sources/herdr-federation-node"
        ),
        .testTarget(
            name: "FederationNodeTests",
            dependencies: ["FederationNode"],
            path: "Tests/FederationNodeTests"
        ),
    ]
)
