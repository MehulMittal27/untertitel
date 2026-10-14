// swift-tools-version: 6.2
import PackageDescription

// The one place the app depends on FluidAudio. Its NeMo text-normalisation trait
// (a prebuilt binary) is switched off: `traits: []`.
let package = Package(
    name: "MeetingKit",
    platforms: [
        .macOS("15.0"),
    ],
    products: [
        .library(name: "MeetingKit", targets: ["MeetingKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: []),
    ],
    targets: [
        .target(
            name: "MeetingKit",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
