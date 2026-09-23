// swift-tools-version: 6.0
import PackageDescription

/// Capture: ScreenCaptureKit in, a `.klikrec` package out.
///
/// Lives in its own package so the heavy half of the add-on is compiled, tested and
/// reasoned about without a UI. Klik itself never links this — that is the point of the
/// add-on.
let package = Package(
    name: "RecordKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RecordKit", targets: ["RecordKit"]),
    ],
    dependencies: [
        .package(path: "../AddOnKit"),
    ],
    targets: [
        // Left `nonisolated` by default: frames arrive on the system's queues and must
        // never touch an actor on their way to the encoder.
        .target(name: "RecordKit", dependencies: ["AddOnKit"]),
        .testTarget(name: "RecordKitTests", dependencies: ["RecordKit"]),
    ]
)
