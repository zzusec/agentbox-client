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
    targets: [
        .executableTarget(
            name: "AgentboxTerm",
            path: "Sources/AgentboxTerm"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
