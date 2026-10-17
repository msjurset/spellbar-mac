// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SpellBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SpellBarLib", targets: ["SpellBarLib"]),
        .executable(name: "SpellBar", targets: ["SpellBar"])
    ],
    targets: [
        .target(
            name: "SpellBarLib",
            path: "Sources/SpellBar"
        ),
        .executableTarget(
            name: "SpellBar",
            dependencies: ["SpellBarLib"],
            path: "Sources/SpellBarMain"
        ),
        .testTarget(
            name: "SpellBarTests",
            dependencies: ["SpellBarLib"],
            path: "Tests/SpellBarTests"
        )
    ]
)
