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
        // Writes a made-up take the way the recorder does, until it is told to stop or is
        // killed. The tests run it as a child process and kill it mid-take, which is the
        // only honest way to show a take surviving a crash. Not a product: nothing ships it.
        .executableTarget(name: "RecordKitCrashProbe", dependencies: ["RecordKit"]),
        .testTarget(name: "RecordKitTests", dependencies: ["RecordKit", "RecordKitCrashProbe"]),
    ]
)
