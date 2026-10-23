import Foundation
import Observation
import RecordKit
import SwiftUI

/// The level of the microphone that will be recorded, for the bar to draw.
///
/// Two sources, never both: before a take, a `MicrophoneLevelMonitor` of its own, so
/// somebody can see the microphone works before pressing Record; during one, the take's own
/// capture, so the meter shows what is being written rather than a second opinion.
///
/// It listens only when all of these hold: the bar is on screen, the microphone has been
/// turned on, and the grant has already been given. Nothing here opens a microphone that
/// was not chosen or asks for a permission, and hiding the bar stops it.
@MainActor
@Observable
final class MicrophoneMeter {
    private(set) var meter = LevelMeter()
    /// Whether there is a level to show at all.
    private(set) var isListening = false

    @ObservationIgnored private var monitor: MicrophoneLevelMonitor?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var read: () -> Float? = { nil }

    /// Where the level comes from — see `RecorderCompanions.meterSource`.
    typealias Source = RecorderCompanions.MeterSource

    private(set) var source: Source = .none

    func update(to source: Source, session: RecordingSession) {
        guard source != self.source else { return }
        self.source = source
        monitor?.stop()
        monitor = nil
        meter.reset()

        switch source {
        case .none:
            read = { nil }
            isListening = false
        case .device(let id):
            let monitor = MicrophoneLevelMonitor(deviceID: id)
            monitor?.start()
            self.monitor = monitor
            read = { [weak monitor] in monitor?.power }
            // A microphone unplugged since it was chosen has no meter rather than an empty one.
            isListening = monitor != nil
        case .take:
            read = { [weak session] in session?.microphonePower }
            isListening = true
        }
        isListening ? startTicking() : stopTicking()
    }

    private func startTicking() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTicking() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        meter.update(decibels: read(), at: ProcessInfo.processInfo.systemUptime)
    }
}

/// A slim bar with a peak mark: green while it is fine, amber near the top, red at it.
///
/// Drawn on the recorder's dark glass, which stays dark whatever the system is set to;
/// the empty track is a lighter band with an edge so the meter reads over a bright
/// wallpaper showing through the glass as well as a dark one.
///
/// Handed the meter object rather than a reading, so that thirty readings a second redraw
/// this view alone and not the bar around it.
struct MicrophoneMeterView: View {
    let source: MicrophoneMeter
    var length: CGFloat = 44
    var thickness: CGFloat = 5
    var vertical = false

    private var meter: LevelMeter { source.meter }

    var body: some View {
        GeometryReader { proxy in
            let full = vertical ? proxy.size.height : proxy.size.width
            let across = vertical ? proxy.size.width : proxy.size.height
            ZStack(alignment: vertical ? .bottom : .leading) {
                Capsule().fill(.white.opacity(0.16))
                    .overlay(Capsule().strokeBorder(.black.opacity(0.25), lineWidth: 0.5))
                Capsule().fill(color)
                    .frame(width: vertical ? across : max(across, full * meter.level),
                           height: vertical ? max(across, full * meter.level) : across)
                    .opacity(meter.level > 0.01 ? 1 : 0)
                Rectangle().fill(.white.opacity(0.9))
                    .frame(width: vertical ? across : 1.5, height: vertical ? 1.5 : across)
                    .offset(x: vertical ? 0 : min(full - 1.5, full * meter.peak),
                            y: vertical ? -min(full - 1.5, full * meter.peak) : 0)
                    .opacity(meter.peak > 0.02 ? 1 : 0)
            }
        }
        .frame(width: vertical ? thickness : length, height: vertical ? length : thickness)
        .accessibilityElement()
        .accessibilityLabel("Microphone level")
        .accessibilityValue("\(Int((meter.level * 100).rounded())) percent")
    }

    private var color: Color {
        if meter.isHot { return .red }
        if meter.level > LevelMeter.fraction(forDecibels: -12) { return .yellow }
        return .green
    }
}
