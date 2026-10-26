import SwiftUI

/// Cue's mark as a pixel creature, in the manner of the Claude robot: the white blob
/// with its two eyes looking left. While music plays it dances or plays a guitar
/// (each track picks one), notes rising beside it; paused, it stands and blinks.
struct CueCritter: View {
    enum Mood: Hashable {
        case idle, dance, guitar

        /// What the critter does to `trackID` while `playing`.
        static func playing(_ playing: Bool, trackID: String?) -> Mood {
            guard playing else { return .idle }
            return (trackID?.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } ?? 0) % 2 == 0 ? .dance : .guitar
        }
    }

    /// Its height; the width follows the grid.
    let side: CGFloat
    var mood: Mood = .idle

    static func width(side: CGFloat) -> CGFloat { (side * CGFloat(columns) / CGFloat(rows)).rounded() }

    /// w body · s its shaded side · k eyes · e the light in them.
    private static let body: [String] = [
        "....wwwwww......",
        "..wwwwwwwwwww...",
        ".wwwwwwwwwwwwws.",
        ".wwwwwwkewkewws.",
        "..wwwwwkkwkkwws.",
        "...wwwwkkwkkwws.",
        "....wwwwwwwwwws.",
        "...wwwwwwwwwwws.",
        "..wwwwwwwwwwwws.",
        "..wwwwwwwwwwwss.",
        "...wwwww.wwwss..",
        "....www....ss...",
    ]
    /// The same with its eyes shut.
    private static let blinkRows: [Int: String] = [
        3: ".wwwwwwwwwwwwws.",
        4: "..wwwwwkkwkkwws.",
        5: "...wwwwwwwwwwws.",
    ]
    private static let note: [String] = [
        ".mm",
        ".m.",
        "mm.",
    ]

    private static let columns = 24, rows = 16
    /// Where the body's top-left sits in the grid.
    private static let bodyOrigin = (x: 4, y: 3)
    private static let beat = 0.16

    private static let white = Color(white: 0.96)
    private static let shade = Color(white: 0.72)
    private static let limb = Color(white: 0.84)
    private static let wood = Color(red: 0.86, green: 0.5, blue: 0.24)
    private static let neck = Color(red: 0.5, green: 0.3, blue: 0.16)
    private static let noteColors = [Color(red: 0.55, green: 0.78, blue: 1.0), Color(red: 1.0, green: 0.62, blue: 0.78)]

    private struct Pixel {
        let x: Int, y: Int
        let color: Color
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: Self.beat, paused: IslandView.reduceMotion)) { context in
            let tick = IslandView.reduceMotion ? 0 : Int(context.date.timeIntervalSinceReferenceDate / Self.beat)
            Self.sprite(Self.frame(mood, tick: tick))
        }
        .frame(width: Self.width(side: side), height: side)
        .accessibilityLabel(label)
    }

    #if DEBUG
    /// For diagnostics: each mood's first frames in a row, to look at.
    static func sheet(frames: Int = 8) -> some View {
        VStack(spacing: 8) {
            ForEach([Mood.idle, .dance, .guitar], id: \.self) { mood in
                HStack(spacing: 8) {
                    ForEach(0..<frames, id: \.self) { tick in
                        sprite(frame(mood, tick: mood == .idle ? tick * 7 : tick))
                            .frame(width: width(side: 64), height: 64)
                            .background(Color(white: 0.12))
                    }
                }
            }
        }
        .padding(12)
        .background(.black)
    }
    #endif

    private static func sprite(_ pixels: [Pixel]) -> some View {
            Canvas { canvas, size in
                let pixel = min(size.width / CGFloat(Self.columns), size.height / CGFloat(Self.rows))
                let origin = CGPoint(x: (size.width - pixel * CGFloat(Self.columns)) / 2, y: size.height - pixel * CGFloat(Self.rows))
                for dot in pixels where (0..<Self.columns).contains(dot.x) && (0..<Self.rows).contains(dot.y) {
                    // A hair over a pixel so neighbours meet without seams.
                    let rect = CGRect(x: origin.x + CGFloat(dot.x) * pixel, y: origin.y + CGFloat(dot.y) * pixel,
                                      width: pixel + 0.3, height: pixel + 0.3)
                    canvas.fill(Path(rect), with: .color(dot.color))
                }
            }
    }

    private var label: String {
        switch mood {
        case .idle: "Cue, listening"
        case .dance: "Cue, dancing"
        case .guitar: "Cue, playing guitar"
        }
    }

    // MARK: - Frames

    private static func frame(_ mood: Mood, tick: Int) -> [Pixel] {
        switch mood {
        case .idle: idle(tick)
        case .dance: dance(tick)
        case .guitar: guitar(tick)
        }
    }

    private static func idle(_ tick: Int) -> [Pixel] {
        // A blink now and then; otherwise still.
        blob(dx: 0, dy: 0, blinking: tick % 28 == 0)
    }

    /// Bobbing on the beat, leaning one way then the other, an arm up on each side in turn.
    private static func dance(_ tick: Int) -> [Pixel] {
        let step = tick % 8
        let lean = step < 4 ? -1 : 1
        let bob = step % 2 == 0 ? 0 : 1
        let (ox, oy) = (bodyOrigin.x + lean, bodyOrigin.y + bob)
        var pixels: [Pixel] = []
        // The arm on the side it leans to is up, the other down.
        let left = lean < 0 ? [(0, 4), (-1, 3), (-2, 2)] : [(1, 7), (0, 8), (-1, 9)]
        let right = lean > 0 ? [(15, 4), (16, 3), (17, 2)] : [(14, 7), (15, 8), (16, 9)]
        for (x, y) in left + right { pixels.append(Pixel(x: ox + x, y: oy + y, color: limb)) }
        pixels += blob(dx: lean, dy: bob, blinking: false)
        // Little feet stepping.
        let feet = step % 4 < 2 ? [(4, 12), (11, 11)] : [(5, 11), (12, 12)]
        for (x, y) in feet { pixels.append(Pixel(x: ox + x, y: oy + y, color: shade)) }
        pixels += notes(tick, x: lean < 0 ? 20 : 0)
        return pixels
    }

    /// Strumming a guitar held across it, nodding along.
    private static func guitar(_ tick: Int) -> [Pixel] {
        let nod = (tick / 2) % 2
        let strum = tick % 2
        var pixels = blob(dx: 0, dy: nod, blinking: false)
        let (ox, oy) = (bodyOrigin.x, bodyOrigin.y)
        // The guitar sits still while the body nods behind it: neck up to the left, head at its end.
        let neckPixels = [(4, 9), (3, 8), (2, 7), (1, 6), (0, 5)]
        for (x, y) in neckPixels { pixels.append(Pixel(x: ox + x, y: oy + y, color: neck)) }
        for (x, y) in [(-1, 4), (-1, 5), (0, 4)] { pixels.append(Pixel(x: ox + x, y: oy + y, color: neck)) }
        let woodPixels = [(5, 9), (6, 9), (7, 9), (4, 10), (5, 10), (7, 10), (8, 10), (4, 11), (5, 11), (6, 11), (7, 11), (8, 11), (5, 12), (6, 12), (7, 12)]
        for (x, y) in woodPixels { pixels.append(Pixel(x: ox + x, y: oy + y, color: wood)) }
        pixels.append(Pixel(x: ox + 6, y: oy + 10, color: .black)) // the sound hole
        // The fretting hand on the neck, the strumming one going up and down over the hole.
        pixels.append(Pixel(x: ox + 2, y: oy + 6, color: limb))
        for (x, y) in strum == 0 ? [(9, 9), (8, 9)] : [(9, 11), (8, 12)] { pixels.append(Pixel(x: ox + x, y: oy + y, color: limb)) }
        pixels += notes(tick, x: 20)
        return pixels
    }

    private static func blob(dx: Int, dy: Int, blinking: Bool) -> [Pixel] {
        var pixels: [Pixel] = []
        for (row, line) in body.enumerated() {
            let line = blinking ? blinkRows[row] ?? line : line
            for (column, mark) in line.enumerated() {
                let color: Color? = switch mark {
                case "w": white
                case "s": shade
                case "k": .black
                case "e": white
                default: nil
                }
                if let color { pixels.append(Pixel(x: bodyOrigin.x + dx + column, y: bodyOrigin.y + dy + row, color: color)) }
            }
        }
        return pixels
    }

    /// Two notes rising in turn from about the critter's shoulder, gone at the top.
    private static func notes(_ tick: Int, x: Int) -> [Pixel] {
        var pixels: [Pixel] = []
        for index in 0..<2 {
            let age = (tick + index * 5) % 10
            guard age < 8 else { continue }
            let top = 9 - age
            let drift = index == 0 ? 0 : 1
            for (row, line) in note.enumerated() {
                for (column, mark) in line.enumerated() where mark == "m" {
                    pixels.append(Pixel(x: x + drift + column - (x > 10 ? 1 : 0), y: top + row, color: noteColors[index]))
                }
            }
        }
        return pixels
    }
}
