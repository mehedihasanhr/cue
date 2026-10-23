// swift-tools-version: 6.0
import PackageDescription

/// The backgrounds both apps offer, in one place.
///
/// A leaf: no package dependencies, and none wanted. Cue's screenshot editor and Cue
/// Studio's recording editor have different documents and different renderers, but they
/// offer the same wallpapers — so what is shared is the catalogue and the ids, not the
/// model that stores a choice.
///
/// Deliberately not folded into `AddOnKit`, which exists so the host can speak to the
/// add-on "without a single frame of video code": a wallpaper catalogue needs AppKit,
/// ImageIO and an open panel, none of which belong in a contract.
let package = Package(
    name: "BackgroundKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BackgroundKit", targets: ["BackgroundKit"]),
    ],
    targets: [
        .target(name: "BackgroundKit"),
        .testTarget(name: "BackgroundKitTests", dependencies: ["BackgroundKit"]),
    ]
)
