import CoreMedia
import Foundation
import TimelineKit

/// The stretches offered for speeding up, and which of them are going to be.
struct PacingReview: Equatable {
    struct Item: Identifiable, Equatable {
        let id = UUID()
        let range: CMTimeRange
        let reason: PaceSuggestion.Reason
        var isChosen = true
    }

    enum State: Equatable {
        /// The picture is being read to find when it changes.
        case measuring
        case ready
        case failed(String)
    }

    var state: State = .measuring
    var items: [Item] = []
    var idleSpeed = 4.0
    var typingSpeed = 2.5

    func speed(for reason: PaceSuggestion.Reason) -> Double {
        reason == .idle ? idleSpeed : typingSpeed
    }

    /// Seconds the chosen stretches take off the edit.
    var saving: Double {
        items.filter(\.isChosen).reduce(0) { total, item in
            total + item.range.duration.seconds * (1 - 1 / speed(for: item.reason))
        }
    }

    var chosenCount: Int { items.filter(\.isChosen).count }
}

/// Suggest pacing: the waiting in a recording, found and offered for speeding up.
///
/// The finding is `PaceSuggester`'s; this gathers what it reads — the pointer, the keys,
/// the captions' speech and the picture itself — and holds the review sheet's state.
/// Nothing changes until Apply, and Apply is one step on the undo stack however many
/// stretches it speeds up.
extension EditorModel {
    static let idleSpeeds: [Double] = [2, 3, 4, 6, 8]
    static let typingSpeeds: [Double] = [1.5, 2, 2.5, 3, 4]

    func reviewPacing() {
        pacingTask?.cancel()
        var review = PacingReview()
        if let screen = knownScreenActivity() {
            screenActivity = screen
            review.items = pacingItems(screen: screen)
            review.state = .ready
            pacing = review
            return
        }
        pacing = review
        guard let url = document.videoURL else {
            pacing?.state = .failed("This project has no screen recording to read.")
            return
        }
        let package = document.package
        pacingTask = Task { [weak self] in
            do {
                let screen = try await ScreenActivity.measure(videoURL: url)
                ScreenActivity.cache(screen, in: package, source: url)
                guard let self, !Task.isCancelled, self.pacing != nil else { return }
                self.screenActivity = screen
                self.pacing?.items = self.pacingItems(screen: screen)
                self.pacing?.state = .ready
            } catch is CancellationError {
                return
            } catch {
                self?.pacing?.state = .failed("Cue couldn't read the recording's picture: \(error.localizedDescription)")
            }
        }
    }

    func applyPacing() {
        guard let review = pacing else { return }
        let changes = review.items.filter(\.isChosen).map { (range: $0.range, speed: review.speed(for: $0.reason)) }
        pacing = nil
        guard !changes.isEmpty else { return }
        clearSelection()
        apply(Commands.SetSpeeds(changes, name: changes.count == 1 ? "Speed Up Stretch" : "Speed Up Waiting"))
    }

    func cancelPacing() {
        pacingTask?.cancel()
        pacingTask = nil
        pacing = nil
    }

    /// Whether anything in the edit could be sped up at all.
    var canReviewPacing: Bool { duration > .zero && document.videoURL != nil }

    private func knownScreenActivity() -> [ClosedRange<Double>]? {
        if let screenActivity { return screenActivity }
        guard let url = document.videoURL else { return nil }
        return ScreenActivity.cached(in: document.package, source: url)
    }

    private func pacingItems(screen: [ClosedRange<Double>]) -> [PacingReview.Item] {
        let typing = Typing.bursts(in: document.inputSamples).map { $0.start...$0.end }
        let speech = timeline.captions.map(\.range)
        return PaceSuggester.suggestions(timeline: timeline,
                                         pointer: document.cursorTrack.activity,
                                         screen: screen,
                                         typing: typing,
                                         speech: speech)
            .map { PacingReview.Item(range: $0.range, reason: $0.reason) }
    }
}
