// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "NostromoCodex",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "NostromoCodexCore", targets: ["NostromoCodexCore"]),
        .executable(name: "NostromoCodex", targets: ["NostromoCodexApp"]),
    ],
    targets: [
        .target(
            name: "NostromoCodexCore"
        ),
        .executableTarget(
            name: "NostromoCodexApp",
            dependencies: ["NostromoCodexCore"],
            exclude: ["Resources"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(
            name: "NostromoCodexCoreTests",
            dependencies: ["NostromoCodexCore"]
        ),
        .testTarget(
            name: "NostromoCodexAppTests",
            dependencies: ["NostromoCodexApp", "NostromoCodexCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
