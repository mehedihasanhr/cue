import CoreMedia
import Foundation
import ScreenCaptureKit
import Testing
@testable import RecordKit

/// Whose sound a take records, and on which stream.
///
/// Nothing here opens a stream or asks for a grant: the decision is a plan made from
/// bundle identifiers, and the stream configuration is a value that can be read back.
struct SystemAudioRouteTests {
    private let own: Set<String> = ["com.stackrover.cue.studio", "com.stackrover.cue"]
    private let running = ["com.apple.Safari", "com.apple.Music", "com.stackrover.cue.studio", "com.spotify.client"]

    @Test func systemAudioOffIsOffWhateverWasChosen() {
        #expect(SystemAudioRoute.plan(systemAudio: false, chosen: [], running: running, ownBundleIDs: own) == .off)
        #expect(SystemAudioRoute.plan(systemAudio: false, chosen: ["com.apple.Safari"], running: running,
                                      ownBundleIDs: own) == .off)
    }

    /// Nothing chosen is everything, on the screen's own stream — what every take did before.
    @Test func nothingChosenIsEverythingOnTheScreensStream() {
        let route = SystemAudioRoute.plan(systemAudio: true, chosen: [], running: running, ownBundleIDs: own)
        #expect(route == .everything)
        #expect(route.usesScreenStream)
        #expect(route.recordsAudio)
    }

    @Test func chosenAppsAreHeardInTheOrderTheyWereChosenOnceEach() {
        let route = SystemAudioRoute.plan(systemAudio: true,
                                          chosen: ["com.spotify.client", "com.apple.Safari", "com.spotify.client"],
                                          running: running, ownBundleIDs: own)
        #expect(route == .applications(["com.spotify.client", "com.apple.Safari"]))
        #expect(!route.usesScreenStream)
        #expect(route.recordsAudio)
    }

    /// An app that is not running cannot be put in a filter, so it is left out; the rest
    /// are still heard.
    @Test func appsThatAreNotRunningAreLeftOut() {
        let route = SystemAudioRoute.plan(systemAudio: true,
                                          chosen: ["com.apple.Safari", "com.example.gone"],
                                          running: running, ownBundleIDs: own)
        #expect(route == .applications(["com.apple.Safari"]))
    }

    /// None of them running is no lane at all, rather than a file of silence.
    @Test func noChosenAppRunningRecordsNoSystemAudio() {
        let route = SystemAudioRoute.plan(systemAudio: true, chosen: ["com.example.gone"],
                                          running: running, ownBundleIDs: own)
        #expect(route == .nothingRunning)
        #expect(!route.recordsAudio)
        #expect(!route.usesScreenStream)
    }

    /// The recorder is never listened to, even when somebody picks it.
    @Test func theRecorderItselfIsNeverHeard() {
        let route = SystemAudioRoute.plan(systemAudio: true, chosen: ["com.stackrover.cue.studio"],
                                          running: running, ownBundleIDs: own)
        #expect(route == .nothingRunning)
    }

    // MARK: - Apps launched during a take

    /// A take hearing some apps listens for launches — even one where none of them was
    /// running yet, which is when it matters most. One hearing everything or nothing does not.
    @Test func onlyATakeOfChosenAppsListensForLaunches() {
        #expect(SystemAudioRoute.applications(["com.apple.Music"]).listensForLaunches)
        #expect(SystemAudioRoute.nothingRunning.listensForLaunches)
        #expect(!SystemAudioRoute.everything.listensForLaunches)
        #expect(!SystemAudioRoute.off.listensForLaunches)
    }

    /// Music opened a minute in, having been chosen, is heard from then on; an app nobody
    /// chose, the recorder itself, and a launch with no bundle ID change nothing.
    @Test func aChosenAppLaunchedMidTakeChangesTheFilter() {
        let chosen = ["com.apple.Safari", "com.apple.Music"]
        #expect(SystemAudioRoute.launchChangesFilter(launched: "com.apple.Music", chosen: chosen, ownBundleIDs: own))
        #expect(!SystemAudioRoute.launchChangesFilter(launched: "com.spotify.client", chosen: chosen, ownBundleIDs: own))
        #expect(!SystemAudioRoute.launchChangesFilter(launched: nil, chosen: chosen, ownBundleIDs: own))
        #expect(!SystemAudioRoute.launchChangesFilter(launched: "com.stackrover.cue.studio",
                                                      chosen: chosen + ["com.stackrover.cue.studio"],
                                                      ownBundleIDs: own))
        // The rebuilt filter is the plan against what runs now: both, in the chosen order.
        let now = SystemAudioRoute.plan(systemAudio: true, chosen: chosen,
                                        running: running, ownBundleIDs: own)
        #expect(now == .applications(["com.apple.Safari", "com.apple.Music"]))
    }

    /// Quit and opened again, a chosen app is a new process the old filter does not name,
    /// so its launch rebuilds the filter even though it was already being heard.
    @Test func aChosenAppReopenedMidTakeRebuildsTheFilter() {
        #expect(SystemAudioRoute.launchChangesFilter(launched: "com.apple.Safari",
                                                     chosen: ["com.apple.Safari"], ownBundleIDs: own))
    }

    // MARK: - Stream configurations

    /// With apps chosen the screen's stream stops asking for sound; with none it asks, as
    /// it always did.
    @Test func theScreensStreamHearsOnlyWhenNoAppsAreChosen() {
        var configuration = RecordingConfiguration(target: .display(CGMainDisplayID()),
                                                   destination: FileManager.default.temporaryDirectory)
        #expect(configuration.systemAudioApps.isEmpty)
        #expect(configuration.screenStreamCapturesAudio)
        configuration.systemAudioApps = ["com.apple.Safari"]
        #expect(!configuration.screenStreamCapturesAudio)
        configuration.systemAudio = false
        configuration.systemAudioApps = []
        #expect(!configuration.screenStreamCapturesAudio)
    }

    /// The audio-only stream: sound, not this app's, and a picture too small and too rare
    /// to cost anything.
    @Test func theAudioOnlyStreamAsksForSoundAndAlmostNoPicture() {
        let configuration = RecordingConfiguration.audioOnlyStreamConfiguration()
        #expect(configuration.capturesAudio)
        #expect(configuration.excludesCurrentProcessAudio)
        #expect(configuration.width == 2 && configuration.height == 2)
        #expect(configuration.minimumFrameInterval == CMTime(value: 1, timescale: 1))
        #expect(!configuration.showsCursor)
    }
}
