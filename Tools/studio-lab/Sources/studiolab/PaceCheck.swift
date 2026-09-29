import Foundation
import RecordKit
import TimelineKit

/// `studiolab pace <recording.klikrec>` — what "Speed Up Waiting…" would offer for a
/// recording, and what each stretch was measured from: the same analysis the editor runs,
/// printed rather than put in a sheet.
@MainActor
enum PaceCheck {
    static func run(_ arguments: [String]) async -> Int32 {
        guard let path = arguments.first else {
            print("usage: studiolab pace <recording.klikrec>")
            return 2
        }
        let package = RecordingPackage(url: URL(fileURLWithPath: path))
        let document: EditorDocument
        do {
            document = try EditorDocument(package: package)
        } catch {
            print("could not open the recording: \(error)")
            return 1
        }
        guard let url = document.videoURL else { print("no screen recording"); return 1 }
        let started = Date()
        let screen: [ClosedRange<Double>]
        do {
            screen = try await ScreenActivity.measure(videoURL: url)
        } catch {
            print("could not read the picture: \(error)")
            return 1
        }
        let pointer = document.cursorTrack.activity
        let typing = Typing.bursts(in: document.inputSamples).map { $0.start...$0.end }
        let speech = document.timeline.captions.map(\.range)
        func line(_ ranges: [ClosedRange<Double>]) -> String {
            ranges.map { String(format: "%.1f–%.1f", $0.lowerBound, $0.upperBound) }.joined(separator: ", ")
        }
        print(String(format: "edit %.1f s, picture read in %.1f s", document.timeline.duration.seconds, Date().timeIntervalSince(started)))
        print("pointer: \(line(pointer))")
        print("screen:  \(line(screen))")
        print("typing:  \(line(typing))")
        print("speech:  \(speech.count) captions")
        let found = PaceSuggester.suggestions(timeline: document.timeline, pointer: pointer,
                                              screen: screen, typing: typing, speech: speech)
        for s in found {
            print(String(format: "  %@ %.2f–%.2f  %.1f s at %.1f× saves %.1f s",
                         s.reason == .idle ? "still " : "typing", s.range.start.seconds, s.range.end.seconds,
                         s.range.duration.seconds, s.speed, s.saving))
        }
        if found.isEmpty { print("  nothing to speed up") }
        return 0
    }
}
