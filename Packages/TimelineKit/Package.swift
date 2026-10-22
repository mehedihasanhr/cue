// swift-tools-version: 6.0
import PackageDescription

/// The edit: a document made of value types, and the arithmetic that keeps it honest.
///
/// It depends on `RecordKit` for the `.cuerec` format — the manifest and the telemetry
/// samples the recorder writes and the editor reads. The two ship in the same app, and
/// the recorder owns the format it produces. If a third thing ever needs to read a
/// recording without being able to make one, that format is the seam to split on.
let package = Package(
    name: "TimelineKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TimelineKit", targets: ["TimelineKit"]),
    ],
    dependencies: [
        .package(path: "../RecordKit"),
    ],
    targets: [
        .target(name: "TimelineKit", dependencies: ["RecordKit"]),
        .testTarget(name: "TimelineKitTests", dependencies: ["TimelineKit"]),
    ]
)
