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
    private let own: Set<String> = ["com.stackrover.klik.studio", "com.stackrover.klik"]
    private let running = ["com.apple.Safari", "com.apple.Music", "com.stackrover.klik.studio", "com.spotify.client"]

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
        let route = SystemAudioRoute.plan(systemAudio: true, chosen: ["com.stackrover.klik.studio"],
                                          running: running, ownBundleIDs: own)
        #expect(route == .nothingRunning)
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
