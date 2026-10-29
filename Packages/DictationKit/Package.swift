// swift-tools-version: 6.0
import PackageDescription

/// Speech to text on the Mac, with Whisper models a person chooses to download: the
/// catalog, a store that installs, updates and wholly removes them, and a transcriber that
/// holds a model in memory only while it is being used. Argmax's WhisperKit (MIT) runs
/// the models on the Neural Engine.
let package = Package(
    name: "DictationKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DictationKit", targets: ["DictationKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.1.1"),
    ],
    targets: [
        // Swift 5 mode: WhisperKit's types are not `Sendable`, and the actor that holds one
        // is the whole of the concurrency story here.
        .target(name: "DictationKit",
                dependencies: [.product(name: "WhisperKit", package: "WhisperKit")],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "DictationKitTests", dependencies: ["DictationKit"]),
    ]
)
