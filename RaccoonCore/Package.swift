// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "RaccoonCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "RaccoonCore",
            targets: ["RaccoonCore"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.29.0")
    ],
    targets: [
        .target(
            name: "RaccoonCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "RaccoonCoreTests",
            dependencies: ["RaccoonCore"],
            resources: [
                .copy("corpus"),
                .copy("fixtures")
            ]
        )
    ]
)
