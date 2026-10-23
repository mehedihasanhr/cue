import RenderKit
import SwiftUI
import TimelineKit

/// "Clean up voice" and "Even out volume" for one source, or for the whole recording's
/// sound when `id` is `nil` (a recording with its sound inside the video).
struct VoiceSwitches: View {
    let model: EditorModel
    let id: UUID?
    /// Why the switches cannot be used right now, written under them; `nil` when they can.
    var unavailable: String?

    var body: some View {
        let style = model.voiceStyle(id)
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            InspectorSwitch("Clean up voice", isOn: Binding(
                get: { model.voiceStyle(id).cleansVoice },
                set: { model.setCleansVoice($0, for: id) }
            ))
            .help(unavailable ?? "Takes out rumble and the hiss between words, and softens the loudest syllables")
            InspectorSwitch("Even out volume", isOn: Binding(
                get: { model.voiceStyle(id).evensVolume },
                set: { model.setEvensVolume($0, for: id) }
            ))
            .help(unavailable ?? "Brings this sound to the loudness most videos and podcasts use, without clipping")
            // The measurement is the one line kept: it is what the switch did, in numbers.
            // Why the switches are off, when they are, is in their tooltips — the dimmed
            // switch beside a muted source already says most of it.
            if unavailable == nil, style.evensVolume, let file = model.measuredFile(for: id) {
                LevelReadout(url: file.url, track: file.track, cleansVoice: style.cleansVoice)
            }
        }
        .disabled(unavailable != nil)
    }
}

/// What "Even out volume" measured and what it does about it.
///
/// Asked of the same analyser the mixdown uses, so the numbers shown are the numbers
/// applied — and the measuring is done once, whichever of the two asks first.
struct LevelReadout: View {
    let url: URL
    let track: Int
    let cleansVoice: Bool

    private enum Reading: Equatable {
        case measuring
        case silent
        case measured(LevelReading)
    }

    @State private var reading = Reading.measuring

    var body: some View {
        Text(text)
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .task(id: "\(url.path)#\(track)#\(cleansVoice)") {
                reading = .measuring
                let level = await SoundAnalyzer.shared.level(of: url, track: track, cleansVoice: cleansVoice)
                reading = level.map(Reading.measured) ?? .silent
            }
    }

    private var text: String {
        switch reading {
        case .measuring:
            return "Measuring…"
        case .silent:
            return "Too quiet to measure, so it is left as it is."
        case .measured(let level):
            let measured = "Measured \(Self.number(level.measured)) LUFS."
            let reached = level.measured + level.gain
            let change = abs(level.gain) < 0.05 ? "Already at \(Self.number(Levelling.target))."
                : "\(level.gain > 0 ? "Raised" : "Lowered") \(Self.number(abs(level.gain))) dB"
                    + (abs(reached - Levelling.target) < 0.05
                       ? " to \(Self.number(Levelling.target))."
                       : ", as far as it goes.")
            return "\(measured) \(change)"
        }
    }

    /// One decimal, with a real minus sign.
    private static func number(_ value: Double) -> String {
        String(format: "%.1f", value).replacingOccurrences(of: "-", with: "−")
    }
}

/// "Lower under speech" for one added sound.
struct DuckControls: View {
    let model: EditorModel
    let id: UUID
    /// The switch alone, for the list of every added sound; the amount and the
    /// explanation are in the sound's own panel.
    var compact = false

    var body: some View {
        let region = model.timeline.audio.first { $0.id == id }
        let source = model.duckingSource
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            InspectorSwitch("Lower under speech", isOn: Binding(
                get: { region?.ducksUnderSpeech ?? false },
                set: { model.setDucksUnderSpeech($0, for: id) }
            ))
            .help("Turns this sound down wherever somebody is speaking, and back up after. \(source.explanation)")
            .disabled(!source.available && region?.ducksUnderSpeech != true)
            if !compact, region?.ducksUnderSpeech == true {
                InspectorSlider(model: model, "Lower by", systemImage: "arrow.down.to.line",
                                value: Binding(
                                    get: { model.timeline.audio.first { $0.id == id }?.duckAmount
                                           ?? AudioRegion.defaultDuckAmount },
                                    set: { model.setDuckAmount($0.rounded(), for: id) }
                                ),
                                range: 3...30,
                                format: { "\(Int($0.rounded())) dB" })
            }
            // Only when there is nothing to listen for: then the switch cannot do its job,
            // and that changes what you would do next. Otherwise the explanation is the
            // switch's tooltip.
            if !source.available {
                InspectorNote(source.explanation)
            }
        }
    }
}
