// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "AgentboxTerm",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "AgentboxTerm", targets: ["AgentboxTerm"]),
    ],
    dependencies: [
        .package(path: "../third_party/swiftterm"),
    ],
    targets: [
        .executableTarget(
            name: "AgentboxTerm",
            dependencies: [
                .product(name: "SwiftTerm", package: "swiftterm"),
            ],
            path: "Sources/AgentboxTerm"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
