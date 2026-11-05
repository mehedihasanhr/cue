import CoreGraphics
import Foundation
import Testing
@testable import RecordKit

/// The pointer's trips to the camera bubble, kept out of the recording.
struct PointerAsideTests {
    private let step = 1.0 / 120

    /// A run of samples moving in a straight line, written out in order.
    private final class Run {
        var aside = PointerAside()
        var written: [CursorSample] = []
        var now = 0.0

        func feed(from a: CGPoint, to b: CGPoint, seconds: Double) {
            let count = max(1, Int(seconds * 120))
            for index in 0..<count {
                let f = Double(index + 1) / Double(count)
                now += 1.0 / 120
                written += aside.add(CursorSample(t: now, x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f, shape: .arrow))
            }
        }

        func finish() { written += aside.flush() }

        func at(_ t: Double) -> CGPoint {
            let sample = written.min { abs($0.t - t) < abs($1.t - t) }!
            return CGPoint(x: sample.x, y: sample.y)
        }
    }

    private let work = CGPoint(x: 200, y: 200)
    private let bubble = CGPoint(x: 1000, y: 700)
    private let dropped = CGPoint(x: 300, y: 800)
    private let elsewhere = CGPoint(x: 600, y: 300)

    @Test func withNoBubbleEverySampleIsWrittenAsItWas() {
        let run = Run()
        run.feed(from: work, to: elsewhere, seconds: 2)
        run.finish()
        #expect(run.written.count == 240)
        #expect(run.written.last.map { CGPoint(x: $0.x, y: $0.y) } == elsewhere)
        #expect(zip(run.written, run.written.dropFirst()).allSatisfy { $0.t < $1.t })
    }

    @Test func theTripToTheBubbleIsNotInTheRecording() {
        let run = Run()
        run.feed(from: work, to: work, seconds: 1)
        run.feed(from: work, to: bubble, seconds: 0.4)
        run.aside.setAside(true)
        run.feed(from: bubble, to: bubble, seconds: 1)
        run.finish()
        #expect(run.written.allSatisfy { abs($0.x - work.x) < 1 && abs($0.y - work.y) < 1 })
    }

    @Test func draggingTheBubbleIsNotInTheRecording() {
        let run = Run()
        run.feed(from: work, to: work, seconds: 1)
        run.aside.setAside(true)
        run.feed(from: work, to: dropped, seconds: 2)
        run.finish()
        #expect(run.written.allSatisfy { $0.x == work.x && $0.y == work.y })
    }

    @Test func theTripBackIsNotInTheRecordingAndThenItFollowsAgain() {
        let run = Run()
        run.feed(from: work, to: work, seconds: 1)
        run.aside.setAside(true)
        run.feed(from: work, to: dropped, seconds: 1)
        run.aside.setAside(false)
        let leaving = run.now
        run.feed(from: dropped, to: elsewhere, seconds: 0.5)
        let arrived = run.now
        run.feed(from: elsewhere, to: elsewhere, seconds: 1)
        run.finish()
        #expect(run.at(leaving + 0.25) == work, "still where it was, half way back")
        #expect(run.at(arrived + 0.1) == work, "and until it has come to rest")
        #expect(run.at(arrived + 0.9) == elsewhere, "then it is where the hand is")
    }

    @Test func aClickElsewhereEndsItAtOnce() {
        let run = Run()
        run.feed(from: work, to: work, seconds: 1)
        run.aside.setAside(true)
        run.feed(from: work, to: dropped, seconds: 1)
        run.aside.setAside(false)
        run.aside.clicked()
        let clicked = run.now
        run.feed(from: dropped, to: elsewhere, seconds: 0.5)
        run.finish()
        #expect(run.at(clicked + 0.5) == elsewhere)
    }

    @Test func leftOnTheBubbleItStaysPut() {
        let run = Run()
        run.feed(from: work, to: work, seconds: 1)
        run.aside.setAside(true)
        run.feed(from: work, to: dropped, seconds: 1)
        run.aside.setAside(false)
        run.feed(from: dropped, to: dropped, seconds: 3)
        run.finish()
        #expect(run.written.allSatisfy { $0.x == work.x && $0.y == work.y })
    }

    @Test func comingBackToWhereItWasFollowsAtOnce() {
        let run = Run()
        run.feed(from: work, to: work, seconds: 1)
        run.aside.setAside(true)
        run.feed(from: work, to: dropped, seconds: 1)
        run.aside.setAside(false)
        run.feed(from: dropped, to: work, seconds: 0.5)
        let near = CGPoint(x: work.x + 100, y: work.y)
        run.feed(from: work, to: near, seconds: 0.5)
        run.finish()
        #expect(run.written.last.map { CGPoint(x: $0.x, y: $0.y) } == near)
    }

    @Test func noSampleIsLostOrOutOfOrder() {
        let run = Run()
        run.feed(from: work, to: bubble, seconds: 1)
        run.aside.setAside(true)
        run.feed(from: bubble, to: dropped, seconds: 1)
        run.aside.setAside(false)
        run.feed(from: dropped, to: elsewhere, seconds: 1)
        run.finish()
        #expect(run.written.count == 360)
        #expect(zip(run.written, run.written.dropFirst()).allSatisfy { $0.t < $1.t })
    }

    @Test func goingThereAtTheVeryStartOfATakeHoldsTheFirstPlace() {
        var aside = PointerAside()
        aside.setAside(true)
        _ = aside.add(CursorSample(t: 0, x: 10, y: 20, shape: .arrow))
        _ = aside.add(CursorSample(t: 0.01, x: 500, y: 500, shape: .arrow))
        let out = aside.flush()
        #expect(out.allSatisfy { $0.x == 10 && $0.y == 20 })
    }
}
