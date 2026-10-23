// swift-tools-version: 6.0
import PackageDescription

/// Capture: ScreenCaptureKit in, a `.cuerec` package out.
///
/// Lives in its own package so recording is compiled, tested and reasoned about without
/// a UI. Cue links it for its screen recorder.
let package = Package(
    name: "RecordKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RecordKit", targets: ["RecordKit"]),
    ],
    targets: [
        // Left `nonisolated` by default: frames arrive on the system's queues and must
        // never touch an actor on their way to the encoder.
        .target(name: "RecordKit"),
        // Writes a made-up take the way the recorder does, until it is told to stop or is
        // killed. The tests run it as a child process and kill it mid-take, which is the
        // only honest way to show a take surviving a crash. Not a product: nothing ships it.
        .executableTarget(name: "RecordKitCrashProbe", dependencies: ["RecordKit"]),
        .testTarget(name: "RecordKitTests", dependencies: ["RecordKit", "RecordKitCrashProbe"]),
    ]
)
