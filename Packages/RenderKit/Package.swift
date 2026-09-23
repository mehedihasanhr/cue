// swift-tools-version: 6.0
import PackageDescription

/// Turning an edit into pixels.
///
/// One renderer serves both the preview and the export. That is the whole design: the
/// tools this is modelled on keep a canvas renderer for the preview and a second one for
/// the file, and spend real effort keeping the two in agreement.
let package = Package(
    name: "RenderKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RenderKit", targets: ["RenderKit"]),
    ],
    dependencies: [
        .package(path: "../TimelineKit"),
    ],
    targets: [
        .target(name: "RenderKit", dependencies: ["TimelineKit"]),
        .testTarget(name: "RenderKitTests", dependencies: ["RenderKit"]),
    ]
)
