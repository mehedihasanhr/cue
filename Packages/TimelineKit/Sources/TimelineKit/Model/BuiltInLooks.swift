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
    /// Four, and each is a different idea rather than a different colour: the app's
    /// default, a warm one, none at all, and a portrait one. There were six, with a light
    /// and a dark one beside them, but those two were the default in another colour —
    /// which is what the Background section is for — and six tiles made the choice look
    /// bigger than it is. A project still wearing either of them is not changed: it simply
    /// stops matching a built-in, and the picker calls it Custom.
    ///
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
