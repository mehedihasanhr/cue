import CoreGraphics
import Foundation

/// What the recording sits on and inside.
///
/// The part that turns a screen capture into something worth posting: a background, room
/// around the frame, rounded corners, a shadow. All of it is applied at render time, so
/// changing any of it is free and reversible.
public struct FrameStyle: Codable, Equatable, Sendable {
    public enum Background: Codable, Equatable, Sendable {
        case color(ColorValue)
        case gradient(from: ColorValue, to: ColorValue, angle: Double)
        /// Relative to the project package, so the project stays portable.
        case image(path: String)
        /// A named background from the shared catalogue — a generated gradient or one of
        /// the system's desktop pictures.
        ///
        /// An id rather than the thing itself, for three reasons at once: a generated
        /// gradient has as many stops as it likes and `.gradient` has exactly two; a
        /// system picture's path is specific to one version of macOS while its name is
        /// not; and a picker can only put a ring around the swatch that is selected if
        /// the document remembers *which* swatch that was.
        case wallpaper(id: String)
        /// Nothing at all: the area outside the picture is left see-through.
        ///
        /// Kept see-through in a file only by the formats that can carry it — ProRes 4444
        /// and HEVC with transparency. Anything else has no alpha to keep it in, and the
        /// encoder writes black there.
        case transparent
        /// A gradient somebody built: two or three colours, linear or radial.
        case customGradient(BackgroundGradient)
        /// A background that moves, drawn fresh for every frame. See `AnimatedBackground`.
        case animated(AnimatedBackground)
        /// A movie played on a loop behind the picture, without its sound. Relative to the
        /// project package, like `image`.
        case video(path: String)
    }

    public var background: Background
    /// Fraction of the *shorter* output side, so padding looks the same at 1080p and 4K
    /// and in any aspect ratio.
    public var padding: Double
    /// Fraction of the shorter side of the video frame.
    public var cornerRadius: Double
    public var shadowRadius: Double
    public var shadowOpacity: Double
    /// Blur applied to the background, which is what makes a busy wallpaper usable
    /// behind a recording instead of a distraction.
    ///
    /// A fraction of the shorter output side, like `padding` and `shadowRadius`: as a
    /// raw sigma the same setting softened a 1080p export and barely touched a 4K one.
    public var backgroundBlur: Double
    public var aspect: AspectPreset
    /// The part of the recording that makes it into the frame.
    ///
    /// Optional rather than a full-frame default for two reasons: an older `project.json`
    /// decodes with no `crop` key and no migration, and `Timeline: Equatable` drives
    /// `isDirty`, so a stray full-frame crop would mark an untouched project as edited.
    public var crop: CropRect?
    /// The shape `aspect == .custom` means. Kept even while another shape is chosen, so
    /// switching to Custom brings back the numbers that were typed last time.
    public var customAspect: CustomAspect
    /// A line round the recording's picture, as a fraction of the shorter side of the
    /// video frame like `cornerRadius`. Zero — the default, and what every project
    /// written before it existed decodes to — is no border at all.
    ///
    /// Drawn *inside* the picture's edge, so turning it on moves nothing: the frame, the
    /// shadow and the corners stay exactly where the padding put them.
    public var borderWidth: Double
    public var borderColor: ColorValue
    /// A window drawn round the picture — a title bar, or a browser's bar. `.none`, the
    /// default and what every project written before it decodes to, draws the picture on
    /// its own.
    public var chrome: WindowChrome
    /// The picture turned in space. Flat — the default, and what every project written
    /// before it decodes to — is the picture square-on. See `FramePerspective`.
    public var perspective: FramePerspective
    /// Colour correction for the recording's picture alone. Neutral by default.
    public var grade: ColorGrade

    public init(background: Background = .gradient(from: ColorValue(r: 0.36, g: 0.42, b: 0.85),
                                                   to: ColorValue(r: 0.15, g: 0.16, b: 0.35),
                                                   angle: 0.25),
                padding: Double = 0.06,
                cornerRadius: Double = 0.02,
                shadowRadius: Double = 0.03,
                shadowOpacity: Double = 0.45,
                backgroundBlur: Double = 0,
                aspect: AspectPreset = .source,
                crop: CropRect? = nil,
                customAspect: CustomAspect = CustomAspect(),
                borderWidth: Double = 0,
                borderColor: ColorValue = .white,
                chrome: WindowChrome = WindowChrome(),
                perspective: FramePerspective = FramePerspective(),
                grade: ColorGrade = ColorGrade()) {
        self.background = background
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.shadowRadius = shadowRadius
        self.shadowOpacity = shadowOpacity
        self.backgroundBlur = backgroundBlur
        self.aspect = aspect
        self.crop = crop
        self.customAspect = customAspect
        self.borderWidth = borderWidth
        self.borderColor = borderColor
        self.chrome = chrome
        self.perspective = perspective
        self.grade = grade
    }

    /// Decoded field by field, for the reason `CursorStyle.init(from:)` gives — and here
    /// the synthesised decoder had already been trusted too long: the first field added
    /// to this type (the border) would have made every project written before it fail to
    /// decode its style, and `Timeline`'s lenient decoder would have quietly handed back
    /// a *default* `FrameStyle` — somebody's wallpaper and padding replaced by indigo,
    /// because a border was added.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, default fallback: @autoclosure () -> T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback()
        }
        let factory = FrameStyle()
        background = value(.background, default: factory.background)
        padding = value(.padding, default: factory.padding)
        cornerRadius = value(.cornerRadius, default: factory.cornerRadius)
        shadowRadius = value(.shadowRadius, default: factory.shadowRadius)
        shadowOpacity = value(.shadowOpacity, default: factory.shadowOpacity)
        backgroundBlur = value(.backgroundBlur, default: factory.backgroundBlur)
        // A shape this build has never heard of — one a newer build wrote — is drawn at
        // the recording's own shape rather than costing the project its whole style.
        aspect = value(.aspect, default: .source)
        crop = value(.crop, default: nil)
        customAspect = value(.customAspect, default: CustomAspect())
        borderWidth = value(.borderWidth, default: 0)
        borderColor = value(.borderColor, default: ColorValue.white)
        chrome = value(.chrome, default: WindowChrome())
        perspective = value(.perspective, default: FramePerspective())
        grade = value(.grade, default: ColorGrade())
    }

    enum CodingKeys: String, CodingKey {
        case background, padding, cornerRadius, shadowRadius, shadowOpacity, backgroundBlur
        case aspect, crop, customAspect, borderWidth, borderColor, chrome
        case perspective, grade
    }
}

/// The part of the recording that is shown.
///
/// Normalised with a top-left origin, the same convention `BlurRegion.rect` uses — which
/// is what the renderer's `(1 - rect.maxY)` flip is converting from. A named type rather
/// than a bare `CGRect` because there is real arithmetic here (clamping, a minimum side,
/// an even pixel size) and because it stops "which space is this rect in?" being asked
/// at every call site.
public struct CropRect: Codable, Equatable, Sendable {
    public var rect: CGRect

    /// Small enough to be a deliberate close-up, large enough that a crop can never be a
    /// handful of pixels the exporter then has to refuse.
    public static let minimumSide: CGFloat = 0.05

    public static let full = CropRect(rect: CGRect(x: 0, y: 0, width: 1, height: 1))

    public init(rect: CGRect) {
        var rect = rect.standardized
        rect.size.width = min(1, max(Self.minimumSide, rect.width))
        rect.size.height = min(1, max(Self.minimumSide, rect.height))
        rect.origin.x = min(1 - rect.width, max(0, rect.minX))
        rect.origin.y = min(1 - rect.height, max(0, rect.minY))
        self.rect = rect
    }

    /// Whether this crop takes nothing away.
    public var isFull: Bool {
        abs(rect.minX) < 1e-6 && abs(rect.minY) < 1e-6
            && abs(rect.width - 1) < 1e-6 && abs(rect.height - 1) < 1e-6
    }

    /// The cropped size in pixels, even and never degenerate — an odd dimension is a
    /// problem for every video encoder that will ever be pointed at this.
    public func pixels(in videoSize: CGSize) -> CGSize {
        let width = max(2, ((videoSize.width * rect.width) / 2).rounded() * 2)
        let height = max(2, ((videoSize.height * rect.height) / 2).rounded() * 2)
        return CGSize(width: width, height: height)
    }
}

/// The shape of the exported frame.
public enum AspectPreset: String, Codable, Sendable, CaseIterable {
    /// Whatever was recorded.
    case source
    case wide16x9
    case square
    case vertical9x16
    case classic4x3
    case portrait4x5
    case portrait3x4
    case wide16x10
    /// Two whole numbers the user typed. The numbers themselves are
    /// `FrameStyle.customAspect`, which is why this one has no `ratio` of its own — ask
    /// `FrameStyle.aspectRatio`, which knows both.
    case custom

    /// Width over height, or `nil` for the recording's own shape — and for `.custom`,
    /// whose numbers live on the style. Read `FrameStyle.aspectRatio` instead.
    public var ratio: Double? {
        switch self {
        case .source: nil
        case .wide16x9: 16.0 / 9
        case .square: 1
        case .vertical9x16: 9.0 / 16
        case .classic4x3: 4.0 / 3
        case .portrait4x5: 4.0 / 5
        case .portrait3x4: 3.0 / 4
        case .wide16x10: 16.0 / 10
        case .custom: nil
        }
    }

    public var title: String {
        switch self {
        case .source: "Source"
        case .wide16x9: "16 : 9"
        case .square: "1 : 1"
        case .vertical9x16: "9 : 16"
        case .classic4x3: "4 : 3"
        case .portrait4x5: "4 : 5"
        case .portrait3x4: "3 : 4"
        case .wide16x10: "16 : 10"
        case .custom: "Custom"
        }
    }

    /// The longer label a menu button wears, where there is room to say what it means.
    public var displayName: String {
        switch self {
        case .source: "Source"
        case .wide16x9: "Wide 16:9"
        case .square: "Square 1:1"
        case .vertical9x16: "Vertical 9:16"
        case .classic4x3: "Classic 4:3"
        case .portrait4x5: "Portrait 4:5"
        case .portrait3x4: "Portrait 3:4"
        case .wide16x10: "Wide 16:10"
        case .custom: "Custom"
        }
    }

    public var symbolName: String {
        switch self {
        case .source: "rectangle.dashed"
        case .wide16x9: "rectangle.ratio.16.to.9"
        case .square: "square"
        case .vertical9x16: "rectangle.ratio.9.to.16"
        case .classic4x3: "rectangle.ratio.4.to.3"
        case .portrait4x5: "rectangle.portrait"
        case .portrait3x4: "rectangle.ratio.3.to.4"
        case .wide16x10: "rectangle"
        case .custom: "rectangle.and.pencil.and.ellipsis"
        }
    }
}

/// How the pointer is drawn.
///
/// None of this would be possible from a recording with the cursor burned in, which is
/// why the recorder writes cursor positions as data and leaves the video clean.
public struct CursorStyle: Codable, Equatable, Sendable {
    public var isVisible: Bool
    /// Multiplier on the system size. Bigger than 1 by default: a 4K recording watched
    /// in a small player has a pointer nobody can follow.
    public var scale: Double
    /// 0 is the raw sampled path, 1 is as smooth as it goes.
    public var smoothing: Double
    /// The pointer swells a little when a button goes down.
    public var clickEffect: Bool
    public var motionBlur: Bool
    /// Keep the pointer's size steady while the camera zooms, instead of letting the
    /// zoom magnify it too.
    public var sizeIsIndependentOfZoom: Bool
    /// A ring at the place a click happened, spreading and fading.
    ///
    /// Separate from `clickEffect`, and not a replacement for it: the swell says *the
    /// pointer* did something, the ring says *this spot* was clicked. The swell alone is
    /// easy to miss in a silent screen recording, which is the whole reason this exists —
    /// a viewer watching a demo cannot hear the click and has nothing else to go on.
    public var clickHighlight: Bool
    /// What colour the ring is. White reads on almost everything, which is why it is the
    /// default, and a light interface is exactly when somebody will want to change it.
    public var clickColor: ColorValue
    /// How big the ring grows, as a fraction of the shorter side of the finished frame.
    public var clickSize: Double
    /// Draw the pointer the recording actually had, rather than Klik's drawing of it.
    ///
    /// On when the recording kept one — which is the right default, because the drawn
    /// pointer is an approximation of a *stock* Apple pointer and plenty of people do not
    /// use one: a larger size, a different fill or outline, an accessibility pointer. A
    /// recording of somebody's screen should show the pointer they were looking at.
    ///
    /// Off falls back to the drawing, as does any recording that kept no artwork.
    public var usesRecordedArtwork: Bool

    /// Fade the pointer away when it has been still for a while, and bring it back as it
    /// starts to move.
    ///
    /// A pointer parked over the thing being talked about is in the way of it. Off by
    /// default, so a project made before this existed draws the pointer it always drew.
    public var hidesWhenIdle: Bool
    /// How long the pointer has to be still before it goes, in seconds.
    public var idleDelay: Double

    /// Draw the arrow whatever the pointer turned into.
    ///
    /// For a demo where the I-beam flickering in and out over every line of text is
    /// noise. Off by default.
    public var alwaysArrow: Bool
    /// Ignore a shape the pointer held for only an instant.
    ///
    /// Crossing a toolbar turns the pointer into a hand, an I-beam and a hand again inside
    /// a quarter of a second. At video size that is a flicker rather than information, so
    /// a shape has to last a moment to be drawn. On by default: nothing a viewer could
    /// have read is lost.
    public var steadiesShape: Bool

    /// What marks a click.
    public var clickStyle: ClickStyle

    /// How a click is marked on the picture.
    public enum ClickStyle: String, Codable, Sendable, CaseIterable {
        /// One ring, spreading and fading. What every project had before there was a choice.
        case ring
        /// Several rings, one after another, like a drop in water.
        case ripple
        /// A soft disc of light that swells and fades: quieter than a ring on a busy screen.
        case glow

        public var title: String {
            switch self {
            case .ring: "Ring"
            case .ripple: "Ripple"
            case .glow: "Glow"
            }
        }
    }

    /// Whether a click is heard as well as seen.
    ///
    /// Off unless asked for: a sound the recording never made is a decision about the
    /// finished video, not something to find in it by surprise.
    public var clickSound: Bool
    public var clickSoundKind: ClickSound
    /// 0 is silent, 1 as loud as the sound goes.
    public var clickSoundVolume: Double

    /// What a click sounds like. Both are made by the app rather than recorded, so they
    /// are the same on every Mac and in every export.
    public enum ClickSound: String, Codable, Sendable, CaseIterable {
        /// Low and round, like a trackpad. Sits under a voice without competing with it.
        case soft
        /// Brighter and shorter, like a mouse button. Carries over music.
        case crisp

        public var title: String {
            switch self {
            case .soft: "Soft"
            case .crisp: "Crisp"
            }
        }
    }

    public static let idleDelayRange: ClosedRange<Double> = 0.5...10

    /// What the pointer is drawn as. `asRecorded` for every project written before there
    /// was a choice, so it draws the pointer it always drew.
    public var appearance: Appearance
    /// The colour of the `dot` style. Its size is `scale`, like every other style's.
    public var dotColor: ColorValue
    /// Darken the picture except round the pointer.
    public var spotlight: PointerSpotlight
    /// A magnified view of the recording round the pointer.
    public var magnifier: PointerMagnifier
    /// The pointer eased home over the last moments, for a video played on a loop.
    public var loop: PointerLoop
    /// The arrow leaning into its travel.
    public var sway: PointerSway

    /// A bright red, the colour of a laser pointer: it reads on a white page and on a dark
    /// editor alike, which is where screen recordings spend their time.
    public static let defaultDotColor = ColorValue(r: 1, g: 0.23, b: 0.19)

    public init(isVisible: Bool = true,
                scale: Double = 1.4,
                smoothing: Double = 0.6,
                clickEffect: Bool = true,
                motionBlur: Bool = false,
                sizeIsIndependentOfZoom: Bool = true,
                clickHighlight: Bool = true,
                clickColor: ColorValue = .white,
                clickSize: Double = 0.07,
                usesRecordedArtwork: Bool = true,
                hidesWhenIdle: Bool = false,
                idleDelay: Double = 2,
                alwaysArrow: Bool = false,
                steadiesShape: Bool = true,
                clickStyle: ClickStyle = .ring,
                clickSound: Bool = false,
                clickSoundKind: ClickSound = .soft,
                clickSoundVolume: Double = 0.5,
                appearance: Appearance = .asRecorded,
                dotColor: ColorValue = CursorStyle.defaultDotColor,
                spotlight: PointerSpotlight = PointerSpotlight(),
                magnifier: PointerMagnifier = PointerMagnifier(),
                loop: PointerLoop = PointerLoop(),
                sway: PointerSway = PointerSway()) {
        self.isVisible = isVisible
        self.scale = scale
        self.smoothing = smoothing
        self.clickEffect = clickEffect
        self.motionBlur = motionBlur
        self.sizeIsIndependentOfZoom = sizeIsIndependentOfZoom
        self.clickHighlight = clickHighlight
        self.clickColor = clickColor
        self.clickSize = clickSize
        self.usesRecordedArtwork = usesRecordedArtwork
        self.hidesWhenIdle = hidesWhenIdle
        self.idleDelay = min(max(idleDelay, Self.idleDelayRange.lowerBound), Self.idleDelayRange.upperBound)
        self.alwaysArrow = alwaysArrow
        self.steadiesShape = steadiesShape
        self.clickStyle = clickStyle
        self.clickSound = clickSound
        self.clickSoundKind = clickSoundKind
        self.clickSoundVolume = min(max(clickSoundVolume, 0), 1)
        self.appearance = appearance
        self.dotColor = dotColor
        self.spotlight = spotlight
        self.magnifier = magnifier
        self.loop = loop
        self.sway = sway
    }

    /// Decoded field by field, for the reason `Timeline.init(from:)` gives — and here it
    /// is not hypothetical. The synthesised decoder wants every key, so the first field
    /// added to this type would have made every project written before it fail to decode
    /// its pointer settings, and `Timeline`'s lenient decoder would have quietly handed
    /// back a *default* `CursorStyle`: somebody's pointer size, smoothing and motion blur
    /// replaced by the factory ones, because a ring was added.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, default fallback: @autoclosure () -> T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback()
        }
        isVisible = value(.isVisible, default: true)
        scale = value(.scale, default: 1.4)
        smoothing = value(.smoothing, default: 0.6)
        clickEffect = value(.clickEffect, default: true)
        motionBlur = value(.motionBlur, default: false)
        sizeIsIndependentOfZoom = value(.sizeIsIndependentOfZoom, default: true)
        clickHighlight = value(.clickHighlight, default: true)
        clickColor = value(.clickColor, default: ColorValue.white)
        clickSize = value(.clickSize, default: 0.07)
        usesRecordedArtwork = value(.usesRecordedArtwork, default: true)
        hidesWhenIdle = value(.hidesWhenIdle, default: false)
        let delay: Double = value(.idleDelay, default: 2)
        idleDelay = delay.isFinite
            ? min(max(delay, Self.idleDelayRange.lowerBound), Self.idleDelayRange.upperBound)
            : 2
        alwaysArrow = value(.alwaysArrow, default: false)
        // Off for a project written before it existed, so that project draws the shapes
        // it always drew; on for a new one.
        steadiesShape = value(.steadiesShape, default: false)
        clickStyle = value(.clickStyle, default: .ring)
        clickSound = value(.clickSound, default: false)
        clickSoundKind = value(.clickSoundKind, default: .soft)
        let volume: Double = value(.clickSoundVolume, default: 0.5)
        clickSoundVolume = volume.isFinite ? min(max(volume, 0), 1) : 0.5
        // A style this build does not draw — one a newer build wrote — is the pointer as
        // recorded rather than the loss of every other pointer setting.
        appearance = value(.appearance, default: .asRecorded)
        dotColor = value(.dotColor, default: CursorStyle.defaultDotColor)
        spotlight = value(.spotlight, default: PointerSpotlight())
        magnifier = value(.magnifier, default: PointerMagnifier())
        // Both off for a project written before they existed, like every new pointer
        // setting: that project's film was approved without them.
        loop = value(.loop, default: PointerLoop())
        sway = value(.sway, default: PointerSway())
    }

    enum CodingKeys: String, CodingKey {
        case isVisible, scale, smoothing, clickEffect, motionBlur, sizeIsIndependentOfZoom
        case clickHighlight, clickColor, clickSize, usesRecordedArtwork
        case hidesWhenIdle, idleDelay, alwaysArrow, steadiesShape, clickStyle
        case clickSound, clickSoundKind, clickSoundVolume
        case appearance, dotColor, spotlight, magnifier, loop, sway
    }
}

/// How the camera behaves while a zoom is following the pointer.
///
/// Three numbers that used to be constants inside the renderer. They are here, on the
/// document, rather than in app preferences because they change what the exported video
/// looks like: two people opening the same project must see the same framing, and
/// changing one has to be undoable like any other edit.
///
/// The defaults are exactly the constants they replace, so a project made before this
/// existed renders frame-for-frame as it did.
public struct CameraStyle: Codable, Equatable, Sendable {
    /// How far back the camera looks when averaging where the pointer has been, in
    /// seconds.
    ///
    /// The dead zone is measured against this average rather than against the pointer
    /// itself, because at 2× every twitch of a hand is 2× on screen and a boundary tested
    /// on the raw position would nudge the picture for a tremor. It also decides how long
    /// the camera keeps framing where the pointer *was* after it turns around: a long
    /// memory holds the old shot a moment longer, a short one is already home.
    ///
    /// Its effect is small while the dead zone is wide, and that is not a fault — with a
    /// wide zone nothing the pointer does inside the shot reaches the camera at all.
    public var steadiness: Double

    /// How much of the way to the pointer the camera travels, 0 to 1.
    ///
    /// How much the pointer may drag the camera off the shot the zoom was aimed at.
    ///
    /// 0 holds that shot and ignores the pointer entirely — right for a zoom on something
    /// that does not move. 1 lets the pointer take the camera with it as far as it has to
    /// go to stay in frame.
    ///
    /// Not a leash. Following is a *dead zone*: the camera holds its shot and moves only
    /// when the pointer would otherwise leave it. Work done inside the shot — three clicks
    /// on three things that are all already in frame — costs no camera movement at all.
    /// This dial scales how much of the movement is taken when the pointer does leave.
    public var follow: Double

    /// How far the pointer may travel from the middle of the zoomed frame before it drags
    /// the camera with it, as a fraction of the distance from centre to edge.
    ///
    /// This is the dead zone: inside it the camera does not react at all, which is what
    /// keeps a resting hand — and a hand working inside the shot — from moving the picture.
    /// At 1 the pointer may reach the very edge of frame before anything happens, which
    /// means it is half out of shot by the time the camera responds; lower values keep it
    /// further in.
    ///
    /// This is the setting that decides *when* the camera moves, and the one to reach for
    /// if a zoom feels either glued to the mouse or slow to keep up.
    public var safeArea: Double

    /// Whether a zoom magnifies the framed picture as a whole, or only what is inside it.
    ///
    /// On — the default — the framed recording grows and travels: the picture behaves like
    /// a camera moving towards the scene, so at 2× the recording is twice the size, its
    /// rounded corners and shadow travel with it, and the padding around it closes up. The
    /// *background* never moves, because the background is the stage rather than part of
    /// the shot. That is what a zoom means in every screen-recording tool worth copying,
    /// and it is what makes a zoom actually fill the finished video.
    ///
    /// Off, the recording's rounded rectangle stays exactly where the padding put it and
    /// the content magnifies *inside* it, like pushing in on a screen behind a window. The
    /// padding, the corners and the shadow never move, so the styling stays visible
    /// throughout — worth having when the frame itself is the design, and wrong the rest
    /// of the time, which is why it is no longer what you get by default.
    public var zoomsWholeFrame: Bool

    /// Whether the camera travels straight from one zoom to the next when the two are
    /// close together, instead of pulling back to the whole picture in between.
    ///
    /// On for a new project. The rule for "close together", and what the travel looks
    /// like, is `ZoomGlide`'s; this only says whether it applies.
    public var glidesBetweenZooms: Bool
    /// Seconds between two zooms that the camera stays zoomed in across instead of pulling
    /// back out, travelling to the second when it is time — 0 for never.
    ///
    /// Gliding alone only joins zooms whose ramps would meet. Two clicks four seconds apart
    /// in the same corner of the screen still pulled out to the whole picture and pushed
    /// back in, which is a lot of movement to show nothing new. Only acts while gliding is
    /// on, because it *is* a glide: one that waits before it moves. See `ZoomGlide`.
    public var keepsZoomedInFor: Double

    /// Whether the picture is softened along its travel while the camera moves quickly —
    /// pushing in, pulling out, or panning after the pointer.
    ///
    /// A real camera's shutter stays open for part of each frame, so fast movement smears;
    /// a picture that jumps crisply from one frame to the next at speed reads as stepping.
    /// Gentle on purpose: it should be felt in a fast zoom and not noticed at all in a
    /// slow one. Worked out from the camera's path either side of the frame, never from
    /// the frame before, so scrubbing to a moment shows what playing to it shows.
    ///
    /// On for a new project.
    public var motionBlur: Bool

    /// How far in the camera stays for the whole video, 1 for not at all.
    ///
    /// "Stay zoomed in" across gaps joins zooms that are near each other; this is the
    /// other end of the same idea — the camera never pulls back to the whole recording at
    /// all. The picture is held at this magnification from the first frame to the last and
    /// the camera pans after the pointer throughout, the way it does inside a zoom that
    /// follows. What it is for: a vertical 9:16 cut of a 16:9 recording, or a close crop of
    /// a big display, where the whole picture is never what should be on screen.
    ///
    /// Zooms still work inside it, and multiply: a 2× zoom in a video held at 1.5× goes to
    /// 3×, so a zoom means "closer than now" whatever the level. Its framing is arrived at
    /// from wherever the held camera was looking, over the zoom's own ramp.
    public var wholeVideoZoom: Double

    public static let wholeVideoZoomRange: ClosedRange<Double> = 1...4

    /// Whether the whole video is held zoomed in.
    public var holdsWholeVideoZoomed: Bool { sanitised.wholeVideoZoom > 1.001 }

    public init(steadiness: Double = 0.7,
                follow: Double = 1,
                safeArea: Double = 0.85,
                zoomsWholeFrame: Bool = true,
                glidesBetweenZooms: Bool = true,
                keepsZoomedInFor: Double = 0,
                motionBlur: Bool = true,
                wholeVideoZoom: Double = 1) {
        self.steadiness = steadiness
        self.follow = follow
        self.safeArea = safeArea
        self.zoomsWholeFrame = zoomsWholeFrame
        self.glidesBetweenZooms = glidesBetweenZooms
        self.keepsZoomedInFor = keepsZoomedInFor
        self.motionBlur = motionBlur
        self.wholeVideoZoom = wholeVideoZoom
    }

    /// What a project saved before gliding existed decodes to when it carries no camera
    /// at all — see `Timeline.init(from:)`. Everything else at its default, gliding and
    /// motion blur off, since neither was in the film that was approved.
    public static let asSavedBeforeGliding = CameraStyle(glidesBetweenZooms: false, motionBlur: false)

    /// Decoded field by field, for the reason `CursorStyle` is: the synthesised decoder
    /// wants every key, so adding one would make every project written before it fail to
    /// decode its camera — and `Timeline`'s lenient decoder would then hand back a
    /// *default* `CameraStyle`, quietly resetting somebody's steadiness and follow because
    /// a new switch appeared beside them.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, default fallback: @autoclosure () -> T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback()
        }
        steadiness = value(.steadiness, default: 0.7)
        follow = value(.follow, default: 1)
        safeArea = value(.safeArea, default: 0.85)
        // A project written before this key existed gets the new answer rather than the
        // old one. The alternative — remembering `false` for anything without the key —
        // would mean an old project and a new one with identical settings rendered
        // differently, with nothing on screen to say why.
        zoomsWholeFrame = value(.zoomsWholeFrame, default: true)
        // The opposite decision from the one above, on purpose. A project saved before
        // this existed was exported, watched and approved with the camera pulling back
        // between its zooms; opening it a month later must show the same film, and the
        // switch is one click away for anyone who wants the new movement. A new project
        // has no such history and starts with it on.
        glidesBetweenZooms = value(.glidesBetweenZooms, default: false)
        keepsZoomedInFor = value(.keepsZoomedInFor, default: 0)
        // Off for a project saved before it existed, for the reason gliding is: that film
        // was watched and approved without it, and must look the same when it is opened
        // again. The switch is in the Zoom panel for anyone who wants it.
        motionBlur = value(.motionBlur, default: false)
        // Not held for a project written before it existed: the zooms it has are the
        // whole of what it asked for.
        wholeVideoZoom = value(.wholeVideoZoom, default: 1)
    }

    enum CodingKeys: String, CodingKey {
        case steadiness, follow, safeArea, zoomsWholeFrame, glidesBetweenZooms, keepsZoomedInFor, motionBlur
        case wholeVideoZoom
    }

    /// The same values, clamped to what the renderer can act on.
    ///
    /// A project is a file, and a file can say `safeArea: 40`. Clamping when it is read
    /// rather than when it is written means a hand-edited or newer project frames sanely
    /// instead of showing a camera that has flown off the picture.
    public var sanitised: CameraStyle {
        CameraStyle(steadiness: min(max(steadiness, 0), 5),
                    follow: min(max(follow, 0), 1),
                    safeArea: min(max(safeArea, 0.05), 1),
                    zoomsWholeFrame: zoomsWholeFrame,
                    glidesBetweenZooms: glidesBetweenZooms,
                    keepsZoomedInFor: keepsZoomedInFor.isFinite ? min(max(keepsZoomedInFor, 0), 30) : 0,
                    motionBlur: motionBlur,
                    wholeVideoZoom: wholeVideoZoom.isFinite
                        ? min(max(wholeVideoZoom, Self.wholeVideoZoomRange.lowerBound),
                              Self.wholeVideoZoomRange.upperBound)
                        : 1)
    }
}

/// What the recording's own sound does in the finished video.
///
/// A document setting rather than a preference, because it changes the exported file:
/// silencing the screen so a voiceover can be heard, or dropping it under music, is an
/// edit, and it is undoable like any other.
///
/// Note what this is *not*: the editor's preview level lives in preferences, because
/// turning the volume down to work at night must not quietly ship a silent video. These
/// two are easy to confuse and so are deliberately kept apart — this one travels in the
/// project, that one stays on the Mac.
public struct SoundStyle: Codable, Equatable, Sendable {
    /// Whether the recording's own sound is heard at all.
    public var isMuted: Bool

    /// How loud it is, 0 to 2. 1 is as recorded.
    public var gain: Double

    /// Take out rumble and the hiss between words, and even out loud syllables. See
    /// `VoiceChain` in RenderKit for what that is, sample by sample.
    public var cleansVoice: Bool

    /// Bring the source to one agreed loudness, so a quiet microphone and a loud one
    /// come out alike. Measured once per file; see `SoundAnalyzer` in RenderKit.
    public var evensVolume: Bool

    public init(isMuted: Bool = false, gain: Double = 1,
                cleansVoice: Bool = false, evensVolume: Bool = false) {
        self.isMuted = isMuted
        self.gain = gain
        self.cleansVoice = cleansVoice
        self.evensVolume = evensVolume
    }

    /// Decoded field by field: a project saved before the voice switches existed has
    /// neither key, and the synthesised decoder would have thrown the whole style away —
    /// mute and level with it — rather than read the two that are there.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isMuted = (try? container.decodeIfPresent(Bool.self, forKey: .isMuted)) ?? false
        gain = (try? container.decodeIfPresent(Double.self, forKey: .gain)) ?? 1
        cleansVoice = (try? container.decodeIfPresent(Bool.self, forKey: .cleansVoice)) ?? false
        evensVolume = (try? container.decodeIfPresent(Bool.self, forKey: .evensVolume)) ?? false
    }

    enum CodingKeys: String, CodingKey {
        case isMuted, gain, cleansVoice, evensVolume
    }

    /// What is actually heard: muted counts as silent whatever the gain says, so one
    /// reading answers the question rather than two that can disagree.
    public var level: Double { isMuted ? 0 : min(max(gain, 0), 2) }

    public var isAudible: Bool { level > 0 }

    /// Whether anything is done to the sound beyond its level.
    public var isTreated: Bool { cleansVoice || evensVolume }
}

/// The camera bubble, when there is one.
public struct WebcamSettings: Codable, Equatable, Sendable {
    public enum Corner: String, Codable, Sendable, CaseIterable {
        case bottomLeft, bottomRight, topLeft, topRight, custom
    }

    /// What happens to everything in the camera's picture that is not the person.
    ///
    /// Found by Vision's person segmentation, one frame at a time — see
    /// `PersonMatte` in RenderKit for why one frame at a time.
    public enum Background: String, Codable, Sendable, CaseIterable, Identifiable {
        /// The camera's picture as it was filmed. What every project had before there was
        /// a choice.
        case keep
        /// Softened behind the person, so a messy room stops competing with the face.
        case blur
        /// Taken away: the person alone, over whatever is behind the bubble.
        case remove

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .keep: "None"
            case .blur: "Blur Background"
            case .remove: "Remove Background"
            }
        }
    }

    public var isEnabled: Bool
    public var corner: Corner
    /// Used when `corner` is `.custom`, normalised to the output frame.
    public var position: CGPoint
    /// Fraction of the shorter output side.
    public var size: Double
    /// 0 is a square, 1 is a circle.
    public var roundness: Double
    public var isMirrored: Bool
    public var shadowOpacity: Double
    /// Grow the bubble slightly while the camera is zoomed in, so it keeps its weight in
    /// the frame instead of shrinking away.
    public var reactsToZoom: Bool
    /// Which part of the camera's picture is shown. See `WebcamCrop`.
    public var crop: WebcamCrop
    /// A line round the bubble, as a fraction of the bubble's shorter side. Zero is none,
    /// which is what every project written before there was one draws.
    public var borderWidth: Double
    public var borderColor: ColorValue
    public var background: Background
    /// How soft a blurred background is, 0…1.
    public var backgroundBlur: Double

    /// The widest border the inspector offers: a tenth of the bubble. Past that it is a
    /// frame with a face in it rather than a face with a frame round it.
    public static let borderWidthRange: ClosedRange<Double> = 0...0.1

    public init(isEnabled: Bool = false,
                corner: Corner = .bottomRight,
                position: CGPoint = CGPoint(x: 0.85, y: 0.85),
                size: Double = 0.22,
                roundness: Double = 1,
                isMirrored: Bool = true,
                shadowOpacity: Double = 0.4,
                reactsToZoom: Bool = true,
                crop: WebcamCrop = WebcamCrop(),
                borderWidth: Double = 0,
                borderColor: ColorValue = .white,
                background: Background = .keep,
                backgroundBlur: Double = 0.5) {
        self.isEnabled = isEnabled
        self.corner = corner
        self.position = position
        self.size = size
        self.roundness = roundness
        self.isMirrored = isMirrored
        self.shadowOpacity = shadowOpacity
        self.reactsToZoom = reactsToZoom
        self.crop = crop
        self.borderWidth = borderWidth
        self.borderColor = borderColor
        self.background = background
        self.backgroundBlur = backgroundBlur
    }

    /// Field by field, for the reason `CaptionStyle.init(from:)` gives. This one decoded
    /// with the synthesised decoder until the crop, the border and the background were
    /// added — which is exactly the moment that stops being safe: every project saved
    /// before them has none of those keys, the synthesised decoder wants all of them, and
    /// the whole bubble — whether it was on, where it sat — would have gone back to the
    /// defaults on opening.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, default fallback: @autoclosure () -> T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback()
        }
        isEnabled = value(.isEnabled, default: false)
        corner = value(.corner, default: .bottomRight)
        position = value(.position, default: CGPoint(x: 0.85, y: 0.85))
        size = value(.size, default: 0.22)
        roundness = value(.roundness, default: 1)
        isMirrored = value(.isMirrored, default: true)
        shadowOpacity = value(.shadowOpacity, default: 0.4)
        reactsToZoom = value(.reactsToZoom, default: true)
        crop = value(.crop, default: WebcamCrop())
        borderWidth = value(.borderWidth, default: 0)
        borderColor = value(.borderColor, default: ColorValue.white)
        background = value(.background, default: .keep)
        backgroundBlur = value(.backgroundBlur, default: 0.5)
    }

    enum CodingKeys: String, CodingKey {
        case isEnabled, corner, position, size, roundness, isMirrored, shadowOpacity, reactsToZoom
        case crop, borderWidth, borderColor, background, backgroundBlur
    }
}

/// Which part of the camera's picture the bubble shows.
///
/// The bubble always *fills* — see `WebcamLayer` in RenderKit — so at 1× it shows as much
/// of the camera as its shape allows, centred. `zoom` goes in from there, and `offset`
/// slides the window across whatever the zoom and the fill have left over.
///
/// The offset is a fraction of the room there is to move, not of the picture: −1 is the
/// window against one edge, +1 against the other, 0 centred. So it can never ask for a
/// window that runs off the camera's picture, and a setting chosen at one zoom still means
/// "towards the left" at another.
///
/// Measured on the picture as it is *shown* — mirrored, if the bubble is mirrored — so
/// dragging the slider towards the left moves the window towards the left of what is on
/// screen.
public struct WebcamCrop: Codable, Equatable, Sendable {
    public var zoom: Double
    /// −1…1 on each axis, y downwards like every other normalised point in the model.
    public var offset: CGPoint

    public static let zoomRange: ClosedRange<Double> = 1...3

    public init(zoom: Double = 1, offset: CGPoint = .zero) {
        self.zoom = zoom
        self.offset = offset
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        zoom = ((try? container.decodeIfPresent(Double.self, forKey: .zoom)) ?? nil) ?? 1
        offset = ((try? container.decodeIfPresent(CGPoint.self, forKey: .offset)) ?? nil) ?? .zero
    }

    enum CodingKeys: String, CodingKey {
        case zoom, offset
    }

    /// The same crop, held to what can be drawn: a file can ask for a zoom of 40 or an
    /// offset off the side of the picture.
    public var sanitised: WebcamCrop {
        func finite(_ value: Double, _ fallback: Double) -> Double { value.isFinite ? value : fallback }
        return WebcamCrop(zoom: min(max(finite(zoom, 1), Self.zoomRange.lowerBound), Self.zoomRange.upperBound),
                          offset: CGPoint(x: min(max(finite(offset.x, 0), -1), 1),
                                          y: min(max(finite(offset.y, 0), -1), 1)))
    }

    /// Whether this shows the camera exactly as a crop-less bubble would.
    public var isNone: Bool { sanitised == WebcamCrop() }
}

/// How captions are drawn, when there are any.
///
/// One style for every cue rather than per-cue styling: subtitles that change size or
/// colour line by line are a fault, not a feature, and the one thing people do want to
/// change — where they sit, so they miss the thing being demonstrated — is here.
public struct CaptionStyle: Codable, Equatable, Sendable {
    public enum Position: String, Codable, Sendable, CaseIterable {
        case bottom, top

        public var title: String {
            switch self {
            case .bottom: "Bottom"
            case .top: "Top"
            }
        }
    }

    /// The family of type the words are set in.
    ///
    /// Four, all of them the system's own: they are on every Mac, they have every weight,
    /// and a caption set in a font that is missing on the machine that exports it is a
    /// caption in the wrong font.
    public enum Typeface: String, Codable, Sendable, CaseIterable {
        case standard, rounded, serif, monospaced

        public var title: String {
            switch self {
            case .standard: "Standard"
            case .rounded: "Rounded"
            case .serif: "Serif"
            case .monospaced: "Monospaced"
            }
        }
    }

    /// How a line arrives and leaves.
    public enum Animation: String, Codable, Sendable, CaseIterable {
        /// Simply there. For captions that must not move at all.
        case none
        /// A short fade at each end. What every project had before there was a choice.
        case fade
        /// Rises a little as it fades in.
        case rise
        /// Swells slightly past its size and settles.
        case pop

        public var title: String {
            switch self {
            case .none: "None"
            case .fade: "Fade"
            case .rise: "Rise"
            case .pop: "Pop"
            }
        }
    }

    public var isVisible: Bool
    /// Fraction of the output height, like `AnnotationItem.fontSize`, so captions keep
    /// their weight at any export size.
    public var fontSize: Double
    public var color: ColorValue
    /// The plate behind the words. Captions over a bright screenshot are unreadable
    /// without one, and a drop shadow alone is not enough on white.
    public var backgroundOpacity: Double
    public var position: Position
    /// How far in from the top or bottom edge, as a fraction of the output height.
    public var margin: Double
    public var typeface: Typeface
    public var animation: Animation
    /// Light up each word as it is said.
    ///
    /// Off by default. It draws the eye to the captions, which is right for a video made
    /// to be watched without sound and wrong for one where the picture is the point.
    public var highlightsWords: Bool
    /// The colour a word is while it is being said.
    public var highlightColor: ColorValue
    /// A family chosen by name, set in place of `typeface`; empty for the system's own type
    /// in the typeface's design. A family this Mac does not have falls back to `typeface`,
    /// so a project from another Mac still has its captions.
    public var fontFamily: String

    public init(isVisible: Bool = true,
                fontSize: Double = 0.05,
                color: ColorValue = .white,
                backgroundOpacity: Double = 0.55,
                position: Position = .bottom,
                margin: Double = 0.06,
                typeface: Typeface = .standard,
                animation: Animation = .fade,
                highlightsWords: Bool = false,
                highlightColor: ColorValue = ColorValue(r: 1, g: 0.84, b: 0.2),
                fontFamily: String = "") {
        self.isVisible = isVisible
        self.fontSize = fontSize
        self.color = color
        self.backgroundOpacity = backgroundOpacity
        self.position = position
        self.margin = margin
        self.typeface = typeface
        self.animation = animation
        self.highlightsWords = highlightsWords
        self.highlightColor = highlightColor
        self.fontFamily = fontFamily
    }

    /// Field by field, for the reason `CursorStyle.init(from:)` gives: the synthesised
    /// decoder wants every key, so the first setting added here would have cost every
    /// project written before it the whole of its caption style.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, default fallback: @autoclosure () -> T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback()
        }
        isVisible = value(.isVisible, default: true)
        fontSize = value(.fontSize, default: 0.05)
        color = value(.color, default: ColorValue.white)
        backgroundOpacity = value(.backgroundOpacity, default: 0.55)
        position = value(.position, default: .bottom)
        margin = value(.margin, default: 0.06)
        typeface = value(.typeface, default: .standard)
        animation = value(.animation, default: .fade)
        highlightsWords = value(.highlightsWords, default: false)
        highlightColor = value(.highlightColor, default: ColorValue(r: 1, g: 0.84, b: 0.2))
        fontFamily = value(.fontFamily, default: "")
    }

    enum CodingKeys: String, CodingKey {
        case isVisible, fontSize, color, backgroundOpacity, position, margin
        case typeface, animation, highlightsWords, highlightColor, fontFamily
    }
}
