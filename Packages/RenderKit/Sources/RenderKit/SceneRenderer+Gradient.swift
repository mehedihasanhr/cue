import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import TimelineKit

extension SceneRenderer {
    /// A gradient somebody built, fitted to the frame. See `BackgroundLayer.fittedGradient`.
    ///
    /// Drawn in two steps, the same way for both shapes: a grey ramp that says how far along
    /// the sweep each pixel is — a straight one across the frame, or a round one out from
    /// its middle — and then a lookup that turns "how far" into a colour. Core Image has a
    /// generator for each ramp but for neither with three colours, and one lookup for every
    /// shape and every number of stops is one piece of arithmetic to be right about rather
    /// than four.
    func fittedGradient(stops: [GradientStop], angle: Double, isRadial: Bool, in output: CGRect) -> CIImage {
        let sorted = stops.sorted { $0.location < $1.location }
        guard let first = sorted.first else { return CIImage(color: .black).cropped(to: output) }
        guard sorted.count > 1, output.width > 0, output.height > 0 else {
            let c = first.color
            return CIImage(color: CIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a)).cropped(to: output)
        }
        let centre = CGPoint(x: output.midX, y: output.midY)

        let distance: CIImage?
        if isRadial {
            let filter = CIFilter.radialGradient()
            filter.center = centre
            filter.radius0 = 0
            // Out to the corners, so the last colour is exactly what a corner shows.
            filter.radius1 = Float(hypot(output.width, output.height) / 2)
            filter.color0 = CIColor(red: 0, green: 0, blue: 0)
            filter.color1 = CIColor(red: 1, green: 1, blue: 1)
            distance = filter.outputImage
        } else {
            // As long as the frame is, measured along the sweep: the two far corners are
            // then exactly the two ends, whatever the angle — which is what an angle on a
            // gradient means everywhere else people meet one.
            let radians = angle * 2 * .pi
            let direction = CGVector(dx: cos(radians), dy: sin(radians))
            let length = abs(output.width * direction.dx) + abs(output.height * direction.dy)
            let filter = CIFilter.linearGradient()
            filter.point0 = CGPoint(x: centre.x - direction.dx * length / 2, y: centre.y - direction.dy * length / 2)
            filter.point1 = CGPoint(x: centre.x + direction.dx * length / 2, y: centre.y + direction.dy * length / 2)
            filter.color0 = CIColor(red: 0, green: 0, blue: 0)
            filter.color1 = CIColor(red: 1, green: 1, blue: 1)
            distance = filter.outputImage
        }

        guard let distance, let ramp = Self.ramp(sorted) else {
            return CIImage(color: .black).cropped(to: output)
        }
        let lookup = CIFilter.colorMap()
        lookup.inputImage = distance.cropped(to: output)
        lookup.gradientImage = CIImage(cgImage: ramp)
        return (lookup.outputImage ?? CIImage(color: .black)).cropped(to: output)
    }
}
