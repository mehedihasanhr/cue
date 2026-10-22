import CoreGraphics
import Foundation
import Testing
@testable import RecordKit

/// The pieces of the recorder bar and the menu bar icon that are arithmetic: the meter,
/// what the icon says, when a restart asks first, what a restart leaves behind, and what a
/// display recording leaves out.
struct RecorderBarTests {
    // MARK: - Microphone meter

    @Test func `the scale runs from the floor to full scale`() {
        #expect(LevelMeter.fraction(forDecibels: 0) == 1)
        #expect(LevelMeter.fraction(forDecibels: LevelMeter.floor) == 0)
        #expect(LevelMeter.fraction(forDecibels: -30) == 0.5)
        #expect(LevelMeter.fraction(forDecibels: -120) == 0)
        #expect(LevelMeter.fraction(forDecibels: 6) == 1, "over full scale is full")
        #expect(LevelMeter.fraction(forDecibels: -.infinity) == 0)
        #expect(LevelMeter.fraction(forDecibels: .nan) == 0)
    }

    @Test func `the meter rises at once`() {
        var meter = LevelMeter()
        meter.update(decibels: -60, at: 0)
        meter.update(decibels: -6, at: 0.05)
        #expect(meter.level == LevelMeter.fraction(forDecibels: -6))
    }

    @Test func `the meter falls smoothly rather than dropping`() {
        var meter = LevelMeter()
        meter.update(decibels: 0, at: 0)
        meter.update(decibels: -60, at: 0.1)
        #expect(abs(meter.level - (1 - LevelMeter.fallRate * 0.1)) < 1e-9, "one tenth of a second's fall")
        meter.update(decibels: -60, at: 2)
        #expect(meter.level == 0, "and reaches the bottom in the end")
    }

    @Test func `the peak holds, then falls, and never sits below the bar`() {
        var meter = LevelMeter()
        meter.update(decibels: -12, at: 0)
        let peak = meter.peak
        meter.update(decibels: -60, at: 0.5)
        meter.update(decibels: -60, at: LevelMeter.peakHold - 0.01)
        #expect(meter.peak == peak, "held")
        meter.update(decibels: -60, at: LevelMeter.peakHold + 0.25)
        #expect(meter.peak < peak, "falling")
        #expect(abs(meter.peak - (peak - LevelMeter.peakFallRate * 0.25)) < 1e-9)
        meter.update(decibels: -60, at: 10)
        #expect(meter.peak == meter.level)
    }

    @Test func `a louder word moves the peak up and restarts its hold`() {
        var meter = LevelMeter()
        meter.update(decibels: -30, at: 0)
        meter.update(decibels: -10, at: 1)
        #expect(meter.peak == LevelMeter.fraction(forDecibels: -10))
        meter.update(decibels: -60, at: 1 + LevelMeter.peakHold - 0.1)
        #expect(meter.peak == LevelMeter.fraction(forDecibels: -10))
    }

    @Test func `nothing arriving reads as silence, and near full scale reads as hot`() {
        var meter = LevelMeter()
        meter.update(decibels: nil, at: 0)
        #expect(meter.level == 0)
        meter.update(decibels: -1, at: 0.1)
        #expect(meter.isHot)
        meter.reset()
        #expect(meter == LevelMeter())
    }

    // MARK: - When the meter and the preview may open a device

    private typealias Companions = RecorderCompanions

    @Test func `the meter listens to nothing until a microphone is chosen`() {
        #expect(Companions.meterSource(deviceID: nil, isBarVisible: true, state: .idle) == .none)
        #expect(Companions.meterSource(deviceID: "mic", isBarVisible: true, state: .idle) == .device("mic"))
    }

    @Test func `hiding the bar stops the meter, whatever the state`() {
        for state: RecordingSession.State in [.idle, .countdown(remaining: 2), .recording(startedAt: started)] {
            #expect(Companions.meterSource(deviceID: "mic", isBarVisible: false, state: state) == .none)
        }
    }

    @Test func `during a take the meter reads the take, not a second capture`() {
        #expect(Companions.meterSource(deviceID: "mic", isBarVisible: true, state: .recording(startedAt: started)) == .take)
        #expect(Companions.meterSource(deviceID: "mic", isBarVisible: true,
                                       state: .paused(startedAt: started, at: started)) == .take)
        #expect(Companions.meterSource(deviceID: "mic", isBarVisible: true, state: .countdown(remaining: 1)) == .device("mic"),
                "the countdown is still a chance to check it")
        #expect(Companions.meterSource(deviceID: "mic", isBarVisible: true, state: .finishing) == .none,
                "and it does not reopen a microphone being let go of")
    }

    @Test func `the camera preview is up before a take and down during one`() {
        func shows(_ state: RecordingSession.State, keeps: Bool = false, visible: Bool = true,
                   camera: Bool = true, enabled: Bool = true) -> Bool {
            Companions.showsCameraPreview(isEnabled: enabled, keepsWhileRecording: keeps,
                                          hasCamera: camera, isBarVisible: visible, state: state)
        }
        #expect(shows(.idle))
        #expect(!shows(.countdown(remaining: 3)))
        #expect(!shows(.recording(startedAt: started)))
        #expect(shows(.recording(startedAt: started), keeps: true), "unless it is asked to stay")
        #expect(!shows(.finishing, keeps: true))
        #expect(!shows(.idle, visible: false), "never without the bar")
        #expect(!shows(.idle, camera: false), "never without a chosen, allowed camera")
        #expect(!shows(.idle, enabled: false))
    }

    // MARK: - Menu bar icon

    private let started = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func `the icon says what the session is doing`() {
        #expect(RecorderStatus(.idle, at: started).phase == .idle)
        #expect(RecorderStatus(.idle, at: started).title.isEmpty)
        #expect(RecorderStatus(.countdown(remaining: 3), at: started).title == "3")
        let recording = RecorderStatus(.recording(startedAt: started), at: started.addingTimeInterval(42.2))
        #expect(recording.phase == .recording)
        #expect(recording.title == "0:42")
        #expect(recording.symbol == "record.circle.fill")
        let paused = RecorderStatus(.paused(startedAt: started, at: started.addingTimeInterval(65)),
                                    at: started.addingTimeInterval(500))
        #expect(paused.phase == .paused)
        #expect(paused.title == "1:05", "a paused clock stands still")
        #expect(RecorderStatus(.finishing, at: started).phase == .finishing)
        #expect(RecorderStatus(.failed(.targetDisappeared), at: started).phase == .idle)
    }

    @Test func `an hour-long take shows hours`() {
        #expect(RecorderStatus.clock(3_725) == "1:02:05")
        #expect(RecorderStatus.clock(59.6) == "1:00")
    }

    // MARK: - Restart

    @Test func `a short take restarts without asking, a longer one asks`() {
        #expect(!TakeRestart.needsConfirmation(recordedSeconds: 4))
        #expect(!TakeRestart.needsConfirmation(recordedSeconds: 10))
        #expect(TakeRestart.needsConfirmation(recordedSeconds: 10.5))
    }

    @Test func `the restart question follows the threshold the user chose`() {
        #expect(!TakeRestart.needsConfirmation(recordedSeconds: 25, threshold: 30))
        #expect(TakeRestart.needsConfirmation(recordedSeconds: 31, threshold: 30))
        #expect(TakeRestart.needsConfirmation(recordedSeconds: 0.5, threshold: 0), "zero asks about anything recorded")
        #expect(!TakeRestart.needsConfirmation(recordedSeconds: 0, threshold: 0), "nothing recorded is nothing to lose")
        #expect(!TakeRestart.needsConfirmation(recordedSeconds: 3_600, threshold: nil), "nil never asks")
        #expect(TakeRestart.needsConfirmation(recordedSeconds: 1, threshold: -5), "a negative threshold reads as zero")
    }

    @Test func `the recorded length leaves pauses out`() {
        let paused = RecordingSession.State.paused(startedAt: started, at: started.addingTimeInterval(12))
        #expect(paused.recordedSeconds(at: started.addingTimeInterval(400)) == 12)
        #expect(RecordingSession.State.recording(startedAt: started).recordedSeconds(at: started.addingTimeInterval(8)) == 8)
        #expect(RecordingSession.State.countdown(remaining: 2).recordedSeconds(at: started) == 0)
    }

    @Test func `a restart leaves nothing of the old take behind`() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("restart-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let package = try RecordingPackage.create(named: "Take", in: folder)
        try package.writeMarker(TakeMarker(manifest: RecordingManifest(name: "Take")))
        try Data([1, 2, 3]).write(to: package.mediaFolder.appendingPathComponent("screen.mov"))
        #expect(package.hasMarker)

        #expect(TakeRestart.removeLeftovers(of: package.url))
        #expect(!FileManager.default.fileExists(atPath: package.url.path(percentEncoded: false)))
        // Nothing in the library would offer it as an interrupted take.
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
        #expect(left.isEmpty)
    }

    @Test func `a restart with nothing left behind is already clean`() {
        #expect(TakeRestart.removeLeftovers(of: nil))
        let gone = FileManager.default.temporaryDirectory.appendingPathComponent("gone-\(UUID().uuidString).cuerec")
        #expect(TakeRestart.removeLeftovers(of: gone))
    }

    @Test func `a restart refuses to delete anything that is not a recording`() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-take-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(!TakeRestart.removeLeftovers(of: folder))
        #expect(FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
    }

    // MARK: - What a display recording leaves out

    private let own: Set<String> = ["com.stackrover.cue.studio", "com.stackrover.cue"]
    private let finder = CaptureExclusion.finderBundleID
    private let desktopLayer = Int(CGWindowLevelForKey(.desktopIconWindow))

    private var windows: [CaptureExclusion.Window] {
        [.init(id: 1, bundleID: finder, layer: desktopLayer),                // the icons
         .init(id: 2, bundleID: finder, layer: Int(CGWindowLevelForKey(.desktopWindow))),
         .init(id: 3, bundleID: finder, layer: 0),                            // a Finder window
         .init(id: 4, bundleID: finder, layer: Int(CGWindowLevelForKey(.popUpMenuWindow))),
         .init(id: 5, bundleID: "com.apple.dock", layer: Int(CGWindowLevelForKey(.desktopWindow))), // wallpaper
         .init(id: 6, bundleID: "com.stackrover.cue.studio", layer: 0),     // the bar
         .init(id: 7, bundleID: "com.apple.Safari", layer: 0)]
    }

    private var running: [String] {
        [finder, "com.apple.dock", "com.stackrover.cue.studio", "com.stackrover.cue", "com.apple.Safari"]
    }

    @Test func `by default only Cue Studio and Cue are left out`() {
        let plan = CaptureExclusion.plan(running: running, windows: windows, ownBundleIDs: own, hidesDesktopIcons: false)
        #expect(plan.excludedApplications == own)
        #expect(plan.exceptedWindows.isEmpty)
    }

    @Test func `hiding the icons leaves the Finder's desktop out and its windows in`() {
        let plan = CaptureExclusion.plan(running: running, windows: windows, ownBundleIDs: own, hidesDesktopIcons: true)
        #expect(plan.excludedApplications == own.union([finder]))
        #expect(plan.exceptedWindows == [3, 4], "the Finder window and its menu, not the desktop")
        #expect(!plan.exceptedWindows.contains(6), "the bar is never named back in")
        #expect(!plan.excludedApplications.contains("com.apple.dock"), "the wallpaper stays")
    }

    @Test func `the desktop is told apart by layer`() {
        #expect(CaptureExclusion.isDesktop(.init(id: 1, bundleID: finder, layer: desktopLayer)))
        #expect(!CaptureExclusion.isDesktop(.init(id: 3, bundleID: finder, layer: 0)))
        #expect(!CaptureExclusion.isDesktop(.init(id: 5, bundleID: "com.apple.dock", layer: desktopLayer)))
    }

    @Test func `with no Finder running there is nothing to hide`() {
        let plan = CaptureExclusion.plan(running: running.filter { $0 != finder },
                                         windows: windows, ownBundleIDs: own, hidesDesktopIcons: true)
        #expect(plan.excludedApplications == own)
        #expect(plan.exceptedWindows.isEmpty)
    }

    /// The bar, the menu bar icon, the speaker notes and the camera preview are all this
    /// app's windows, and they stay out of a display recording because the app does.
    @Test func `this app is always left out of a display recording`() {
        #expect(ShareableContentStore().excludedBundleIDs.contains("com.stackrover.cue.studio"))
        let plan = CaptureExclusion.plan(running: running, windows: windows,
                                         ownBundleIDs: ShareableContentStore().excludedBundleIDs,
                                         hidesDesktopIcons: true)
        #expect(plan.excludedApplications.contains("com.stackrover.cue.studio"))
    }
}
