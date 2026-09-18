// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LeiosKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "LeiosShared", targets: ["LeiosShared"]),
        .library(name: "LeiosEngine", targets: ["LeiosEngine"]),
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
            name: "LeiosShared",
            path: "Sources/LeiosShared",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "LeiosEngine",
            dependencies: ["LeiosShared", "CPrivateShim"],
            path: "Sources/LeiosEngine",
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
            name: "LeiosEngineTests",
            dependencies: ["LeiosEngine"],
            path: "Tests/LeiosEngineTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "LeiosSharedTests",
            dependencies: ["LeiosShared"],
            path: "Tests/LeiosSharedTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ],
    swiftLanguageModes: [.v5]
)
