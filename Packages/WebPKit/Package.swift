// swift-tools-version: 6.0
import PackageDescription

/// WebP writing, which ImageIO can't do (it reads WebP, never writes it): Google's
/// libwebp encoder behind one Swift call.
let package = Package(
    name: "WebPKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WebPKit", targets: ["WebPKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/SDWebImage/libwebp-Xcode", from: "1.5.0"),
    ],
    targets: [
        .target(name: "WebPKit", dependencies: [.product(name: "libwebp", package: "libwebp-Xcode")]),
        .testTarget(name: "WebPKitTests", dependencies: ["WebPKit"]),
    ]
)
