// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AirStats",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AirStats", targets: ["AirStats"]),
        .library(name: "AirStatKit", targets: ["AirStatKit"]),
        .library(name: "AirStatUI", targets: ["AirStatUI"]),
    ],
    targets: [
        // Metric collection. Deliberately Swift 5 language mode: the collectors are
        // queue-confined by construction (see SamplingCore) rather than by the type
        // system, and the low-level Mach/IOKit code they wrap is not Sendable-clean.
        .target(
            name: "AirStatKit",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("Metal"),
            ]
        ),
        .target(
            name: "AirStatUI",
            dependencies: ["AirStatKit"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AirStats",
            dependencies: ["AirStatKit", "AirStatUI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AirStatKitTests",
            dependencies: ["AirStatKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
