import CoreGraphics
import Foundation

/// A way of dressing a video, kept apart from any one recording.
///
/// **What is in a look, and why.** Everything about how the finished video looks that
/// would be wanted again on the next recording, and nothing that belongs to this one:
///
/// - The frame (`FrameStyle`): background, padding, corners, shadow, background blur,
///   border, the window drawn round it, and the shape — the preset and the typed
///   numbers. *Not* the crop: a crop is a rectangle of one particular recording.
/// - The pointer (`CursorStyle`), all of it, including whether it is shown. "No
///   pointer" is a way a video can be dressed.
/// - The captions (`CaptionStyle`), all of it. How words are set is a style; the words
///   themselves are cues on the timeline and stay there.
/// - The camera (`CameraStyle`): how a zoom follows the pointer, whether the whole
///   frame zooms, and whether fast camera moves are softened. It changes the feel of every zoom, and none of it names a moment.
/// - The camera bubble (`WebcamSettings`): where it sits, its size, roundness, mirror,
///   shadow, border, and what happens to the room behind the person. *Not* whether it is
///   on: a recording either has a camera in it or it does not, and a look must not switch
///   on a bubble with nothing behind it or switch off one somebody filmed. *Not* the
///   camera's crop either, for the screen crop's reason: it frames one take's face, and
///   the next take sits somewhere else in the picture.
///
/// Nothing with a time on it — clips, zooms, blurs, annotations, cues, sounds, pointer
/// stretches — and nothing that is a fact about the footage.
///
/// **A picture of the user's own** (`FrameStyle.Background.image`) is not carried
/// either. It lives inside the recording's package, so the path means nothing in
/// another project; a look saved from such a project simply leaves the background out,
/// and applying it keeps whatever background the project already has. A background movie
/// is left out for the same reason, and so is a colour grade's `.cube` table — the grade's
/// sliders travel, the table stays with the recording it was loaded into.
///
/// **Every field is optional.** A look says only what it says: applying one changes the
/// fields it carries and leaves the rest of the project alone. That is what lets a file
/// written by an older build apply to a newer one — the fields it never heard of are
/// simply not in it — and a file from a newer build apply to this one, whose unknown
/// keys are skipped. A field that cannot be read (a kind of click mark this build does
/// not draw, say) is treated the same way as one that is missing.
public struct Look: Equatable, Sendable {
    /// What this file was written by, so a future reader knows what it is looking at.
    public static let currentVersion = 1
    /// The extension a look file wears.
    public static let fileExtension = "cuestyle"

    public var name: String
    public var frame: Frame
    public var pointer: Pointer
    public var captions: Captions
    public var camera: Camera
    public var webcam: Webcam

    public init(name: String,
                frame: Frame = Frame(),
                pointer: Pointer = Pointer(),
                captions: Captions = Captions(),
                camera: Camera = Camera(),
                webcam: Webcam = Webcam()) {
        self.name = name
        self.frame = frame
        self.pointer = pointer
        self.captions = captions
        self.camera = camera
        self.webcam = webcam
    }

    /// Everything look-worthy about a project, as a look.
    public init(name: String, capturing timeline: Timeline) {
        self.init(name: name,
                  frame: Frame(timeline.style),
                  pointer: Pointer(timeline.cursor),
                  captions: Captions(timeline.captionStyle),
                  camera: Camera(timeline.camera),
                  webcam: Webcam(timeline.webcam))
    }

    /// Whether this look says nothing at all.
    public var isEmpty: Bool {
        frame.isEmpty && pointer.isEmpty && captions.isEmpty && camera.isEmpty && webcam.isEmpty
    }

    /// Dresses the project in this look: every field the look carries is set, and
    /// nothing else is touched.
    public func apply(to timeline: inout Timeline) {
        frame.apply(to: &timeline.style)
        pointer.apply(to: &timeline.cursor)
        captions.apply(to: &timeline.captionStyle)
        camera.apply(to: &timeline.camera)
        webcam.apply(to: &timeline.webcam)
    }

    public func applied(to timeline: Timeline) -> Timeline {
        var dressed = timeline
        apply(to: &dressed)
        return dressed
    }

    /// Whether the project is already wearing this look — applying it would change
    /// nothing. An empty look matches nothing, or every tile in the picker would be
    /// ringed at once.
    public func matches(_ timeline: Timeline) -> Bool {
        !isEmpty && applied(to: timeline) == timeline
    }
}

// MARK: - The parts

/// Reads one optional field, and reads a field that will not decode as one that is not
/// there. Every part below decodes with this, which is the whole of the forward and
/// backward compatibility story.
private func field<T: Decodable, Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, _ key: Key) -> T? {
    (try? container.decodeIfPresent(T.self, forKey: key)) ?? nil
}

private func set<T>(_ target: inout T, _ value: T?) {
    if let value { target = value }
}

public extension Look {
    struct Frame: Codable, Equatable, Sendable {
        public var background: FrameStyle.Background?
        public var padding: Double?
        public var cornerRadius: Double?
        public var shadowRadius: Double?
        public var shadowOpacity: Double?
        public var backgroundBlur: Double?
        public var aspect: AspectPreset?
        public var customAspect: CustomAspect?
        public var borderWidth: Double?
        public var borderColor: ColorValue?
        public var chrome: WindowChrome?
        public var perspective: FramePerspective?
        /// Without its table — see `Look`. Applying it keeps the project's own table.
        public var grade: ColorGrade?

        public init(background: FrameStyle.Background? = nil,
                    padding: Double? = nil,
                    cornerRadius: Double? = nil,
                    shadowRadius: Double? = nil,
                    shadowOpacity: Double? = nil,
                    backgroundBlur: Double? = nil,
                    aspect: AspectPreset? = nil,
                    customAspect: CustomAspect? = nil,
                    borderWidth: Double? = nil,
                    borderColor: ColorValue? = nil,
                    chrome: WindowChrome? = nil,
                    perspective: FramePerspective? = nil,
                    grade: ColorGrade? = nil) {
            self.perspective = perspective
            self.grade = grade
            self.background = background
            self.padding = padding
            self.cornerRadius = cornerRadius
            self.shadowRadius = shadowRadius
            self.shadowOpacity = shadowOpacity
            self.backgroundBlur = backgroundBlur
            self.aspect = aspect
            self.customAspect = customAspect
            self.borderWidth = borderWidth
            self.borderColor = borderColor
            self.chrome = chrome
        }

        public init(_ style: FrameStyle) {
            // A picture or a movie inside the project is left out — see `Look`.
            switch style.background {
            case .image, .video: background = nil
            default: background = style.background
            }
            perspective = style.perspective
            var grade = style.grade
            grade.lut = nil
            self.grade = grade
            padding = style.padding
            cornerRadius = style.cornerRadius
            shadowRadius = style.shadowRadius
            shadowOpacity = style.shadowOpacity
            backgroundBlur = style.backgroundBlur
            aspect = style.aspect
            customAspect = style.customAspect
            borderWidth = style.borderWidth
            borderColor = style.borderColor
            chrome = style.chrome
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            background = field(c, .background)
            padding = field(c, .padding)
            cornerRadius = field(c, .cornerRadius)
            shadowRadius = field(c, .shadowRadius)
            shadowOpacity = field(c, .shadowOpacity)
            backgroundBlur = field(c, .backgroundBlur)
            aspect = field(c, .aspect)
            customAspect = field(c, .customAspect)
            borderWidth = field(c, .borderWidth)
            borderColor = field(c, .borderColor)
            chrome = field(c, .chrome)
            perspective = (field(c, .perspective) as FramePerspective?)?.sanitised
            grade = (field(c, .grade) as ColorGrade?).map { grade in
                var held = grade.sanitised
                held.lut = nil
                return held
            }
        }

        enum CodingKeys: String, CodingKey {
            case background, padding, cornerRadius, shadowRadius, shadowOpacity, backgroundBlur
            case aspect, customAspect, borderWidth, borderColor, chrome
            case perspective, grade
        }

        public var isEmpty: Bool {
            background == nil && padding == nil && cornerRadius == nil && shadowRadius == nil
                && shadowOpacity == nil && backgroundBlur == nil && aspect == nil
                && customAspect == nil && borderWidth == nil && borderColor == nil
                && chrome == nil && perspective == nil && grade == nil
        }

        public func apply(to style: inout FrameStyle) {
            set(&style.background, background)
            set(&style.padding, padding)
            set(&style.cornerRadius, cornerRadius)
            set(&style.shadowRadius, shadowRadius)
            set(&style.shadowOpacity, shadowOpacity)
            set(&style.backgroundBlur, backgroundBlur)
            set(&style.aspect, aspect)
            set(&style.customAspect, customAspect)
            set(&style.borderWidth, borderWidth)
            set(&style.borderColor, borderColor)
            set(&style.chrome, chrome)
            set(&style.perspective, perspective)
            // The project's own table stays: a look never carries one.
            if var grade {
                grade.lut = style.grade.lut
                style.grade = grade
            }
        }
    }

    struct Pointer: Codable, Equatable, Sendable {
        public var isVisible: Bool?
        public var scale: Double?
        public var smoothing: Double?
        public var clickEffect: Bool?
        public var motionBlur: Bool?
        public var sizeIsIndependentOfZoom: Bool?
        public var clickHighlight: Bool?
        public var clickColor: ColorValue?
        public var clickSize: Double?
        public var usesRecordedArtwork: Bool?
        public var hidesWhenIdle: Bool?
        public var idleDelay: Double?
        public var alwaysArrow: Bool?
        public var steadiesShape: Bool?
        public var clickStyle: CursorStyle.ClickStyle?
        public var clickSound: Bool?
        public var clickSoundKind: CursorStyle.ClickSound?
        public var clickSoundVolume: Double?
        public var appearance: CursorStyle.Appearance?
        public var dotColor: ColorValue?
        public var spotlight: PointerSpotlight?
        public var magnifier: PointerMagnifier?
        public var loop: PointerLoop?
        public var sway: PointerSway?

        public init() {}

        public init(_ style: CursorStyle) {
            isVisible = style.isVisible
            scale = style.scale
            smoothing = style.smoothing
            clickEffect = style.clickEffect
            motionBlur = style.motionBlur
            sizeIsIndependentOfZoom = style.sizeIsIndependentOfZoom
            clickHighlight = style.clickHighlight
            clickColor = style.clickColor
            clickSize = style.clickSize
            usesRecordedArtwork = style.usesRecordedArtwork
            hidesWhenIdle = style.hidesWhenIdle
            idleDelay = style.idleDelay
            alwaysArrow = style.alwaysArrow
            steadiesShape = style.steadiesShape
            clickStyle = style.clickStyle
            clickSound = style.clickSound
            clickSoundKind = style.clickSoundKind
            clickSoundVolume = style.clickSoundVolume
            appearance = style.appearance
            dotColor = style.dotColor
            spotlight = style.spotlight
            magnifier = style.magnifier
            loop = style.loop
            sway = style.sway
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            isVisible = field(c, .isVisible)
            scale = field(c, .scale)
            smoothing = field(c, .smoothing)
            clickEffect = field(c, .clickEffect)
            motionBlur = field(c, .motionBlur)
            sizeIsIndependentOfZoom = field(c, .sizeIsIndependentOfZoom)
            clickHighlight = field(c, .clickHighlight)
            clickColor = field(c, .clickColor)
            clickSize = field(c, .clickSize)
            usesRecordedArtwork = field(c, .usesRecordedArtwork)
            hidesWhenIdle = field(c, .hidesWhenIdle)
            idleDelay = field(c, .idleDelay)
            alwaysArrow = field(c, .alwaysArrow)
            steadiesShape = field(c, .steadiesShape)
            clickStyle = field(c, .clickStyle)
            clickSound = field(c, .clickSound)
            clickSoundKind = field(c, .clickSoundKind)
            clickSoundVolume = field(c, .clickSoundVolume)
            appearance = field(c, .appearance)
            dotColor = field(c, .dotColor)
            spotlight = field(c, .spotlight)
            magnifier = field(c, .magnifier)
            loop = field(c, .loop)
            sway = field(c, .sway)
        }

        enum CodingKeys: String, CodingKey {
            case isVisible, scale, smoothing, clickEffect, motionBlur, sizeIsIndependentOfZoom
            case clickHighlight, clickColor, clickSize, usesRecordedArtwork
            case hidesWhenIdle, idleDelay, alwaysArrow, steadiesShape, clickStyle
            case clickSound, clickSoundKind, clickSoundVolume
            case appearance, dotColor, spotlight, magnifier, loop, sway
        }

        public var isEmpty: Bool {
            isVisible == nil && scale == nil && smoothing == nil && clickEffect == nil
                && motionBlur == nil && sizeIsIndependentOfZoom == nil && clickHighlight == nil
                && clickColor == nil && clickSize == nil && usesRecordedArtwork == nil
                && hidesWhenIdle == nil && idleDelay == nil && alwaysArrow == nil
                && steadiesShape == nil && clickStyle == nil
                && clickSound == nil && clickSoundKind == nil && clickSoundVolume == nil
                && appearance == nil && dotColor == nil && spotlight == nil && magnifier == nil
                && loop == nil && sway == nil
        }

        public func apply(to style: inout CursorStyle) {
            set(&style.isVisible, isVisible)
            set(&style.scale, scale)
            set(&style.smoothing, smoothing)
            set(&style.clickEffect, clickEffect)
            set(&style.motionBlur, motionBlur)
            set(&style.sizeIsIndependentOfZoom, sizeIsIndependentOfZoom)
            set(&style.clickHighlight, clickHighlight)
            set(&style.clickColor, clickColor)
            set(&style.clickSize, clickSize)
            set(&style.usesRecordedArtwork, usesRecordedArtwork)
            set(&style.hidesWhenIdle, hidesWhenIdle)
            // Through the same clamp the initialiser applies, so a file cannot ask for a
            // delay the slider could not.
            if let idleDelay {
                style.idleDelay = min(max(idleDelay, CursorStyle.idleDelayRange.lowerBound),
                                      CursorStyle.idleDelayRange.upperBound)
            }
            set(&style.alwaysArrow, alwaysArrow)
            set(&style.steadiesShape, steadiesShape)
            set(&style.clickStyle, clickStyle)
            set(&style.clickSound, clickSound)
            set(&style.clickSoundKind, clickSoundKind)
            if let clickSoundVolume, clickSoundVolume.isFinite {
                style.clickSoundVolume = min(max(clickSoundVolume, 0), 1)
            }
            set(&style.appearance, appearance)
            set(&style.dotColor, dotColor)
            set(&style.spotlight, spotlight)
            set(&style.magnifier, magnifier)
            set(&style.loop, loop)
            set(&style.sway, sway)
        }
    }

    struct Captions: Codable, Equatable, Sendable {
        public var isVisible: Bool?
        public var fontSize: Double?
        public var color: ColorValue?
        public var backgroundOpacity: Double?
        public var position: CaptionStyle.Position?
        public var margin: Double?
        public var typeface: CaptionStyle.Typeface?
        public var animation: CaptionStyle.Animation?
        public var highlightsWords: Bool?
        public var highlightColor: ColorValue?
        /// Empty is a statement too — the system's type — so a look taken from a project
        /// without a family takes the family off the project it is put on.
        public var fontFamily: String?

        public init() {}

        public init(_ style: CaptionStyle) {
            isVisible = style.isVisible
            fontSize = style.fontSize
            color = style.color
            backgroundOpacity = style.backgroundOpacity
            position = style.position
            margin = style.margin
            typeface = style.typeface
            animation = style.animation
            highlightsWords = style.highlightsWords
            highlightColor = style.highlightColor
            fontFamily = style.fontFamily
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            isVisible = field(c, .isVisible)
            fontSize = field(c, .fontSize)
            color = field(c, .color)
            backgroundOpacity = field(c, .backgroundOpacity)
            position = field(c, .position)
            margin = field(c, .margin)
            typeface = field(c, .typeface)
            animation = field(c, .animation)
            highlightsWords = field(c, .highlightsWords)
            highlightColor = field(c, .highlightColor)
            fontFamily = field(c, .fontFamily)
        }

        enum CodingKeys: String, CodingKey {
            case isVisible, fontSize, color, backgroundOpacity, position, margin
            case typeface, animation, highlightsWords, highlightColor, fontFamily
        }

        public var isEmpty: Bool {
            isVisible == nil && fontSize == nil && color == nil && backgroundOpacity == nil
                && position == nil && margin == nil && typeface == nil && animation == nil
                && highlightsWords == nil && highlightColor == nil && fontFamily == nil
        }

        public func apply(to style: inout CaptionStyle) {
            set(&style.isVisible, isVisible)
            set(&style.fontSize, fontSize)
            set(&style.color, color)
            set(&style.backgroundOpacity, backgroundOpacity)
            set(&style.position, position)
            set(&style.margin, margin)
            set(&style.typeface, typeface)
            set(&style.animation, animation)
            set(&style.highlightsWords, highlightsWords)
            set(&style.highlightColor, highlightColor)
            set(&style.fontFamily, fontFamily)
        }
    }

    struct Camera: Codable, Equatable, Sendable {
        public var steadiness: Double?
        public var follow: Double?
        public var safeArea: Double?
        public var zoomsWholeFrame: Bool?
        public var glidesBetweenZooms: Bool?
        public var keepsZoomedInFor: Double?
        public var motionBlur: Bool?
        public var wholeVideoZoom: Double?
        public var zoomSpeed: ZoomSpeed?

        public init() {}

        public init(_ style: CameraStyle) {
            steadiness = style.steadiness
            follow = style.follow
            safeArea = style.safeArea
            zoomsWholeFrame = style.zoomsWholeFrame
            glidesBetweenZooms = style.glidesBetweenZooms
            keepsZoomedInFor = style.keepsZoomedInFor
            motionBlur = style.motionBlur
            wholeVideoZoom = style.wholeVideoZoom
            zoomSpeed = style.zoomSpeed
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            steadiness = field(c, .steadiness)
            follow = field(c, .follow)
            safeArea = field(c, .safeArea)
            zoomsWholeFrame = field(c, .zoomsWholeFrame)
            glidesBetweenZooms = field(c, .glidesBetweenZooms)
            keepsZoomedInFor = field(c, .keepsZoomedInFor)
            motionBlur = field(c, .motionBlur)
            wholeVideoZoom = field(c, .wholeVideoZoom)
            zoomSpeed = field(c, .zoomSpeed)
        }

        enum CodingKeys: String, CodingKey {
            case steadiness, follow, safeArea, zoomsWholeFrame, glidesBetweenZooms, keepsZoomedInFor, motionBlur
            case wholeVideoZoom, zoomSpeed
        }

        public var isEmpty: Bool {
            steadiness == nil && follow == nil && safeArea == nil && zoomsWholeFrame == nil
                && glidesBetweenZooms == nil && keepsZoomedInFor == nil && motionBlur == nil
                && wholeVideoZoom == nil && zoomSpeed == nil
        }

        public func apply(to style: inout CameraStyle) {
            set(&style.steadiness, steadiness)
            set(&style.follow, follow)
            set(&style.safeArea, safeArea)
            set(&style.zoomsWholeFrame, zoomsWholeFrame)
            set(&style.glidesBetweenZooms, glidesBetweenZooms)
            set(&style.keepsZoomedInFor, keepsZoomedInFor)
            set(&style.motionBlur, motionBlur)
            set(&style.zoomSpeed, zoomSpeed)
            // Through the same clamp the renderer reads it by, so a file cannot hold a
            // project at 40×.
            if let wholeVideoZoom, wholeVideoZoom.isFinite {
                style.wholeVideoZoom = min(max(wholeVideoZoom, CameraStyle.wholeVideoZoomRange.lowerBound),
                                           CameraStyle.wholeVideoZoomRange.upperBound)
            }
        }
    }

    struct Webcam: Codable, Equatable, Sendable {
        public var corner: WebcamSettings.Corner?
        public var position: CGPoint?
        public var size: Double?
        public var roundness: Double?
        public var isMirrored: Bool?
        public var shadowOpacity: Double?
        public var reactsToZoom: Bool?
        public var borderWidth: Double?
        public var borderColor: ColorValue?
        public var background: WebcamSettings.Background?
        public var backgroundBlur: Double?

        public init() {}

        /// Everything but `isEnabled` and `crop` — see `Look`.
        public init(_ settings: WebcamSettings) {
            corner = settings.corner
            position = settings.position
            size = settings.size
            roundness = settings.roundness
            isMirrored = settings.isMirrored
            shadowOpacity = settings.shadowOpacity
            reactsToZoom = settings.reactsToZoom
            borderWidth = settings.borderWidth
            borderColor = settings.borderColor
            background = settings.background
            backgroundBlur = settings.backgroundBlur
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            corner = field(c, .corner)
            position = field(c, .position)
            size = field(c, .size)
            roundness = field(c, .roundness)
            isMirrored = field(c, .isMirrored)
            shadowOpacity = field(c, .shadowOpacity)
            reactsToZoom = field(c, .reactsToZoom)
            borderWidth = field(c, .borderWidth)
            borderColor = field(c, .borderColor)
            background = field(c, .background)
            backgroundBlur = field(c, .backgroundBlur)
        }

        enum CodingKeys: String, CodingKey {
            case corner, position, size, roundness, isMirrored, shadowOpacity, reactsToZoom
            case borderWidth, borderColor, background, backgroundBlur
        }

        public var isEmpty: Bool {
            corner == nil && position == nil && size == nil && roundness == nil
                && isMirrored == nil && shadowOpacity == nil && reactsToZoom == nil
                && borderWidth == nil && borderColor == nil && background == nil
                && backgroundBlur == nil
        }

        public func apply(to settings: inout WebcamSettings) {
            set(&settings.corner, corner)
            set(&settings.position, position)
            set(&settings.size, size)
            set(&settings.roundness, roundness)
            set(&settings.isMirrored, isMirrored)
            set(&settings.shadowOpacity, shadowOpacity)
            set(&settings.reactsToZoom, reactsToZoom)
            // Through the inspector's own limits, so a file cannot ask for a border the
            // slider could not.
            if let borderWidth, borderWidth.isFinite {
                settings.borderWidth = min(max(borderWidth, WebcamSettings.borderWidthRange.lowerBound),
                                           WebcamSettings.borderWidthRange.upperBound)
            }
            set(&settings.borderColor, borderColor)
            set(&settings.background, background)
            if let backgroundBlur, backgroundBlur.isFinite {
                settings.backgroundBlur = min(max(backgroundBlur, 0), 1)
            }
        }
    }
}

// MARK: - The file

extension Look: Codable {
    enum CodingKeys: String, CodingKey {
        case version, name, frame, pointer, captions, camera, webcam
    }

    /// Reads a look written by any build. A part that is missing, or that will not
    /// decode as a whole, is an empty part; inside a part, each field fends for itself.
    /// The version is read and kept only for a future reader — nothing here refuses a
    /// newer file, because a newer file is exactly the one whose extra fields are meant
    /// to be skipped.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = field(c, .name) ?? ""
        frame = field(c, .frame) ?? Frame()
        pointer = field(c, .pointer) ?? Pointer()
        captions = field(c, .captions) ?? Captions()
        camera = field(c, .camera) ?? Camera()
        webcam = field(c, .webcam) ?? Webcam()
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentVersion, forKey: .version)
        try c.encode(name, forKey: .name)
        try c.encode(frame, forKey: .frame)
        try c.encode(pointer, forKey: .pointer)
        try c.encode(captions, forKey: .captions)
        try c.encode(camera, forKey: .camera)
        try c.encode(webcam, forKey: .webcam)
    }

    /// The bytes of a `.cuestyle` file: JSON, keys in a stable order, readable in a
    /// text editor — it is a file people are meant to keep and pass around.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// A look read back from a file, or `nil` for bytes that are not a look at all —
    /// which, since every field is optional, means anything that is not a JSON object.
    public static func decoded(from data: Data) -> Look? {
        try? JSONDecoder().decode(Look.self, from: data)
    }
}
