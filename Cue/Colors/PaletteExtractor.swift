import CoreGraphics
import Foundation

/// The colors that make up an image, most common first: a 64×64 downsample,
/// binned to 5 bits a channel, the fullest bins picked while skipping near-twins
/// of colors already chosen.
nonisolated enum PaletteExtractor {
    enum Export: CaseIterable {
        case css, tailwind, swiftUI

        var title: String {
            switch self {
            case .css: "CSS variables"
            case .tailwind: "Tailwind colors"
            case .swiftUI: "SwiftUI"
            }
        }
    }

    static func dominantColors(in image: CGImage, count: Int = 6) -> [PickedColor] {
        let side = 64
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return [] }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return [] }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)

        // Bin: 5 bits a channel; each bin keeps its count and the sum of its true colors.
        var counts: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]
        for index in stride(from: 0, to: side * side * 4, by: 4) {
            let a = Int(pixels[index + 3])
            guard a > 128 else { continue }
            let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
            let key = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)
            var bin = counts[key] ?? (0, 0, 0, 0)
            bin.count += 1; bin.r += r; bin.g += g; bin.b += b
            counts[key] = bin
        }
        let ranked = counts.values.sorted { $0.count > $1.count }.map { bin in
            PickedColor(red: Double(bin.r) / Double(bin.count) / 255, green: Double(bin.g) / Double(bin.count) / 255, blue: Double(bin.b) / Double(bin.count) / 255)
        }

        var chosen: [PickedColor] = []
        for color in ranked where chosen.count < count {
            let twin = chosen.contains { abs($0.red - color.red) + abs($0.green - color.green) + abs($0.blue - color.blue) < 0.28 }
            if !twin { chosen.append(color) }
        }
        return chosen
    }

    /// The palette as text to paste into a stylesheet or a Swift file.
    static func text(for colors: [PickedColor], as export: Export) -> String {
        switch export {
        case .css:
            return ":root {\n" + colors.enumerated().map { "  --color-\($0.offset + 1): \(ColorFormat.hex.string(for: $0.element));" }.joined(separator: "\n") + "\n}"
        case .tailwind:
            return "colors: {\n" + colors.enumerated().map { "  'palette-\($0.offset + 1)': '\(ColorFormat.hex.string(for: $0.element))'," }.joined(separator: "\n") + "\n}"
        case .swiftUI:
            return colors.enumerated().map { "static let palette\($0.offset + 1) = \(ColorFormat.swiftUI.string(for: $0.element))" }.joined(separator: "\n")
        }
    }
}
