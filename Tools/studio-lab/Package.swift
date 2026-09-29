// swift-tools-version: 6.0
import PackageDescription

/// Measures Klik Studio instead of looking at it.
///
/// A recording is only right if the pointer that gets drawn is where the pointer really
/// was, when it was there. That cannot be judged by eye and cannot be unit-tested without
/// a screen, so this tool makes a real recording of a scripted pointer and compares what
/// was written down with what is in the picture.
let package = Package(
    name: "StudioLab",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../Packages/RecordKit"),
        .package(path: "../../Packages/TimelineKit"),
        .package(path: "../../Packages/RenderKit"),
    ],
    targets: [
        .executableTarget(name: "studiolab",
                          dependencies: ["RecordKit", "TimelineKit", "RenderKit"],
                          // A measuring tool, not shipped code: the script thread and the
                          // main actor talk to each other in ways strict checking would
                          // only make noisier, not safer.
                          swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
