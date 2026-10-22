import Foundation
import Testing
@testable import RecordKit

/// The states a take passes through, and what may be done to it in each one.
///
/// None of this touches a screen. That is the point: the capture path needs a permission
/// grant, a display and an encoder, so the only part of a recording that can be held still
/// and checked is the state it is in — and the state is where the take was being lost.
/// Pause → Stop used to end with the file discarded, because the button that offered Stop
/// and the guard that performed it answered the question differently.
struct SessionStateTests {
    private typealias State = RecordingSession.State

    private let started = Date(timeIntervalSinceReferenceDate: 1_000)

    private var every: [State] {
        [.idle,
         .preparing,
         .countdown(remaining: 3),
         .recording(startedAt: started),
         .paused(startedAt: started, at: started.addingTimeInterval(4)),
         .finishing,
         .finished(URL(fileURLWithPath: "/tmp/take.cuerec")),
         .failed(.targetDisappeared)]
    }

    // MARK: - Stopping while paused keeps the take

    @Test func `a paused take can still be stopped`() {
        #expect(State.paused(startedAt: started, at: started.addingTimeInterval(4)).isTaking)
    }

    /// The whole of the data-loss bug, as an assertion: a hold is let go of before the
    /// stop, so what `stop()` goes on to finish is a recording rather than nothing.
    @Test func `stopping while paused lets the hold go first, so there is a take left to finish`() {
        let paused = State.paused(startedAt: started, at: started.addingTimeInterval(4))
        let released = paused.released(at: started.addingTimeInterval(10))
        #expect(released?.isTaking == true, "a paused take must have somewhere to resume to")
        guard case .recording = released else {
            Issue.record("resuming a paused take must reach .recording, where stop() can finish the file")
            return
        }
    }

    @Test func `only a take that has footage may be stopped`() {
        for state in every {
            switch state {
            case .recording, .paused: #expect(state.isTaking, "\(state) has footage on disk")
            default: #expect(!state.isTaking, "\(state) has no footage to keep")
            }
        }
    }

    /// The states in which Stop and Discard disagree. A countdown can be abandoned, and
    /// there is nothing there to keep; a running take can be either.
    @Test func `a countdown can be abandoned but not stopped`() {
        let countdown = State.countdown(remaining: 2)
        #expect(countdown.isStarting)
        #expect(countdown.isBusy, "so Discard is offered")
        #expect(!countdown.isTaking, "there is no file yet, so Stop would keep nothing")
    }

    @Test func `nothing may be stopped or discarded once it has already finished`() {
        let finished = State.finished(URL(fileURLWithPath: "/tmp/take.cuerec"))
        #expect(!finished.isTaking)
        #expect(!finished.isBusy)
    }

    // MARK: - Holding and letting go

    @Test func `a running take can be held`() {
        let held = State.recording(startedAt: started).held(at: started.addingTimeInterval(6))
        #expect(held == .paused(startedAt: started, at: started.addingTimeInterval(6)))
    }

    /// The paused stretch is absent from the file, so it has to be absent from the clock
    /// too: six seconds recorded, ten seconds held, and the timer still reads six.
    @Test func `the held stretch is taken off the clock rather than counted`() {
        let paused = State.recording(startedAt: started).held(at: started.addingTimeInterval(6))
        let resumedAt = started.addingTimeInterval(16)
        guard case .recording(let restarted)? = paused?.released(at: resumedAt) else {
            Issue.record("a held take must resume")
            return
        }
        #expect(restarted.timeIntervalSince(started) == 10, "the ten-second hold moved the start forward")
        #expect(resumedAt.timeIntervalSince(restarted) == 6, "so the elapsed time is still the six recorded seconds")
    }

    @Test func `two holds in a row are one hold`() {
        let paused = State.recording(startedAt: started).held(at: started.addingTimeInterval(2))
        #expect(paused?.held(at: started.addingTimeInterval(3)) == nil)
    }

    @Test func `nothing but a held take can be let go of`() {
        for state in every where state != .paused(startedAt: started, at: started.addingTimeInterval(4)) {
            #expect(state.released(at: .now) == nil, "\(state) is not being held")
        }
    }

    @Test func `nothing but a running take can be held`() {
        for state in every where state != .recording(startedAt: started) {
            #expect(state.held(at: .now) == nil, "\(state) has nothing to hold")
        }
    }

    // MARK: - What the bar has to draw

    @Test(arguments: [0, 1, 3, 10])
    func `a countdown says how many seconds are left`(remaining: Int) {
        #expect(State.countdown(remaining: remaining).countdownRemaining == remaining)
    }

    @Test func `only a countdown has seconds left`() {
        for state in every where state.countdownRemaining != nil {
            #expect(state == .countdown(remaining: 3))
        }
    }

    /// A failure the bar cannot read is the same as no failure at all, so the reason has to
    /// come back out of the state — with the system's own words in it.
    @Test func `a failure carries the reason out with it`() {
        let state = State.failed(.lowDiskSpace(bytesAvailable: 42_000_000))
        let failure = state.failure
        #expect(failure == .lowDiskSpace(bytesAvailable: 42_000_000))
        #expect(failure?.errorDescription?.isEmpty == false)
        #expect(failure?.recoverySuggestion == "The part that was recorded has been kept.")
    }

    @Test func `a permission failure says where to go and fix it`() throws {
        let suggestion = try #require(State.failed(.permissionDenied).failure?.recoverySuggestion)
        #expect(suggestion.contains("System Settings"))
    }

    @Test func `no other state reports a failure`() {
        for state in every where state != .failed(.targetDisappeared) {
            #expect(state.failure == nil)
        }
    }

    /// Every state the bar could be handed belongs to exactly one of its shapes. A state
    /// that answers "no" to all of these is one the bar draws nothing for, which is how the
    /// countdown and the failure went missing in the first place.
    @Test func `every state falls into exactly one of the shapes the bar draws`() {
        for state in every {
            let shapes = [state == .idle,
                          state.isStarting,
                          state.isTaking,
                          state == .finishing,
                          state.isFinished,
                          state.failure != nil]
            #expect(shapes.filter { $0 }.count == 1, "\(state) is drawn by \(shapes.filter { $0 }.count) shapes, not one")
        }
    }

    // MARK: - The session itself

    /// The real object, as far as it can be driven without recording a screen: it must
    /// refuse rather than crash, and it must say which refusal it was.
    @Test @MainActor func `an idle session has nothing to stop, pause or discard`() async {
        let session = RecordingSession()
        #expect(session.state == .idle)
        #expect(!session.isPaused)

        session.pause()
        #expect(session.state == .idle, "pausing nothing is not a state change")

        session.resume()
        #expect(session.state == .idle)

        #expect(await session.stop() == .failure(.notRecording))
        #expect(session.state == .idle, "a refused stop leaves the session where it was")

        await session.cancel()
        #expect(session.state == .idle)
    }

    @Test @MainActor func `a failure can be put away, and nothing else can`() {
        let session = RecordingSession()
        session.acknowledgeFailure()
        #expect(session.state == .idle, "acknowledging nothing leaves the session alone")
    }
}

private extension RecordingSession.State {
    /// Only for the exhaustiveness check above, where "which shape draws this?" has to be
    /// asked of every case without `.finished`'s URL getting in the way.
    var isFinished: Bool {
        if case .finished = self { true } else { false }
    }
}
