// swift-tools-version:5.10
// Source distribution Package.swift — must mirror root Package.swift minus dev-only deps and test targets
import PackageDescription

let package = Package(
    name: "Encore",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(
            name: "Encore",
            targets: ["Encore"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.0.0"),
        // Direct dep so HTTPTypes is on Encore's link line. In Release builds (whole-module
        // optimization with the -O optimizer) the compiler inlines a direct
        // HTTPTypes.HTTPFields.hash reference into Encore.o. See EncoreKit/ios-sdk#1.
        .package(url: "https://github.com/apple/swift-http-types", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "Encore",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            path: "Sources/Encore",
            swiftSettings: [
                .enableExperimentalFeature("AccessLevelOnImport"),
                // Surface v2: the facade is genuinely @MainActor; keep the
                // compiler checking data-race safety across the whole target.
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
    ]
)
