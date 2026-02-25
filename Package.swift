// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DirWiz",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "DirWiz",
            dependencies: ["DirWizLib"],
            path: "DirWiz",
            exclude: [
                "Info.plist",
                "DirWiz.entitlements",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .target(
            name: "DirWizLib",
            path: "Sources",
            exclude: [
                "Treemap/CushionShaders.metal",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                // Library must be optimized even in debug builds for instant search
                // (debug -Onone makes the 2M-node scan ~12x slower).
                .unsafeFlags(["-O"], .when(configuration: .debug)),
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(
            name: "DirWizTests",
            dependencies: ["DirWizLib"],
            path: "Tests"
        ),
    ]
)
