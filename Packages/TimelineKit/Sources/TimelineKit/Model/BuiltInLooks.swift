import Foundation

public extension Look {
    /// The looks that ship with the app. In code rather than in files, so they cannot be
    /// deleted, renamed or lost, and so a fresh install has something to choose from.
    ///
    /// Each says only how the frame is dressed — the pointer, the captions and the
    /// camera are left as they are, because a built-in look is a starting point rather
    /// than somebody's whole set-up. "Social Post" is the one that also sets the shape,
    /// since a portrait frame is the point of it.
    ///
    /// Six, and each is a different idea rather than a different colour: the app's
    /// default, a light one, a dark one, a warm one, none at all, and a portrait one.
    /// The two that are about having nothing round the picture — the factory one and the
    /// bare one — also take away a window frame; the others leave it as it is.
    static let builtIn: [Look] = [
        // Exactly the factory `FrameStyle`, so a project nobody has restyled is wearing
        // this one and the picker says so.
        Look(name: "Studio",
             frame: Frame(background: FrameStyle().background,
                          padding: 0.06, cornerRadius: 0.02,
                          shadowRadius: 0.03, shadowOpacity: 0.45,
                          backgroundBlur: 0, borderWidth: 0, borderColor: .white,
                          chrome: WindowChrome())),
        // Paper-white with a hairline: a light recording on a light background needs an
        // edge, and a shadow alone is too soft to give it one.
        Look(name: "Paper",
             frame: Frame(background: .color(ColorValue(r: 0.94, g: 0.93, b: 0.9)),
                          padding: 0.07, cornerRadius: 0.018,
                          shadowRadius: 0.035, shadowOpacity: 0.22,
                          backgroundBlur: 0,
                          borderWidth: 0.0025, borderColor: ColorValue(r: 0.1, g: 0.1, b: 0.12, a: 0.55))),
        // Near-black, no shadow — there is nothing for one to fall on — and a faint
        // keyline in its place.
        Look(name: "Midnight",
             frame: Frame(background: .color(ColorValue(r: 0.05, g: 0.05, b: 0.07)),
                          padding: 0.05, cornerRadius: 0.024,
                          shadowRadius: 0.03, shadowOpacity: 0,
                          backgroundBlur: 0,
                          borderWidth: 0.002, borderColor: ColorValue(r: 1, g: 1, b: 1, a: 0.35))),
        // Warm, roomy, with a deep soft shadow: the one for a launch video.
        Look(name: "Sunset",
             frame: Frame(background: .gradient(from: ColorValue(r: 0.98, g: 0.55, b: 0.35),
                                                to: ColorValue(r: 0.72, g: 0.21, b: 0.46),
                                                angle: 0.3),
                          padding: 0.09, cornerRadius: 0.03,
                          shadowRadius: 0.05, shadowOpacity: 0.55,
                          backgroundBlur: 0, borderWidth: 0, borderColor: .white)),
        // The bare recording: nothing round it at all.
        Look(name: "Edge to Edge",
             frame: Frame(background: .color(ColorValue(r: 0, g: 0, b: 0)),
                          padding: 0, cornerRadius: 0,
                          shadowRadius: 0, shadowOpacity: 0,
                          backgroundBlur: 0, borderWidth: 0, borderColor: .white,
                          chrome: WindowChrome())),
        // Portrait, for a feed. The only built-in that changes the shape of the frame.
        Look(name: "Social Post",
             frame: Frame(background: .gradient(from: ColorValue(r: 0.2, g: 0.85, b: 0.7),
                                                to: ColorValue(r: 0.3, g: 0.45, b: 0.95),
                                                angle: 0.25),
                          padding: 0.1, cornerRadius: 0.035,
                          shadowRadius: 0.05, shadowOpacity: 0.5,
                          backgroundBlur: 0, aspect: .portrait4x5,
                          borderWidth: 0, borderColor: .white)),
    ]

    /// The names no saved look may take, so the picker never shows two of one name.
    static var builtInNames: [String] { builtIn.map(\.name) }
}
