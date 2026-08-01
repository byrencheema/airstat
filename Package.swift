// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AirStat",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AirStat", targets: ["AirStat"]),
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
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AirStat",
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
