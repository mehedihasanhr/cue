// swift-tools-version: 6.0
import PackageDescription

/// The contract between Klik and its add-ons.
///
/// Both sides compile this, and nothing else is shared: the host gets the request and
/// capability types without a single frame of video code, which is the whole reason the
/// add-on is a separate app. Keep it that way — anything that needs AVFoundation, Metal
/// or Speech belongs in the add-on, not here.
let package = Package(
    name: "AddOnKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AddOnKit", targets: ["AddOnKit"]),
    ],
    targets: [
        // No `defaultIsolation(MainActor.self)`: this is a library, so the caller
        // decides where its work runs. Its types are values and its protocols say
        // explicitly what they need.
        .target(name: "AddOnKit"),
        .testTarget(name: "AddOnKitTests", dependencies: ["AddOnKit"]),
    ]
)
