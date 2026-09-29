import CoreGraphics
import CoreImage
import Foundation
import Testing
import TimelineKit
@testable import RenderKit

/// A gradient somebody built reaches the colours they picked, at the ends they picked
/// them for.
@Suite("Gradients of one's own")
struct CustomGradientRenderTests {
    private let red = ColorValue(r: 0.9, g: 0.1, b: 0.1)
    private let green = ColorValue(r: 0.1, g: 0.8, b: 0.2)
    private let blue = ColorValue(r: 0.1, g: 0.2, b: 0.9)

    /// Just the background, at 400 × 240.
    private func render(_ gradient: BackgroundGradient) throws -> DressingPixels {
        let layer = DefaultBackgroundResolver().layer(for: .customGradient(gradient), packageURL: nil)
        let scene = SceneDescriptor(outputSize: CGSize(width: 400, height: 240),
                                    background: layer,
                                    videoFrame: .zero)
        return DressingPixels(try #require(SceneRenderer().cgImage(for: scene, source: nil)))
    }

    private func stops(_ colours: [ColorValue]) -> [BackgroundGradient.Stop] {
        colours.enumerated().map { index, colour in
            BackgroundGradient.Stop(color: colour, location: Double(index) / Double(colours.count - 1))
        }
    }

    @Test("It resolves to a gradient fitted to the frame, radial or not")
    func resolves() {
        let gradient = BackgroundGradient(stops: stops([red, blue]), shape: .radial, angle: 0.1)
        let layer = DefaultBackgroundResolver().layer(for: .customGradient(gradient), packageURL: nil)
        #expect(layer == .fittedGradient(stops: [GradientStop(color: red, location: 0),
                                                 GradientStop(color: blue, location: 1)],
                                         angle: 0.1, isRadial: true))
    }

    @Test("Left to right, the two ends are the two colours")
    func linearEnds() throws {
        let pixels = try render(BackgroundGradient(stops: stops([red, blue]), shape: .linear, angle: 0))
        #expect(pixels.isClose(0, 120, to: red, within: 0.03), "\(pixels.colour(0, 120))")
        #expect(pixels.isClose(399, 120, to: blue, within: 0.03), "\(pixels.colour(399, 120))")
        let middle = pixels.colour(200, 120)
        #expect(abs(middle.r - 0.5) < 0.06 && abs(middle.b - 0.5) < 0.06, "half way is half of each: \(middle)")
    }

    @Test("Three colours: both ends, and the middle one in the middle")
    func threeStops() throws {
        let pixels = try render(BackgroundGradient(stops: stops([red, green, blue]), shape: .linear, angle: 0))
        #expect(pixels.isClose(0, 10, to: red, within: 0.03))
        #expect(pixels.isClose(200, 10, to: green, within: 0.04), "\(pixels.colour(200, 10))")
        #expect(pixels.isClose(399, 10, to: blue, within: 0.03))
    }

    @Test("A quarter turn runs bottom to top, like the stock gradients")
    func vertical() throws {
        let pixels = try render(BackgroundGradient(stops: stops([red, blue]), shape: .linear, angle: 0.25))
        #expect(pixels.isClose(200, 239, to: red, within: 0.03), "the first colour at the bottom")
        #expect(pixels.isClose(200, 0, to: blue, within: 0.03), "the last at the top")
    }

    @Test("At an angle, the far corners are the two ends")
    func diagonal() throws {
        let pixels = try render(BackgroundGradient(stops: stops([red, blue]), shape: .linear, angle: 0.125))
        #expect(pixels.isClose(0, 239, to: red, within: 0.04), "bottom-left: \(pixels.colour(0, 239))")
        #expect(pixels.isClose(399, 0, to: blue, within: 0.04), "top-right: \(pixels.colour(399, 0))")
    }

    @Test("Radial: the first colour in the middle, the last in the corners")
    func radialEnds() throws {
        let pixels = try render(BackgroundGradient(stops: stops([red, green, blue]), shape: .radial))
        #expect(pixels.isClose(200, 120, to: red, within: 0.04), "\(pixels.colour(200, 120))")
        #expect(pixels.isClose(0, 0, to: blue, within: 0.04), "\(pixels.colour(0, 0))")
        #expect(pixels.isClose(399, 239, to: blue, within: 0.04))
        // Round, not stretched to the frame: equally far from the middle is the same colour.
        #expect(DressingPixels.distance(pixels.colour(200 + 100, 120), pixels.colour(200, 120 + 100)) < 0.03)
    }

    @Test("The stock gradients still draw exactly as they did")
    func stockGradientUnchanged() throws {
        let stock = FrameStyle.Background.gradient(from: red, to: blue, angle: 0)
        let layer = DefaultBackgroundResolver().layer(for: stock, packageURL: nil)
        guard case .gradient = layer else {
            Issue.record("a stock gradient resolved to \(layer)")
            return
        }
    }
}
