import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Asks ScreenCaptureKit itself what a frame's timestamp means.
///
/// Everything the recorder does with time rests on two assumptions about the frames it is
/// handed: that a frame's timestamp is the moment the picture was on screen, and that a
/// change on screen reaches a frame promptly. This makes a stream of its own, moves the
/// pointer at known moments, and prints what the stream actually did.
final class StreamProbe: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Arrival {
        let status: SCFrameStatus?
        let stamped: Double
        let arrived: Double
        let tip: CGPoint?
    }

    private let queue = DispatchQueue(label: "studiolab.stream-probe")
    private var arrivals: [Arrival] = []
    private var stream: SCStream?

    @MainActor
    static func run() async -> Int32 {
        let stage = Process()
        stage.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        stage.arguments = ["stage", "30"]
        try? stage.run()
        let front = NSWorkspace.shared.frontmostApplication
        defer {
            stage.terminate()
            front?.activate()
        }
        try? await Task.sleep(for: .seconds(1.2))

        let probe = StreamProbe()
        do {
            try await probe.start()
        } catch {
            print("the stream would not start: \(error.localizedDescription)")
            return 1
        }
        try? await Task.sleep(for: .seconds(1.5))

        let script = MouseScript(field: CGRect(x: 120, y: 120, width: 1_272, height: 742))
        var steps: [ScriptStep] = [ScriptStep(at: 0, kind: .move(script.a), label: "settle")]
        for index in 0..<6 {
            steps.append(ScriptStep(at: 1.0 + Double(index) * 0.7,
                                    kind: .move(index.isMultiple(of: 2) ? script.b : script.a),
                                    label: "jump"))
        }
        // Jumps again, but with the pointer kept moving in between so the stream never
        // goes quiet: the same question asked of a stream that is already awake.
        var time = 6.0
        var toggle = false
        while time < 10.0 {
            let base = toggle ? script.c : script.d
            steps.append(ScriptStep(at: time, kind: .move(base), label: "busy-jump"))
            var wiggle = 1.0 / 120
            while wiggle < 0.69 {
                steps.append(ScriptStep(at: time + wiggle,
                                        kind: .move(CGPoint(x: base.x + (Int(wiggle * 120).isMultiple(of: 2) ? 1 : 0), y: base.y)),
                                        label: "wiggle"))
                wiggle += 1.0 / 120
            }
            toggle.toggle()
            time += 0.7
        }
        let ordered = steps.sorted { $0.at < $1.at }
        let events: [ScriptEvent] = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: MouseScript.perform(ordered, pause: {}, resume: {}))
            }
        }
        try? await Task.sleep(for: .seconds(0.5))
        await probe.stop()
        stage.terminate()

        let arrivals = probe.queue.sync { probe.arrivals }
        let complete = arrivals.filter { $0.status == .complete }
        print("\(arrivals.count) buffers, \(complete.count) complete, \(arrivals.filter { $0.status == .idle }.count) idle")
        let delays = complete.map { $0.arrived - $0.stamped }.sorted()
        if !delays.isEmpty {
            print(String(format: "a frame reaches the app %.1f ms after its timestamp (median; min %.1f, max %.1f)",
                         delays[delays.count / 2] * 1_000, delays[0] * 1_000, delays[delays.count - 1] * 1_000))
        }

        for label in ["jump", "busy-jump"] {
            var waits: [Double] = []
            for event in events where event.step.label == label {
                guard case .move(let target) = event.step.kind else { continue }
                // The first frame stamped after the move that shows the pointer there.
                guard let shown = complete.first(where: { frame in
                    guard frame.stamped > event.hostTime - 0.05, let tip = frame.tip else { return false }
                    return hypot(tip.x - target.x, tip.y - target.y) < 6
                }) else { continue }
                let between = complete.filter { $0.stamped > event.hostTime && $0.stamped < shown.stamped }.count
                waits.append(shown.stamped - event.hostTime)
                print(String(format: "%@: moved, and the first frame showing it is stamped %+.1f ms later (it arrived %+.1f ms later; %d frames stamped in between still showed the old place)",
                             label, (shown.stamped - event.hostTime) * 1_000,
                             (shown.arrived - event.hostTime) * 1_000, between))
            }
            if !waits.isEmpty {
                print(String(format: "%@: mean %.1f ms", label, waits.reduce(0, +) / Double(waits.count) * 1_000))
            }
        }
        return 0
    }

    @MainActor
    private func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = Int(CGFloat(display.width) * CGFloat(filter.pointPixelScale))
        configuration.height = Int(CGFloat(display.height) * CGFloat(filter.pointPixelScale))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.showsCursor = true
        configuration.queueDepth = 8
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    @MainActor
    private func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        let arrived = hostNow()
        let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        let status = (attachments?.first?[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:))
        var tip: CGPoint?
        if status == .complete, let image = CMSampleBufferGetImageBuffer(buffer) {
            tip = FrameScan.tip(in: image, scale: 2, region: CGRect(x: 120, y: 120, width: 1_300, height: 760))
        }
        arrivals.append(Arrival(status: status,
                                stamped: CMSampleBufferGetPresentationTimeStamp(buffer).seconds,
                                arrived: arrived,
                                tip: tip))
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        print("the stream stopped: \(error.localizedDescription)")
    }
}
