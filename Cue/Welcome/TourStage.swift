import SwiftUI

/// A small Mac for the tour: a screen with a wallpaper, a menu bar and a notch, and
/// a tiny island playing one feature out on a loop. Everything is drawn from the
/// clock (seconds into the loop), so it plays the same way each time round.
struct TourStage: View {
    static let size = CGSize(width: 560, height: 300)
    /// The screen inside the bezel, where the demo draws.
    static let screen = CGSize(width: 544, height: 284)

    let page: TourPage
    @State private var start = Date()

    var body: some View {
        let still = IslandView.reduceMotion
        TimelineView(.animation(paused: still)) { context in
            let elapsed = context.date.timeIntervalSince(start)
            let t = still ? page.still : elapsed.truncatingRemainder(dividingBy: page.period)
            MiniMac(notch: page == .plainMac ? 1 - ramp(t, 0.3, 1.0) : 1) {
                TourDemo(page: page, t: t)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }
}

extension TourPage {
    /// How long one loop of the demo runs.
    var period: Double {
        switch self {
        case .shelf: 4.6
        case .transform: 5.4
        case .shake: 4.8
        case .music, .compact, .glass: 6
        case .mini, .huds, .notifications, .agents: 5
        case .clipboard: 4.8
        case .plainMac: 5.2
        }
    }

    /// The moment shown when motion is reduced: the one that says the most.
    var still: Double {
        switch self {
        case .shelf: 2.4
        case .transform: 2.5
        case .shake: 1.9
        case .music: 2
        case .mini: 3
        case .clipboard: 1.1
        case .huds: 1.8
        case .notifications: 2
        case .compact: 1.5
        case .agents: 2
        case .glass: 1
        case .plainMac: 3
        }
    }
}

// MARK: - Timing

/// 0 before `from`, 1 after `to`, eased in between.
private func ramp(_ t: Double, _ from: Double, _ to: Double) -> Double {
    let x = min(1, max(0, (t - from) / (to - from)))
    return x * x * (3 - 2 * x)
}

private func mix(_ a: CGFloat, _ b: CGFloat, _ k: Double) -> CGFloat { a + (b - a) * CGFloat(k) }

private func mix(_ a: CGPoint, _ b: CGPoint, _ k: Double) -> CGPoint { CGPoint(x: mix(a.x, b.x, k), y: mix(a.y, b.y, k)) }

// MARK: - The Mac

private struct MiniMac<Content: View>: View {
    /// The notch's opacity (it fades on the page about displays without one).
    var notch: Double = 1
    @ViewBuilder var content: Content

    static var notchSize: CGSize { CGSize(width: 74, height: 16) }

    var body: some View {
        let screen = TourStage.screen
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.1)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.6), radius: 24, y: 14)
            ZStack(alignment: .topLeading) {
                Wallpaper()
                MenuBar()
                content
                UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6, style: .continuous)
                    .fill(.black)
                    .frame(width: Self.notchSize.width, height: Self.notchSize.height)
                    .position(x: screen.width / 2, y: Self.notchSize.height / 2)
                    .opacity(notch)
            }
            .frame(width: screen.width, height: screen.height)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .frame(width: TourStage.size.width, height: TourStage.size.height)
    }
}

private struct Wallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.12, green: 0.14, blue: 0.36), Color(red: 0.32, green: 0.18, blue: 0.46),
                                    Color(red: 0.86, green: 0.46, blue: 0.4)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color(red: 0.3, green: 0.5, blue: 1).opacity(0.55)).frame(width: 260).blur(radius: 70).offset(x: -170, y: 60)
            Circle().fill(Color(red: 1, green: 0.6, blue: 0.4).opacity(0.5)).frame(width: 220).blur(radius: 70).offset(x: 190, y: 90)
        }
    }
}

private struct MenuBar: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "apple.logo").font(.system(size: 8, weight: .bold))
            Text("Finder").font(.system(size: 8, weight: .bold))
            ForEach(["File", "Edit", "View"], id: \.self) { Text($0).font(.system(size: 8, weight: .medium)) }
            Spacer()
            Image(systemName: "wifi").font(.system(size: 7, weight: .bold))
            Image(systemName: "battery.75percent").font(.system(size: 8))
            Text("Tue 9:41").font(.system(size: 8, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 12)
        .frame(width: TourStage.screen.width, height: 16)
        .background(.black.opacity(0.18))
    }
}

/// The island, hanging from the top of the screen.
private struct MiniIsland<Content: View>: View {
    var width: CGFloat
    var height: CGFloat
    var radius: CGFloat = 14
    var fill: AnyShapeStyle = AnyShapeStyle(.black)
    @ViewBuilder var content: Content

    var body: some View {
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: min(radius, height / 2), bottomTrailingRadius: min(radius, height / 2),
                                           style: .continuous)
        content
            .frame(width: width, height: height)
            .background(shape.fill(fill))
            .clipShape(shape)
            .shadow(color: .black.opacity(height > 30 ? 0.45 : 0), radius: 10, y: 4)
            .position(x: TourStage.screen.width / 2, y: height / 2)
    }
}

private struct Pointer: View {
    var body: some View {
        ZStack {
            Image(systemName: "cursorarrow").font(.system(size: 17, weight: .regular)).foregroundStyle(.white)
            Image(systemName: "cursorarrow").font(.system(size: 14, weight: .black)).foregroundStyle(.black).offset(x: 0.5, y: 0.5)
        }
        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
        // The tip, not the middle, is where it points.
        .offset(x: 5, y: 8)
    }
}

/// A picture file, as it looks being dragged.
private struct FileThumb: View {
    var name = "photo.png"
    var size: CGFloat = 34

    var body: some View {
        VStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 1, green: 0.72, blue: 0.4), Color(red: 0.86, green: 0.3, blue: 0.5)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(alignment: .bottom) {
                    // A hill and a sun: a photo.
                    Ellipse().fill(Color(red: 0.3, green: 0.2, blue: 0.5).opacity(0.8)).frame(width: size * 1.2, height: size * 0.6).offset(y: size * 0.3)
                }
                .overlay(alignment: .topTrailing) { Circle().fill(.white.opacity(0.9)).frame(width: size * 0.22).padding(size * 0.14) }
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.white.opacity(0.7), lineWidth: 1.2))
                .frame(width: size, height: size * 1.1)
            Text(name)
                .font(.system(size: 7, weight: .semibold))
                .padding(.horizontal, 3)
                .background(Capsule().fill(Color(red: 0.2, green: 0.45, blue: 0.95)))
        }
        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
    }
}

/// A Finder window, somewhere for files to come from.
private struct FinderWindow: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.85)).frame(width: 6) }
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 16)
            .background(Color(white: 0.24))
            Color(white: 0.17)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
    }
}

// MARK: - Demos

private struct TourDemo: View {
    let page: TourPage
    let t: Double

    private static let mid = TourStage.screen.width / 2
    private static let notch = MiniMac<EmptyView>.notchSize
    private static let green = Color(red: 0.36, green: 0.82, blue: 0.48)

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch page {
            case .shelf: dropDemo(onto: .shelf)
            case .transform: dropDemo(onto: .transform)
            case .shake: shake
            case .music: music
            case .mini: mini
            case .clipboard: clipboard
            case .huds: huds
            case .notifications: notifications
            case .compact: compact
            case .agents: agents
            case .glass: glass
            case .plainMac: plainMac
            }
        }
        .frame(width: TourStage.screen.width, height: TourStage.screen.height, alignment: .topLeading)
    }

    // MARK: Shelf and Transform

    private static let tiles: [IslandDropZone.Target] = IslandDropZone.Target.allCases

    private func tileCenter(_ target: IslandDropZone.Target) -> CGPoint {
        let index = CGFloat(Self.tiles.firstIndex(of: target) ?? 0)
        let width: CGFloat = 360, inset: CGFloat = 8
        let tile = (width - inset * 2) / CGFloat(Self.tiles.count)
        return CGPoint(x: Self.mid - width / 2 + inset + tile * (index + 0.5), y: 44)
    }

    /// A file dragged up from a window; the island opens into the drop places and the
    /// file lands on one. On the shelf it says so; on Transform a menu comes up and a
    /// WebP comes back.
    @ViewBuilder
    private func dropDemo(onto target: IslandDropZone.Target) -> some View {
        let transform = target == .transform
        let from = CGPoint(x: 120, y: 196)
        let over = tileCenter(target)
        let travel = ramp(t, 0.4, 1.5)
        let point = mix(from, over, travel)
        let open = ramp(t, 0.85, 1.2) * (1 - ramp(t, transform ? 1.9 : 3.3, transform ? 2.2 : 3.7))
        let landed = ramp(t, 1.75, 1.95)
        let saved = transform ? 0 : ramp(t, 1.85, 2.15)
        let result = transform ? ramp(t, 3.2, 3.5) * (1 - ramp(t, 4.7, 5.1)) : 0
        let leave = ramp(t, transform ? 3.0 : 2.8, transform ? 3.4 : 3.3)

        FinderWindow().frame(width: 180, height: 120).position(x: 120, y: 190)
        let width = mix(Self.notch.width, 360, max(open, result))
        let height = mix(Self.notch.height, transform && result > 0 ? 62 : 74, max(open, result))
        MiniIsland(width: width, height: height, radius: 18) {
            ZStack {
                if saved < 1 && result == 0 {
                    HStack(spacing: 4) {
                        ForEach(Self.tiles, id: \.self) { tile in
                            miniTile(tile, lit: tile == target && travel > 0.85)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 18)
                    .padding(.bottom, 8)
                    .opacity(ramp(t, 1.0, 1.25) * (1 - saved))
                }
                if saved > 0 { savedCard.opacity(saved).scaleEffect(0.94 + 0.06 * saved) }
                if result > 0 { webpResult.opacity(ramp(t, 3.35, 3.6)) }
            }
            .frame(width: 360, height: transform && result > 0 ? 62 : 74)
        }
        FileThumb()
            .scaleEffect(1 - 0.5 * landed)
            .opacity(ramp(t, 0, 0.3) * (1 - landed))
            .position(x: point.x, y: point.y + 4)
        if transform {
            transformMenu
                .opacity(ramp(t, 2.0, 2.2) * (1 - ramp(t, 2.95, 3.15)))
                .position(x: over.x + 72, y: over.y + 34)
        }
        Pointer()
            .opacity(ramp(t, 0, 0.3) * (1 - leave))
            .position(transform && t > 2.0 ? mix(over, CGPoint(x: over.x + 40, y: over.y + 34), ramp(t, 2.25, 2.6)) : point)
    }

    private func miniTile(_ tile: IslandDropZone.Target, lit: Bool) -> some View {
        VStack(spacing: 4) {
            DropGlyph(symbol: tile.symbol, badge: tile == .share, dim: tile == .shelf, size: 13)
                .frame(height: 20)
            Text(tile.title).font(.system(size: 7.5, weight: .semibold)).foregroundStyle(.white.opacity(lit ? 1 : 0.75))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(white: lit ? 0.22 : 0.08)))
        .scaleEffect(lit ? 1.04 : 1)
    }

    private var savedCard: some View {
        HStack(spacing: 10) {
            FileThumb(name: "", size: 24).overlay(alignment: .bottomTrailing) {
                GlossyDisc(symbol: "checkmark", tint: Self.green, size: 14, lit: false).offset(x: 6, y: -4)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("On the shelf").font(.system(size: 11, weight: .semibold))
                Text("Drag it out when you need it").font(.system(size: 8, weight: .medium)).foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
        }
        .padding(.leading, 18)
        .padding(.top, 14)
    }

    private var transformMenu: some View {
        VStack(alignment: .leading, spacing: 1) {
            menuRow("Convert to", arrow: true, lit: false)
            menuRow("Make Smaller", lit: false)
            menuRow("Make a ZIP", lit: false)
        }
        .padding(4)
        .frame(width: 96)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(white: 0.16).opacity(0.97)))
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 1) {
                menuRow("JPEG", lit: false)
                menuRow("WebP", lit: t > 2.45)
                menuRow("HEIC", lit: false)
            }
            .padding(4)
            .frame(width: 66)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(white: 0.16).opacity(0.97)))
            .offset(x: 70)
            .opacity(ramp(t, 2.25, 2.4))
        }
        .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
    }

    private func menuRow(_ title: String, arrow: Bool = false, lit: Bool) -> some View {
        HStack {
            Text(title).font(.system(size: 8, weight: .medium))
            Spacer()
            if arrow { Image(systemName: "chevron.right").font(.system(size: 6, weight: .bold)) }
        }
        .padding(.horizontal, 6)
        .frame(height: 15)
        .background(RoundedRectangle(cornerRadius: 4).fill(lit || (arrow && t > 2.25) ? Color(red: 0.25, green: 0.48, blue: 0.95) : .clear))
    }

    private var webpResult: some View {
        HStack(spacing: 8) {
            FileThumb(name: "photo.webp", size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("Converted to WebP").font(.system(size: 10.5, weight: .semibold))
                Text("312 KB → 94 KB, on the shelf").font(.system(size: 8, weight: .medium)).foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
        }
        .padding(.leading, 18)
        .padding(.top, 14)
    }

    // MARK: Shake

    private var shake: some View {
        let start = CGPoint(x: 150, y: 200), stop = CGPoint(x: 300, y: 170)
        let move = ramp(t, 0.1, 0.6)
        let shaking = t > 0.6 && t < 1.35 ? sin((t - 0.6) * 42) * 16 * sin((t - 0.6) / 0.75 * .pi) : 0
        let grid = ramp(t, 1.35, 1.55) * (1 - ramp(t, 2.3, 2.45))
        let basket = ramp(t, 2.35, 2.65) * (1 - ramp(t, 4.1, 4.5))
        let toBasket = ramp(t, 1.6, 2.1)
        let basketTile = CGPoint(x: stop.x - 30, y: stop.y - 30)
        var point = mix(start, stop, move)
        point.x += shaking
        point = mix(point, basketTile, toBasket)
        let dropped = ramp(t, 2.25, 2.4)

        return ZStack(alignment: .topLeading) {
            FinderWindow().frame(width: 180, height: 120).position(x: 130, y: 190)
            quickGrid(lit: toBasket > 0.8 ? .basket : nil)
                .scaleEffect(0.85 + 0.15 * grid)
                .opacity(grid)
                .position(stop)
            basketCard
                .scaleEffect(0.9 + 0.1 * basket)
                .opacity(basket)
                .position(x: stop.x, y: stop.y)
            FileThumb()
                .opacity(ramp(t, 0, 0.2) * (1 - dropped))
                .position(x: point.x, y: point.y + 4)
            Pointer()
                .opacity(ramp(t, 0, 0.2) * (1 - ramp(t, 2.7, 3.0)))
                .position(point)
        }
    }

    private func quickGrid(lit: QuickDropTarget?) -> some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            ForEach(0..<2) { row in
                GridRow {
                    ForEach(QuickDropTarget.allCases.filter { $0.row == row }, id: \.self) { target in
                        VStack(spacing: 4) {
                            DropGlyph(symbol: target.symbol, badge: target == .share, dim: target == .basket, size: 14)
                                .frame(height: 22)
                            Text(target.title).font(.system(size: 7.5, weight: .semibold))
                        }
                        .frame(width: 56, height: 56)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: target == lit ? 0.22 : 0.08)))
                    }
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 17, style: .continuous).fill(Color(white: 0.03).opacity(0.96)))
        .shadow(color: .black.opacity(0.45), radius: 10, y: 5)
    }

    private var basketCard: some View {
        VStack(spacing: 6) {
            FileThumb(name: "photo.png", size: 28)
            Text("Basket · 1 file").font(.system(size: 8, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
        }
        .frame(width: 104, height: 92)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.05).opacity(0.95)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 10, y: 5)
    }

    // MARK: Music

    private var lyrics: [String] { ["Headlights on the water", "We drove until the morning", "Singing every word we knew", "Under orange skies"] }

    private var music: some View {
        let open = ramp(t, 0, 0.35)
        return MiniIsland(width: mix(Self.notch.width, 330, open), height: mix(Self.notch.height, 112, open), radius: 22) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    artwork(size: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Night Drive").font(.system(size: 11, weight: .semibold))
                        Text("Lumen").font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                        lyricLine.padding(.top, 3)
                    }
                    Spacer()
                    equalizer
                }
                progress(0.24 + t / period * 0.4)
                HStack(spacing: 22) {
                    Image(systemName: "backward.fill")
                    Image(systemName: "pause.fill").font(.system(size: 13))
                    Image(systemName: "forward.fill")
                }
                .font(.system(size: 10))
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 10)
            .opacity(ramp(t, 0.2, 0.5))
            .frame(width: 330, height: 112)
        }
    }

    private var period: Double { page.period }

    private var lyricLine: some View {
        let index = Int(t / 1.5) % lyrics.count
        let local = t.truncatingRemainder(dividingBy: 1.5)
        return Text(lyrics[index])
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color(red: 1, green: 0.62, blue: 0.72))
            .opacity(ramp(local, 0, 0.25) * (1 - ramp(local, 1.3, 1.5)))
            .offset(y: CGFloat(4 * (1 - ramp(local, 0, 0.25))))
    }

    private func artwork(size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 1, green: 0.45, blue: 0.5), Color(red: 0.45, green: 0.25, blue: 0.85)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(Image(systemName: "music.note").font(.system(size: size * 0.4, weight: .bold)).foregroundStyle(.white.opacity(0.85)))
            .frame(width: size, height: size)
    }

    private var equalizer: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4) { bar in
                Capsule()
                    .fill(Color(red: 1, green: 0.5, blue: 0.6))
                    .frame(width: 3, height: 5 + 9 * abs(sin(t * (5 + Double(bar) * 1.7) + Double(bar))))
            }
        }
        .frame(height: 16, alignment: .bottom)
    }

    private func progress(_ value: Double) -> some View {
        HStack(spacing: 6) {
            Text("1:\(String(format: "%02d", Int(value * 60) % 60))").font(.system(size: 7, weight: .medium).monospacedDigit())
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule().fill(.white).frame(width: geometry.size.width * value)
                }
            }
            .frame(height: 3)
            Text("3:24").font(.system(size: 7, weight: .medium).monospacedDigit())
        }
        .foregroundStyle(.white.opacity(0.55))
    }

    // MARK: Mini player

    private var mini: some View {
        let open = ramp(t, 0, 0.35) * (1 - ramp(t, 1.25, 1.6))
        let tear = ramp(t, 1.1, 2.1)
        let back = ramp(t, 4.3, 4.9)
        let pill = CGPoint(x: Self.mid, y: 48)
        let floating = CGPoint(x: 410, y: 214)
        let at = mix(mix(pill, floating, tear), pill, back)
        return ZStack(alignment: .topLeading) {
            MiniIsland(width: mix(Self.notch.width, 300, open), height: mix(Self.notch.height, 80, open), radius: 20) {
                Color.clear
            }
            HStack(spacing: 8) {
                artwork(size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Night Drive").font(.system(size: 9.5, weight: .semibold))
                    Text("Lumen").font(.system(size: 8, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                Image(systemName: "pause.fill").font(.system(size: 10))
                Image(systemName: "forward.fill").font(.system(size: 9))
            }
            .padding(.horizontal, 8)
            .frame(width: 190, height: 42)
            .background(Capsule().fill(Color(white: 0.06).opacity(0.94)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 1))
            .shadow(color: .black.opacity(0.45 * tear), radius: 12, y: 6)
            .rotationEffect(.degrees(sin(tear * .pi) * -6))
            .opacity(ramp(t, 0.25, 0.5) * (1 - back))
            .position(at)
        }
    }

    // MARK: Clipboard

    private struct Clip {
        let symbol: String, title: String, detail: String, tint: Color
    }

    private static let clips: [Clip] = [
        Clip(symbol: "link", title: "github.com/mehedihasanhr/cue", detail: "Link · Safari", tint: Color(red: 0.4, green: 0.6, blue: 1)),
        Clip(symbol: "text.alignleft", title: "Meet at seven by the station?", detail: "Text · Messages", tint: Color(white: 0.6)),
        Clip(symbol: "circle.fill", title: "#5B8CFF", detail: "Colour · Figma", tint: Color(red: 0.36, green: 0.55, blue: 1)),
        Clip(symbol: "photo", title: "Screenshot 9.41", detail: "Image · Cue", tint: Color(red: 1, green: 0.6, blue: 0.4)),
        Clip(symbol: "terminal", title: "xcodebuild -scheme Cue", detail: "Text · Terminal", tint: Color(red: 0.4, green: 0.8, blue: 0.5)),
    ]

    private var clipboard: some View {
        let open = ramp(t, 0, 0.35)
        let step = 1.2
        let index = Int(t / step)
        let local = t.truncatingRemainder(dividingBy: step)
        let slide = ramp(local, 0.1, 0.45)
        return MiniIsland(width: mix(Self.notch.width, 340, open), height: mix(Self.notch.height, 150, open), radius: 22) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Clipboard").font(.system(size: 10, weight: .bold))
                    Spacer()
                    Text("⌘⇧V").font(.system(size: 8, weight: .medium)).foregroundStyle(.white.opacity(0.4))
                }
                .padding(.bottom, 2)
                ZStack(alignment: .top) {
                    ForEach(0..<5) { row in
                        let clip = Self.clips[((index - row) % Self.clips.count + Self.clips.count) % Self.clips.count]
                        clipRow(clip, fresh: row == 0 && slide < 1)
                            .opacity(row == 0 ? slide : (row == 4 ? 1 - slide : 1))
                            .offset(y: CGFloat(row - 1) * 25 + 25 * CGFloat(slide))
                    }
                }
                .frame(height: 100, alignment: .top)
                .clipped()
            }
            .padding(.horizontal, 14)
            .padding(.top, 20)
            .opacity(ramp(t, 0.2, 0.5))
            .frame(width: 340, height: 150, alignment: .top)
        }
    }

    private func clipRow(_ clip: Clip, fresh: Bool) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(clip.tint.opacity(0.22))
                .overlay(Image(systemName: clip.symbol).font(.system(size: 8, weight: .bold)).foregroundStyle(clip.tint))
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(clip.title).font(.system(size: 8.5, weight: .semibold)).lineLimit(1)
                Text(clip.detail).font(.system(size: 7, weight: .medium)).foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
        }
        .padding(.horizontal, 5)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(fresh ? 0.12 : 0.04)))
    }

    // MARK: HUDs

    private var huds: some View {
        let volume = ramp(t, 0.15, 0.45) * (1 - ramp(t, 2.1, 2.4))
        let pods = ramp(t, 2.5, 2.8) * (1 - ramp(t, 4.4, 4.7))
        let wide = max(volume, pods)
        let level = 0.3 + 0.45 * ramp(t, 0.6, 1.6)
        return MiniIsland(width: mix(Self.notch.width, 250, wide), height: mix(Self.notch.height, 24, wide), radius: 12) {
            ZStack {
                HStack {
                    Image(systemName: level > 0.6 ? "speaker.wave.3.fill" : "speaker.wave.2.fill").font(.system(size: 10))
                    Spacer()
                    Capsule().fill(.white.opacity(0.2)).frame(width: 60, height: 4)
                        .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: 60 * level, height: 4) }
                }
                .opacity(volume)
                HStack {
                    Image(systemName: "airpodspro").font(.system(size: 11))
                    Spacer()
                    ZStack {
                        Circle().stroke(.white.opacity(0.2), lineWidth: 2)
                        Circle().trim(from: 0, to: 0.82 * ramp(t, 2.8, 3.5)).stroke(Self.green, style: SwiftUI.StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 13, height: 13)
                    Text("82%").font(.system(size: 9, weight: .semibold).monospacedDigit())
                }
                .opacity(pods)
            }
            .padding(.horizontal, 12)
            .padding(.top, 2)
            .frame(width: 250, height: 24)
        }
    }

    // MARK: Notifications

    private var notifications: some View {
        let open = ramp(t, 0.5, 0.85) * (1 - ramp(t, 3.7, 4.1))
        return MiniIsland(width: mix(Self.notch.width, 330, open), height: mix(Self.notch.height, 66, open), radius: 20) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.4, green: 0.9, blue: 0.4), Color(red: 0.15, green: 0.7, blue: 0.3)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(Image(systemName: "message.fill").font(.system(size: 13)).foregroundStyle(.white))
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text("Maya").font(.system(size: 10, weight: .semibold))
                        Spacer()
                        Text("now").font(.system(size: 8, weight: .medium)).foregroundStyle(.white.opacity(0.4))
                    }
                    Text("Running five minutes late. Order me a flat white?")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .opacity(ramp(t, 0.7, 0.95))
            .offset(y: CGFloat(6 * (1 - ramp(t, 0.7, 0.95))))
            .frame(width: 330, height: 66)
        }
    }

    // MARK: Compact tiles

    private var compact: some View {
        let grow = ramp(t, 0.1, 0.4)
        let swap = ramp(t, 2.9, 3.3) * (1 - ramp(t, 5.6, 5.95))
        return MiniIsland(width: mix(Self.notch.width, 236, grow), height: Self.notch.height + 2, radius: 8) {
            ZStack {
                HStack {
                    Text("9:41").font(.system(size: 9, weight: .bold).monospacedDigit())
                    Spacer()
                    HStack(spacing: 3) {
                        Image(systemName: "battery.75percent").font(.system(size: 9)).foregroundStyle(Self.green)
                        Text("86%").font(.system(size: 8, weight: .semibold).monospacedDigit())
                    }
                }
                .opacity(1 - swap)
                HStack {
                    HStack(spacing: 3) {
                        Image(systemName: "calendar").font(.system(size: 8)).foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
                        Text("Standup · 5m").font(.system(size: 8, weight: .semibold))
                    }
                    Spacer()
                    HStack(spacing: 3) {
                        Image(systemName: "sun.max.fill").font(.system(size: 8)).foregroundStyle(.yellow)
                        Text("22°").font(.system(size: 8, weight: .semibold))
                    }
                }
                .opacity(swap)
            }
            .padding(.horizontal, 10)
            .opacity(ramp(t, 0.3, 0.55))
            .frame(width: 236, height: Self.notch.height + 2)
        }
    }

    // MARK: Agents

    private var agents: some View {
        let open = ramp(t, 0, 0.35)
        let fill = ramp(t, 0.4, 1.6)
        return MiniIsland(width: mix(Self.notch.width, 350, open), height: mix(Self.notch.height, 128, open), radius: 22) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Agents").font(.system(size: 10, weight: .bold))
                    Spacer()
                    usageRing("5h", 0.42 * fill, Color(red: 0.86, green: 0.5, blue: 0.36))
                    usageRing("wk", 0.71 * fill, Color(red: 0.6, green: 0.45, blue: 1))
                }
                sessionRow("Claude Code", "cue", status: "Thinking…", tint: Color(red: 0.86, green: 0.5, blue: 0.36), pulse: true)
                sessionRow("Codex", "site", status: "Wants to run npm test", tint: .orange, pulse: false)
                    .overlay(alignment: .trailing) {
                        Text("Allow").font(.system(size: 8, weight: .semibold)).foregroundStyle(.black)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(.white))
                            .padding(.trailing, 6)
                            .scaleEffect(t > 3 && t < 3.25 ? 0.9 : 1)
                    }
            }
            .padding(.horizontal, 14)
            .padding(.top, 20)
            .opacity(ramp(t, 0.2, 0.5))
            .frame(width: 350, height: 128, alignment: .top)
        }
    }

    private func usageRing(_ label: String, _ value: Double, _ tint: Color) -> some View {
        HStack(spacing: 3) {
            ZStack {
                Circle().stroke(.white.opacity(0.15), lineWidth: 2)
                Circle().trim(from: 0, to: value).stroke(tint, style: SwiftUI.StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
            }
            .frame(width: 12, height: 12)
            Text(label).font(.system(size: 7, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
        }
    }

    private func sessionRow(_ agent: String, _ project: String, status: String, tint: Color, pulse: Bool) -> some View {
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 6, height: 6)
                .opacity(pulse ? 0.5 + 0.5 * abs(sin(t * 3)) : 1)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(agent) · \(project)").font(.system(size: 9, weight: .semibold))
                Text(status).font(.system(size: 8, weight: .medium)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.06)))
    }

    // MARK: Glass

    private static let tints: [Color] = [Color(white: 0.1), Color(red: 0.2, green: 0.35, blue: 0.9), Color(red: 0.55, green: 0.3, blue: 0.9),
                                         Color(red: 0.9, green: 0.35, blue: 0.5)]

    private var glass: some View {
        let open = ramp(t, 0, 0.35)
        let step = 1.5
        let index = Int(t / step) % Self.tints.count
        let next = (index + 1) % Self.tints.count
        let blend = ramp(t.truncatingRemainder(dividingBy: step), 1.1, 1.5)
        return ZStack(alignment: .topLeading) {
            MiniIsland(width: mix(Self.notch.width, 330, open), height: mix(Self.notch.height, 100, open), radius: 24,
                       fill: AnyShapeStyle(.ultraThinMaterial)) {
                ZStack {
                    Self.tints[index].opacity(0.55)
                    Self.tints[next].opacity(0.55 * blend)
                    // Black where it meets the notch, so it still seems to come out of it.
                    LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.35))
                    HStack(spacing: 10) {
                        artwork(size: 42)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Night Drive").font(.system(size: 11, weight: .semibold))
                            Text("Lumen").font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                        }
                        Spacer()
                        Image(systemName: "pause.fill").font(.system(size: 13))
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .opacity(ramp(t, 0.2, 0.5))
                }
                .frame(width: 330, height: 100)
            }
            .overlay {
                // The rim catching the light.
                UnevenRoundedRectangle(bottomLeadingRadius: 24, bottomTrailingRadius: 24, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.05), .white.opacity(0.35)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                    .frame(width: mix(Self.notch.width, 330, open), height: mix(Self.notch.height, 100, open))
                    .position(x: Self.mid, y: mix(Self.notch.height, 100, open) / 2)
            }
            HStack(spacing: 6) {
                ForEach(0..<Self.tints.count, id: \.self) { swatch in
                    Circle().fill(Self.tints[swatch]).frame(width: 12, height: 12)
                        .overlay(Circle().strokeBorder(.white.opacity(swatch == (blend > 0.5 ? next : index) ? 0.9 : 0.2), lineWidth: 1.5))
                }
            }
            .padding(6)
            .background(Capsule().fill(.black.opacity(0.35)))
            .position(x: Self.mid, y: 150)
        }
    }

    // MARK: Plain displays

    private var plainMac: some View {
        let appear = ramp(t, 0.9, 1.3)
        let open = ramp(t, 1.9, 2.3) * (1 - ramp(t, 3.9, 4.3))
        let width = mix(mix(Self.notch.width, 150, appear), 300, open)
        let height = mix(mix(Self.notch.height, 22, appear), 82, open)
        return MiniIsland(width: width, height: height, radius: 12 + 10 * open) {
            ZStack {
                HStack {
                    Text("9:41").font(.system(size: 9, weight: .bold).monospacedDigit())
                    Spacer()
                    CueCritter(side: 12, mood: .idle)
                }
                .padding(.horizontal, 12)
                .opacity(appear * (1 - open))
                HStack(spacing: 10) {
                    artwork(size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Night Drive").font(.system(size: 11, weight: .semibold))
                        Text("Lumen").font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer()
                    equalizer
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .opacity(ramp(t, 2.1, 2.35) * (1 - ramp(t, 3.8, 4.0)))
            }
            .frame(width: width, height: height)
        }
    }
}
