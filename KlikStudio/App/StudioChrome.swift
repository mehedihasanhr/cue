import SwiftUI

/// The chrome that differs between macOS versions, in one place.
///
/// Klik Studio runs on macOS 14 and up, and the current design language — glass
/// controls, scroll-edge effects — arrived in 26. Rather than scattering `#available`
/// through every view, each adaptive piece is named once here: the views ask for
/// "a prominent button" and get the right one for the system they are on.
extension View {
    /// The app's ordinary button.
    ///
    /// Glass where the system has it, bordered where it does not. Both are the platform
    /// default of their era, so neither reads as a fallback.
    @ViewBuilder
    func studioButton() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    /// The one button a panel is built around — Record, Stop.
    @ViewBuilder
    func studioProminentButton() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    /// Softens content as it passes under a bar, on the systems that draw it.
    ///
    /// A no-op below 26: the hard edge is simply what that system looks like, and faking
    /// the effect with a gradient overlay would be a different thing that reads as a
    /// mistake next to the real one.
    @ViewBuilder
    func studioScrollEdges() -> some View {
        if #available(macOS 26, *) {
            scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            self
        }
    }
}

/// The recorder's colours and metrics, named once.
///
/// Studio is its own target and cannot reach the host app's `Glass.swift`, so the pieces
/// the bar and the target overlay both need are spelled out here beside the rest of the
/// chrome rather than inlined twice.
enum StudioPalette {
    /// Klik blue (#0E4FEC), the fill of the app icon and the app's one accent.
    static let brand = Color(red: 0x0E / 255, green: 0x4F / 255, blue: 0xEC / 255)

    static let barRadius: CGFloat = 22
    static let barHeight: CGFloat = 62

    /// Three weights of white: what is chosen, what is on offer, what cannot be had.
    static let chosen = Color.white
    static let offered = Color.white.opacity(0.62)
    static let unavailable = Color.white.opacity(0.3)
}

extension View {
    /// The floating bar's surface: frosted, not filled.
    ///
    /// It used to be `.regularMaterial` under 35% black, which is near enough to opaque
    /// that the bar read as a solid slab dropped onto the screen. Thinning the material
    /// and lightening the tint lets the wallpaper through — which is the whole point of a
    /// translucent recorder bar. It has to sit over the thing being recorded without
    /// pretending it is not there.
    @ViewBuilder
    func studioGlass(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            glassEffect(.regular.tint(.black.opacity(0.16)), in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.1)))
        } else {
            background(.ultraThinMaterial, in: shape)
                .background(Color.black.opacity(0.26), in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.1)))
        }
    }
}
