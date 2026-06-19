// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DirWiz",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "DirWiz", targets: ["DirWiz"]),
        .executable(name: "dirwiz-cli", targets: ["dirwiz-cli"]),
        .library(name: "DirWizCore", targets: ["DirWizCore"]),
        .library(name: "DirWizUI", targets: ["DirWizUI"]),
    ],
    targets: [
        .executableTarget(
            name: "DirWiz",
            dependencies: ["DirWizCore", "DirWizUI"],
            path: "DirWiz",
            exclude: [
                "Info.plist",
                "DirWiz.entitlements",
                "Resources",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "dirwiz-cli",
            dependencies: ["DirWizCore"],
            path: "CLI",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .target(
            name: "DirWizCore",
            path: "Sources/DirWizCore",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedFramework("CoreServices"),
            ]
        ),
        .target(
            name: "DirWizUI",
            dependencies: ["DirWizCore"],
            path: "Sources/DirWizUI",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("Quartz"),
            ]
        ),
        .testTarget(
            name: "DirWizTests",
            dependencies: ["DirWizCore", "DirWizUI"],
            path: "Tests"
        ),
    ]
)
