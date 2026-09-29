import AVFoundation
import CoreGraphics
import CoreImage
import CoreText
import Foundation

/// Screen-like footage with something moving in it, and where that something truly is on
/// every frame — for following a mask and measuring how far off it is.
///
/// Drawn with Core Graphics and written through `AVAssetWriter` as H.264, so the follower
/// reads what it reads in a real recording: a compressed file, decoded, not the pixels it
/// was drawn from.
struct FollowingFootage {
    static let size = CGSize(width: 1_280, height: 720)
    static let frameRate = 30

    /// One frame: the picture, and where the followed thing is (top-left origin, pixels),
    /// or `nil` once it is not wholly in the picture.
    typealias Scene = (Int) -> (draw: (CGContext) -> Void, truth: CGRect)

    let frames: Int
    let scene: Scene

    func truth(_ frame: Int) -> CGRect { scene(frame).truth }

    /// The frame as a picture, the way the renderer is handed one: bottom-left origin.
    func image(_ frame: Int) -> CIImage {
        let context = Self.context()
        scene(frame).draw(context)
        return CIImage(cgImage: context.makeImage()!)
    }

    func write(to url: URL) async throws {
        let writer = try AVAssetWriter(url: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(Self.size.width),
            AVVideoHeightKey: Int(Self.size.height),
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(Self.size.width),
            kCVPixelBufferHeightKey as String: Int(Self.size.height),
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let renderer = CIContext()
        for index in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { break }
            renderer.render(image(index), to: buffer)
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index),
                                                                timescale: CMTimeScale(Self.frameRate)))
        }
        input.markAsFinished()
        await writer.finishWriting()
    }

    // MARK: - Drawing

    /// A bitmap drawn into top-left first, like a screen.
    static func context(width: Int = Int(size.width), height: Int = Int(size.height)) -> CGContext {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        return context
    }

    static func text(_ string: String, in context: CGContext, at point: CGPoint, size: CGFloat,
                     color: CGColor = CGColor(gray: 0.15, alpha: 1)) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributed = NSAttributedString(string: string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: point.x, y: point.y + size)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        context.restoreGState()
    }

    /// An image drawn the right way up into a top-left context.
    static func draw(_ image: CGImage, in context: CGContext, at rect: CGRect) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    /// A page of words, the same every time for a seed.
    static func page(height: Int = Int(size.height), seed: UInt64, rows list: Bool = false) -> CGImage {
        let words = ["account", "settings", "password", "the", "quick", "brown", "fox", "invoice", "total",
                     "user", "email", "billing", "profile", "security", "open", "save", "export", "report"]
        let context = Self.context(height: height)
        context.setFillColor(CGColor(gray: 0.97, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: CGFloat(height)))
        var state = seed
        func next() -> Int {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Int(state % UInt64(words.count))
        }
        var y: CGFloat = 10
        var row = 0
        while y < CGFloat(height) {
            if list {
                context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.9, alpha: 1))
                context.fillEllipse(in: CGRect(x: 20, y: y + 4, width: 24, height: 24))
                text("Item \(row)   Last opened yesterday", in: context, at: CGPoint(x: 56, y: y + 6), size: 16)
                context.setFillColor(CGColor(gray: 0.85, alpha: 1))
                context.fill(CGRect(x: 0, y: y + 35, width: size.width, height: 1))
                y += 36
            } else {
                var x: CGFloat = 20
                while x < size.width - 80 {
                    let word = words[next()]
                    text(word, in: context, at: CGPoint(x: x, y: y), size: 15)
                    x += CGFloat(word.count) * 8 + 10
                }
                y += 24
            }
            row += 1
        }
        return context.makeImage()!
    }

    /// Something worth hiding: an email address in a box.
    static let secret: CGImage = {
        let context = Self.context(width: 220, height: 40)
        context.setFillColor(CGColor(red: 1, green: 0.95, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 220, height: 40))
        context.setStrokeColor(CGColor(red: 0.8, green: 0.3, blue: 0.1, alpha: 1))
        context.stroke(CGRect(x: 1, y: 1, width: 218, height: 38), width: 2)
        text("hunter2@example.com", in: context, at: CGPoint(x: 8, y: 10), size: 17,
             color: CGColor(red: 0.2, green: 0, blue: 0.3, alpha: 1))
        return context.makeImage()!
    }()

    static let background = page(seed: 7)

    // MARK: - The cases

    /// The secret over a still page, wherever `place` puts it.
    static func moving(frames: Int, _ place: @escaping (Int) -> CGPoint) -> FollowingFootage {
        FollowingFootage(frames: frames) { index in
            let rect = CGRect(origin: place(index), size: CGSize(width: 220, height: 40))
            return ({ context in
                draw(background, in: context, at: CGRect(origin: .zero, size: size))
                draw(secret, in: context, at: rect)
            }, rect)
        }
    }

    /// A page taller than the frame, scrolling up by `speed` a frame; the truth is a line
    /// of it that starts at `line`.
    static func scrolling(frames: Int, speed: CGFloat, list: Bool, line: CGRect) -> FollowingFootage {
        let tall = page(height: Int(size.height) * 3, seed: 11, rows: list)
        return FollowingFootage(frames: frames) { index in
            let offset = CGFloat(index) * speed
            return ({ context in
                draw(tall, in: context, at: CGRect(x: 0, y: -offset, width: size.width, height: size.height * 3))
            }, line.offsetBy(dx: 0, dy: -offset))
        }
    }

    /// A window dragged along a curve over a desktop; the truth is its email field.
    static func draggedWindow(frames: Int) -> FollowingFootage {
        let desktop: CGImage = {
            let context = Self.context()
            for i in 0..<16 {
                for j in 0..<9 {
                    context.setFillColor(CGColor(red: 0.2 + 0.04 * Double(i), green: 0.3,
                                                 blue: 0.5 + 0.03 * Double(j), alpha: 1))
                    context.fill(CGRect(x: i * 80, y: j * 80, width: 80, height: 80))
                }
            }
            return context.makeImage()!
        }()
        let window: CGImage = {
            let context = Self.context(width: 480, height: 320)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 480, height: 320))
            context.setFillColor(CGColor(gray: 0.88, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 480, height: 28))
            text("Sign in", in: context, at: CGPoint(x: 200, y: 5), size: 14)
            text("Email", in: context, at: CGPoint(x: 30, y: 60), size: 14)
            context.setStrokeColor(CGColor(gray: 0.7, alpha: 1))
            context.stroke(CGRect(x: 30, y: 84, width: 300, height: 32))
            text("jane.doe@company.com", in: context, at: CGPoint(x: 38, y: 90), size: 15)
            text("Password", in: context, at: CGPoint(x: 30, y: 130), size: 14)
            context.stroke(CGRect(x: 30, y: 154, width: 300, height: 32))
            return context.makeImage()!
        }()
        return FollowingFootage(frames: frames) { index in
            let t = Double(index) / Double(frames)
            let corner = CGPoint(x: (150 + 500 * t).rounded(), y: (120 + 120 * sin(t * 6)).rounded())
            return ({ context in
                draw(desktop, in: context, at: CGRect(origin: .zero, size: size))
                draw(window, in: context, at: CGRect(origin: corner, size: CGSize(width: 480, height: 320)))
            }, CGRect(x: corner.x + 30, y: corner.y + 84, width: 300, height: 32))
        }
    }
}
