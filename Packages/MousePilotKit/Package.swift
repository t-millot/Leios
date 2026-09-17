// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MousePilotKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "MousePilotShared", targets: ["MousePilotShared"]),
        .library(name: "MousePilotEngine", targets: ["MousePilotEngine"]),
    ],
    targets: [
        .target(
            name: "CPrivateShim",
            path: "Sources/CPrivateShim",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
            ]
        ),
        .target(
            name: "MousePilotShared",
            path: "Sources/MousePilotShared",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "MousePilotEngine",
            dependencies: ["MousePilotShared", "CPrivateShim"],
            path: "Sources/MousePilotEngine",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOKit"),
            ]
        ),
        .testTarget(
            name: "MousePilotEngineTests",
            dependencies: ["MousePilotEngine"],
            path: "Tests/MousePilotEngineTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MousePilotSharedTests",
            dependencies: ["MousePilotShared"],
            path: "Tests/MousePilotSharedTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ],
    swiftLanguageModes: [.v5]
)
