import AppKit
import Foundation
import RecordKit

/// `studiolab pointer [--target display|area|window] [--no-pause] [--out <folder>]` —
/// record a scripted pointer, then measure the recording.
///
/// `studiolab analyze <recording.klikrec>` — measure one that was already made.
/// `studiolab frames <recording.klikrec> <from> <to>` — every frame and sample in a stretch.
/// `studiolab stream` — ask ScreenCaptureKit what its timestamps mean.
///
/// `studiolab stage` is the blank window the pointer performs over. It is a process of its
/// own because the recorder hears clicks through a *global* monitor, and a global monitor
/// is never told about events delivered to its own application.
@main
enum LabMain {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let arguments = Array(CommandLine.arguments.dropFirst())

        if arguments.first == "stage" {
            Stage.show(arguments: Array(arguments.dropFirst()))
            application.run()
            return
        }

        // Operating another app needs no run loop of its own, and must not become an app
        // with a Dock icon while it does it.
        if let command = arguments.first, ["tree", "menus", "press", "set", "key", "shot", "windows", "resize", "drag"].contains(command) {
            exit(MainActor.assumeIsolated { Drive.run(arguments) })
        }

        Task { @MainActor in
            let code = await Lab.run(arguments)
            exit(code)
        }
        application.run()
    }
}

/// A white window for the pointer to perform over.
///
/// Everything the analysis does depends on the pointer being the only dark thing in the
/// frame, which no real desktop can promise and this can.
enum Stage {
    private static var window: NSWindow?

    /// `stage <seconds>` covers the screen; `stage <seconds> x y width height` is an
    /// ordinary titled window at that frame, in the pointer's coordinates (y downwards).
    static func show(arguments: [String]) {
        guard let screen = NSScreen.main else { exit(1) }
        let seconds = Double(arguments.first ?? "") ?? 45
        let numbers = arguments.dropFirst().compactMap(Double.init)

        let window: NSWindow
        if numbers.count == 4 {
            let frame = NSRect(x: numbers[0],
                               y: screen.frame.height - numbers[1] - numbers[3],
                               width: numbers[2], height: numbers[3])
            window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.setFrame(frame, display: false)
            window.title = "Studio Lab Stage"
        } else {
            window = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.hasShadow = false
        }
        window.level = .floating
        window.backgroundColor = .white
        window.isOpaque = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.orderFrontRegardless()
        self.window = window

        // Never left up. If the process that asked for the stage dies, a white sheet over
        // somebody's whole screen with no way to dismiss it is not an acceptable leftover.
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
    }
}

/// What a probe recorded, and what it was told to record.
struct ProbeScript: Codable {
    /// "display", "area" or "window".
    var target: String
    /// The recorded thing's top-left on the desk, in the pointer's coordinates.
    var origin: [Double]
    /// The blank part of the desk the pointer performed in.
    var field: [Double]
    var events: [ScriptRecord]

    var originPoint: CGPoint { CGPoint(x: origin[0], y: origin[1]) }
    var fieldRect: CGRect { CGRect(x: field[0], y: field[1], width: field[2], height: field[3]) }
}

@MainActor
enum Lab {
    static func run(_ arguments: [String]) async -> Int32 {
        guard let command = arguments.first else {
            print("usage: studiolab pointer [--target display|area|window] [--no-pause] [--out <folder>] | analyze <recording> | frames <recording> <from> <to> | stream")
            return 2
        }
        switch command {
        case "pointer":
            let folder = value(after: "--out", in: arguments)
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("studiolab", isDirectory: true)
            return await pointer(target: value(after: "--target", in: arguments) ?? "display",
                                 includingPause: !arguments.contains("--no-pause"),
                                 into: folder)
        case "analyze":
            guard arguments.count > 1 else { return 2 }
            return await analyze(URL(fileURLWithPath: arguments[1]))
        case "stream":
            return await StreamProbe.run()
        case "camera":
            return await CameraCheck.run(Array(arguments.dropFirst()))
        case "renderbench":
            return await RenderBench.run(Array(arguments.dropFirst()))
        case "pace":
            return await PaceCheck.run(Array(arguments.dropFirst()))
        case "everything":
            return await ExportCheck.run(Array(arguments.dropFirst()), everything: true)
        case "export":
            return await ExportCheck.run(Array(arguments.dropFirst()))
        case "frames":
            guard arguments.count > 3, let from = Double(arguments[2]), let to = Double(arguments[3]) else { return 2 }
            return await frames(URL(fileURLWithPath: arguments[1]), from: from, to: to)
        default:
            print("unknown command \(command)")
            return 2
        }
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    // MARK: - Recording

    private static func pointer(target kind: String, includingPause: Bool, into folder: URL) async -> Int32 {
        guard let screen = NSScreen.main else { return 1 }
        let display = CGMainDisplayID()

        // Where the recording is of, where the stage goes, and the blank field inside both.
        let windowFrame = CGRect(x: 180, y: 110, width: min(1_120, screen.frame.width - 260),
                                 height: min(720, screen.frame.height - 200))
        let field: CGRect
        var stageArguments: [String] = []
        switch kind {
        case "display":
            field = CGRect(x: 120, y: 120, width: screen.frame.width - 240, height: screen.frame.height - 240)
        case "area":
            field = CGRect(x: 240, y: 160, width: min(1_000, screen.frame.width - 400),
                           height: min(620, screen.frame.height - 300))
        case "window":
            // Inside the window's content, clear of its title bar.
            field = windowFrame.insetBy(dx: 40, dy: 50).offsetBy(dx: 0, dy: 14)
            stageArguments = [windowFrame.minX, windowFrame.minY, windowFrame.width, windowFrame.height].map { String(Double($0)) }
        default:
            print("unknown target \(kind)")
            return 2
        }

        let script = MouseScript(field: field)
        let steps = script.standard(includingPause: includingPause)
        let length = (steps.last?.at ?? 0) + 4

        let front = NSWorkspace.shared.frontmostApplication
        let stage = Process()
        stage.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        stage.arguments = ["stage", String(length + 10)] + stageArguments
        do { try stage.run() } catch {
            print("couldn't put the stage up: \(error.localizedDescription)")
            return 1
        }
        defer {
            stage.terminate()
            front?.activate()
        }
        try? await Task.sleep(for: .seconds(1.5))

        let target: CaptureTarget
        let origin: CGPoint
        switch kind {
        case "area":
            let rect = field.insetBy(dx: -40, dy: -40)
            target = .area(display: display, rect: rect)
            origin = rect.origin
        case "window":
            guard let id = windowID(ownedBy: stage.processIdentifier) else {
                print("the stage has no window to record")
                return 1
            }
            target = .window(id)
            origin = windowFrame.origin
        default:
            target = .display(display)
            origin = .zero
        }

        let session = RecordingSession()
        let configuration = RecordingConfiguration(target: target,
                                                   destination: folder,
                                                   name: "Pointer probe \(kind)",
                                                   // The one thing the product never does,
                                                   // and the reason this is a measurement:
                                                   // the real pointer, in the picture.
                                                   capturesCursorInVideo: true,
                                                   systemAudio: false,
                                                   capturesFocus: false)
        await session.start(configuration, countdown: 0)
        guard case .recording = session.state else {
            print("the recording did not start: \(session.state)")
            return 1
        }
        // The stream takes a moment to produce its first frame, and the first frame is
        // what starts the clock.
        try? await Task.sleep(for: .seconds(1))

        let events: [ScriptEvent] = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                let events = MouseScript.perform(steps,
                                                 pause: { MainActor.assumeIsolated { session.pause() } },
                                                 resume: { MainActor.assumeIsolated { session.resume() } })
                continuation.resume(returning: events)
            }
        }
        try? await Task.sleep(for: .seconds(0.8))

        guard case .success(let url) = await session.stop() else {
            print("the recording did not finish: \(session.state)")
            return 1
        }
        stage.terminate()

        let probe = ProbeScript(target: kind,
                                origin: [origin.x, origin.y],
                                field: [field.minX, field.minY, field.width, field.height],
                                events: events.map(ScriptRecord.init))
        if let data = try? JSONEncoder().encode(probe) {
            try? data.write(to: url.appendingPathComponent("lab-script.json"))
        }
        print("recorded \(url.path(percentEncoded: false))")
        return await analyze(url)
    }

    /// The first ordinary window a process has on screen.
    private static func windowID(ownedBy process: pid_t) -> CGWindowID? {
        guard let listing = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for entry in listing {
            guard let owner = entry[kCGWindowOwnerPID as String] as? pid_t, owner == process,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID else { continue }
            return id
        }
        return nil
    }

    // MARK: - Reading it back

    private static func script(in url: URL) -> ProbeScript? {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("lab-script.json")) else { return nil }
        return try? JSONDecoder().decode(ProbeScript.self, from: data)
    }

    /// Every frame and every sample in a stretch of the recording, side by side.
    private static func frames(_ url: URL, from: Double, to: Double) async -> Int32 {
        let package = RecordingPackage(url: url)
        guard let manifest = try? package.readManifest(),
              let path = manifest.track(.screen)?.path else { return 1 }
        let region = script(in: url).map { PointerAnalysis.region(for: $0) }
            ?? CGRect(x: 120, y: 120, width: 1_300, height: 760)
        guard let frames = try? await FrameScan.observations(of: url.appendingPathComponent(path),
                                                            scale: manifest.displayScale, region: region) else { return 1 }
        var lines: [(Double, String)] = []
        var previous: Double?
        for frame in frames where frame.time >= from && frame.time <= to {
            let gap = previous.map { String(format: "%+.1f ms", (frame.time - $0) * 1_000) } ?? ""
            let tip = frame.tip.map { String(format: "(%.1f, %.1f)", $0.x, $0.y) } ?? "-"
            lines.append((frame.time, String(format: "%.4f  frame  %@  %@", frame.time, tip, gap)))
            previous = frame.time
        }
        if let cursor = manifest.telemetry.cursor,
           let text = try? String(contentsOf: url.appendingPathComponent(cursor), encoding: .utf8) {
            let decoder = JSONDecoder()
            for line in text.split(separator: "\n") {
                guard let sample = try? decoder.decode(CursorSample.self, from: Data(line.utf8)),
                      sample.t >= from, sample.t <= to else { continue }
                lines.append((sample.t, String(format: "%.4f      sample  (%.1f, %.1f)", sample.t, sample.x, sample.y)))
            }
        }
        for line in lines.sorted(by: { $0.0 < $1.0 }) { print(line.1) }
        print("\(frames.count) frames in the file; intervals: " + intervals(frames.map(\.time)))
        return 0
    }

    private static func intervals(_ times: [Double]) -> String {
        guard times.count > 1 else { return "none" }
        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }.sorted()
        return String(format: "min %.1f ms, median %.1f ms, max %.1f ms",
                      gaps[0] * 1_000, gaps[gaps.count / 2] * 1_000, gaps[gaps.count - 1] * 1_000)
    }

    private static func analyze(_ url: URL) async -> Int32 {
        guard let script = script(in: url) else {
            print("no lab-script.json in \(url.lastPathComponent): this recording was not made by the lab")
            return 1
        }
        do {
            let findings = try await PointerAnalysis.run(package: url, script: script)
            var failed = 0
            for finding in findings {
                if !finding.passed { failed += 1 }
                print("\(finding.passed ? "PASS" : "FAIL")  \(finding.name): \(finding.value)")
                if !finding.note.isEmpty { print("      \(finding.note)") }
            }
            print(failed == 0 ? "\nall \(findings.count) checks passed" : "\n\(failed) of \(findings.count) checks failed")
            return failed == 0 ? 0 : 3
        } catch {
            print("couldn't read the recording: \(error.localizedDescription)")
            return 1
        }
    }
}
