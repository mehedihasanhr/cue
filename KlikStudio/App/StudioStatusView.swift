import AddOnKit
import SwiftUI

/// What Klik last asked for, and what this build told it it could do.
///
/// Small and out of the way — it lives behind a disclosure in About — but it is the
/// first thing to look at when Klik says the add-on is installed and nothing happens:
/// either the request never arrived, or a capability it needed is off.
struct BridgeStatusView: View {
    @Environment(StudioService.self) private var service
    @State private var capabilities: StudioCapabilities?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Last request", value: service.lastRequest.map(Self.describe) ?? "Nothing yet")
            row("Outcome", value: Self.describe(service.lastResult))
            if let note = service.destinationNote {
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            if let capabilities {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 4) {
                    ForEach(Self.rows(for: capabilities), id: \.name) { item in
                        Label(item.name, systemImage: item.available ? "checkmark.circle.fill" : "circle.dashed")
                            .font(.caption)
                            .foregroundStyle(item.available ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                            .symbolRenderingMode(.hierarchical)
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task { capabilities = await service.capabilities() }
    }

    private func row(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.caption).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private static func describe(_ request: RecordingRequest) -> String {
        let target = switch request.target {
        case .display(let id): "display \(id)"
        case .window(let id): "window \(id)"
        case .area(let display, let rect): "area \(Int(rect.width))×\(Int(rect.height)) on display \(display)"
        case .ask: "ask me"
        }
        var parts = [target]
        if request.systemAudio { parts.append("system audio") }
        if request.microphone { parts.append("microphone") }
        if request.opensEditorWhenFinished { parts.append("open editor") }
        return parts.joined(separator: " · ")
    }

    private static func describe(_ result: RecordingResult?) -> String {
        guard let result else { return "—" }
        return [result.outcome.rawValue, result.message].compactMap { $0 }.joined(separator: " · ")
    }

    private static func rows(for capabilities: StudioCapabilities) -> [(name: String, available: Bool)] {
        [("Display", capabilities.canRecordDisplay),
         ("Window", capabilities.canRecordWindow),
         ("Area", capabilities.canRecordArea),
         ("System audio", capabilities.canRecordSystemAudio),
         ("Microphone", capabilities.canRecordMicrophone),
         ("Webcam", capabilities.canRecordWebcam),
         ("Editing", capabilities.canEdit),
         ("GIF export", capabilities.canExportGIF),
         ("Captions", capabilities.canCaption)]
    }
}
