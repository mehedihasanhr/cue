import CoreGraphics
import Foundation
import TimelineKit

extension EditorModel.NewAnnotation {
    var name: AnnotationItem.KindName {
        switch self {
        case .text: .text
        case .arrow: .arrow
        case .box: .rectangle
        case .ellipse: .ellipse
        case .loop: .loop
        case .line: .line
        case .highlight: .highlight
        case .step: .step
        case .callout: .callout
        }
    }

    var title: String { name.title }

    /// What the menu bar calls it, where there is room to say what a step is.
    var menuTitle: String { self == .step ? "Numbered Step" : title }

    var symbol: String { name.symbol }

    /// The three that are out on buttons in an empty panel, then the two beside the menu of
    /// the rest. Eight labelled buttons do not fit a panel that can be 260 points wide, and
    /// squeezing them turns every label into "Hig…"; the ones reached for most are out, the
    /// others are one click further.
    static let first: [Self] = [.text, .arrow, .box]
    static let second: [Self] = [.step, .callout]
    static let more: [Self] = [.ellipse, .loop, .line, .highlight]

    /// The shapes, which share one button on the canvas bar and open a bar of their own:
    /// eight icons in a row is a palette, and the bar is a toolbar.
    static let shapes: [Self] = [.box, .ellipse, .loop, .line, .highlight]

    /// Where one lands when it is added rather than drawn: the middle of the frame, at a
    /// size that reads without being resized first.
    ///
    /// - Parameter aspect: the finished frame's width over its height. A rect is normalised
    ///   to the frame, so a step that is to be round needs to be narrower than it is tall
    ///   on a wide frame.
    func rect(aspect: Double) -> CGRect {
        let aspect = aspect.isFinite && aspect > 0 ? aspect : 16.0 / 9
        func centred(width: Double, height: Double) -> CGRect {
            CGRect(x: 0.5 - width / 2, y: 0.5 - height / 2, width: width, height: height)
        }
        switch self {
        case .text: return CGRect(x: 0.22, y: 0.44, width: 0.56, height: 0.12)
        case .arrow: return CGRect(x: 0.3, y: 0.35, width: 0.4, height: 0.3)
        case .box: return CGRect(x: 0.3, y: 0.32, width: 0.4, height: 0.36)
        case .ellipse: return centred(width: 0.46 / aspect, height: 0.34)
        // Round a word or two: wider than tall, like the words it goes round.
        case .loop: return centred(width: 0.3, height: 0.16)
        // A band as tall as a line of ordinary text on screen: what a marker goes over.
        case .highlight: return centred(width: 0.4, height: 0.075)
        case .line: return centred(width: 0.4, height: 0.06)
        case .step: return centred(width: 0.1 / aspect, height: 0.1)
        // The bubble above the middle, so the tail points at the middle of the frame.
        case .callout: return CGRect(x: 0.37, y: 0.26, width: 0.26, height: 0.13)
        }
    }

    func kind(nextStep: Int) -> AnnotationItem.Kind {
        switch self {
        // Something legible rather than nothing. An empty label draws no pixels, so a
        // button that added one would look like a button that did nothing.
        case .text: .text("Text")
        case .arrow: .arrow(from: CGPoint(x: 0, y: 1), to: CGPoint(x: 1, y: 0))
        case .box: .rectangle
        case .ellipse: .ellipse
        case .loop: .loop
        case .line: .line(from: CGPoint(x: 0, y: 0.5), to: CGPoint(x: 1, y: 0.5))
        case .highlight: .highlight
        case .step: .step(nextStep)
        case .callout: .callout("Callout", tail: AnnotationItem.defaultTail)
        }
    }

    /// What a new one of this kind looks like, beyond the defaults every annotation has.
    func configure(_ item: inout AnnotationItem) {
        switch self {
        case .highlight:
            item.color = AnnotationItem.markerYellow
        case .callout:
            AnnotationItem.dressAsCallout(&item)
        case .loop:
            // A loop is drawn on, the way it would be drawn on paper.
            item.animation.entrance = .draw
            item.animation.entranceDuration = 0.6
            item.animation.easing = .easeInOut
        default:
            break
        }
    }
}

nonisolated extension AnnotationItem {
    /// A highlighter's yellow. Red at a third of its strength over text reads as a mistake
    /// rather than as emphasis.
    static let markerYellow = ColorValue(r: 1, g: 0.86, b: 0.1)

    /// A callout is a bubble with words in it: filled in its colour, the words centred in
    /// white or black, a little smaller than a title.
    static func dressAsCallout(_ item: inout AnnotationItem) {
        item.style.backdrop = .solid
        item.style.alignment = .center
        item.fontSize = 0.04
    }
}

nonisolated extension AnnotationItem.KindName {
    var symbol: String {
        switch self {
        case .text: "textformat"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .loop: "lasso"
        case .line: "line.diagonal"
        case .highlight: "highlighter"
        case .step: "number.circle"
        case .callout: "text.bubble"
        case .image: "photo"
        }
    }
}

/// Changing what an annotation is, and the parts of it that only some kinds have: a step's
/// number, a line's ends, a callout's tail. Each is one command, so each is one undo step.
extension EditorModel {
    /// Switches kind, keeping what still means something — see `Kind.converted(to:)`.
    func setKind(ofAnnotation id: UUID, to name: AnnotationItem.KindName) {
        guard let item = annotation(id), item.kind.name != name else { return }
        let next = timeline.nextStepNumber
        restyleAnnotation(id, "Change to \(name.title)") { item in
            let wasCallout = item.kind.name == .callout
            item.kind = item.kind.converted(to: name, nextStep: next)
            // A box turned into a callout with nothing behind its words would be an
            // outline with words floating in it; it becomes the bubble a new one is.
            if name == .callout, !wasCallout, item.style.backdrop == .none {
                AnnotationItem.dressAsCallout(&item)
            }
        }
    }

    func setStepNumber(ofAnnotation id: UUID, to number: Int) {
        guard let item = annotation(id), case .step(let current) = item.kind, current != number else { return }
        restyleAnnotation(id, "Step Number") { $0.kind = .step(number) }
    }

    func setText(ofAnnotation id: UUID, to text: String) {
        restyleAnnotation(id, "Annotation Text") { $0.kind = $0.kind.withText(text) }
    }

    /// Puts an arrow's or a line's ends where the canvas says, in a box rebuilt round them.
    ///
    /// The turn goes to zero because the ends now say which way it points: a turned box
    /// with ends in it and an unturned one with the same ends are the same line.
    func setEnds(ofAnnotation id: UUID, rect: CGRect, from: CGPoint, to: CGPoint) {
        restyleAnnotation(id, "Move End") { item in
            guard !item.isLocked, item.kind.ends != nil else { return }
            item.rect = rect
            item.rotation = 0
            item.kind = item.kind.withEnds(from: from, to: to)
        }
    }

    /// Points a callout's tail at `tail`, normalised to its bubble.
    func setTail(ofAnnotation id: UUID, to tail: CGPoint) {
        restyleAnnotation(id, "Move Tail") { item in
            guard !item.isLocked, case .callout(let text, _) = item.kind else { return }
            item.kind = .callout(text, tail: tail)
        }
    }
}
