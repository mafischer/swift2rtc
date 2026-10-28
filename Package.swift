// swift-tools-version: 6.2
import PackageDescription

/// Approachable concurrency, as the apps it comes from: nonisolated async functions run on their caller's actor, and
/// conformances of isolated types are inferred as isolated
let concurrency: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "swift2rtc",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "Swift2RTCCore", targets: ["Swift2RTCCore"]),
        .library(name: "Swift2RTCOnvif", targets: ["Swift2RTCOnvif"]),
        .library(name: "Swift2RTCRTSP", targets: ["Swift2RTCRTSP"]),
    ],
    targets: [
        .target(name: "Swift2RTCCore", swiftSettings: concurrency),
        .target(name: "Swift2RTCOnvif", dependencies: ["Swift2RTCCore"], swiftSettings: concurrency),
        .target(name: "Swift2RTCRTSP", dependencies: ["Swift2RTCCore"], swiftSettings: concurrency),
        // Planned: the Tapo private-protocol audio backchannel (see its README); not a product yet
        .target(name: "Swift2RTCTapo", dependencies: ["Swift2RTCCore"], exclude: ["README.md"], swiftSettings: concurrency),
        .testTarget(
            name: "Swift2RTCTests",
            dependencies: ["Swift2RTCCore", "Swift2RTCOnvif", "Swift2RTCRTSP"],
            resources: [.copy("Fixtures")],
            swiftSettings: concurrency
        ),
    ],
    swiftLanguageModes: [.v6]
)
