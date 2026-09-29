import CoreGraphics
import CoreMedia
import Testing
@testable import TimelineKit

@Suite("Where a picture is first laid")
struct PicturePlacementTests {
    private let wide = CGSize(width: 1_920, height: 1_080)

    /// The picture's shape on the finished frame, in pixels, whatever fractions it is in.
    private func shape(_ rect: CGRect, on frame: CGSize) -> Double {
        (rect.width * frame.width) / (rect.height * frame.height)
    }

    @Test("It keeps its own shape on any frame", arguments: [
        CGSize(width: 1_920, height: 1_080), CGSize(width: 1_080, height: 1_920), CGSize(width: 1_000, height: 1_000),
    ])
    func keepsItsShape(_ frame: CGSize) {
        for picture in [CGSize(width: 400, height: 200), CGSize(width: 300, height: 900), CGSize(width: 512, height: 512)] {
            for logo in [false, true] {
                let rect = AnnotationItem.pictureRect(pixelSize: picture, frame: frame, asLogo: logo)
                #expect(abs(shape(rect, on: frame) - picture.width / picture.height) < 0.001)
            }
        }
    }

    @Test("A picture goes in the middle, a third of the width")
    func middle() {
        let rect = AnnotationItem.pictureRect(pixelSize: CGSize(width: 800, height: 600), frame: wide, asLogo: false)
        #expect(abs(rect.width - 1.0 / 3) < 0.001)
        #expect(abs(rect.midX - 0.5) < 0.001)
        #expect(abs(rect.midY - 0.5) < 0.001)
    }

    @Test("A logo goes in the bottom right, the same distance from both edges")
    func corner() {
        let rect = AnnotationItem.pictureRect(pixelSize: CGSize(width: 512, height: 512), frame: wide, asLogo: true)
        let right = (1 - rect.maxX) * wide.width
        let bottom = (1 - rect.maxY) * wide.height
        #expect(abs(right - bottom) < 0.5)
        #expect(right > 10)
        #expect(rect.width < 0.2)
    }

    @Test("Something tall and thin is kept inside the frame")
    func tall() {
        let rect = AnnotationItem.pictureRect(pixelSize: CGSize(width: 100, height: 2_000), frame: wide, asLogo: false)
        #expect(rect.height <= 0.8 + 0.000_1)
        #expect(rect.minY >= 0)
        let logo = AnnotationItem.pictureRect(pixelSize: CGSize(width: 100, height: 2_000), frame: wide, asLogo: true)
        #expect(logo.height <= 0.2 + 0.000_1)
        #expect(logo.maxY < 1)
    }

    @Test("A picture that cannot be measured still lands somewhere sensible")
    func unmeasurable() {
        let rect = AnnotationItem.pictureRect(pixelSize: .zero, frame: wide, asLogo: false)
        #expect(rect.width > 0 && rect.height > 0)
        #expect(CGRect(x: 0, y: 0, width: 1, height: 1).contains(rect))
    }

    @Test("Undo names a logo a logo")
    func named() {
        let item = AnnotationItem(start: .zero, duration: CMTime(seconds: 5, preferredTimescale: 600),
                                  kind: .image(path: "Images/logo.png"),
                                  rect: CGRect(x: 0.8, y: 0.8, width: 0.1, height: 0.1))
        #expect(Commands.AddAnnotation(item, name: "Add Logo").name == "Add Logo")
        #expect(Commands.AddAnnotation(item).name == "Add Annotation")
    }
}
