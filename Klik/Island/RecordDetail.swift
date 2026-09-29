import AddOnKit
import SwiftUI

/// Choosing what to record, in the island.
///
/// A compact surface rather than a screen-filling one, and that is the point of moving it
/// here: picking a window should not require dimming the work you are picking *from*. The
/// tiles show the windows themselves, because an application that offers five windows
/// names them all after itself and the title is rarely the thing anyone is picturing.
struct RecordDetail: View {
    let recorder: IslandRecorder
    var close: () -> Void = {}
    var openSettings: () -> Void = {}

    private enum Kind: String, CaseIterable, Identifiable {
        case display = "Display"
        case window = "Window"
        var id: String { rawValue }
    }

    @State private var kind: Kind = .display

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch kind {
            case .display: displays
            case .window: windows
            }
            footer
        }
        .padding(14)
        .frame(width: 460)
        .task { await recorder.refresh() }
        .onDisappear { recorder.cancel() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Picker("", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 160)

            if kind == .window {
                TextField("Search", text: Binding(get: { recorder.search },
                                                  set: { recorder.search = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
            }
            Spacer(minLength: 0)
        }
    }

    private var displays: some View {
        HStack(spacing: 8) {
            ForEach(recorder.displays) { target in
                tile(target, height: 64)
            }
        }
    }

    @ViewBuilder
    private var windows: some View {
        if recorder.isLoading {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity)
                .frame(height: 150)
        } else if recorder.filteredWindows.isEmpty {
            Text(recorder.search.isEmpty ? "No windows are open to record."
                                         : "Nothing matches that.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 150)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
                    ForEach(recorder.filteredWindows) { target in
                        tile(target, height: 74)
                    }
                }
                .padding(.horizontal, 1)
            }
            .frame(height: 176)
        }
    }

    private func tile(_ target: IslandRecorder.Target, height: CGFloat) -> some View {
        let isSelected = recorder.selected?.id == target.id
        return Button {
            recorder.selected = target
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let image = target.thumbnail {
                            Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle().fill(.quaternary)
                                .overlay {
                                    Image(systemName: target.request.isDisplay ? "display" : "macwindow")
                                        .foregroundStyle(.tertiary)
                                }
                        }
                    }
                    .frame(height: height)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                    if target.isElsewhere {
                        Text("Another Space")
                            .font(.system(size: 8, weight: .semibold))
                            .padding(.horizontal, 4).padding(.vertical, 2)
                            .background(.black.opacity(0.6), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(4)
                    }
                }
                Text(target.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text(target.subtitle.isEmpty ? "Untitled window" : target.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(6)
            .background(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.22)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: isSelected ? 1.5 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            // What the take will use, from the same preferences the request is built from,
            // so this line cannot disagree with the file that comes out.
            Button(action: openSettings) {
                Label(recorder.summary, systemImage: "slider.horizontal.3")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Change what is recorded in Settings › Studio")

            Spacer(minLength: 0)
            Button("Cancel", action: close)
                .controlSize(.small)
            Button {
                recorder.record()
                close()
            } label: {
                Label("Record", systemImage: "record.circle")
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(recorder.selected == nil)
            .keyboardShortcut(.return, modifiers: [])
        }
    }
}

private extension RecordingRequest.Target {
    var isDisplay: Bool { if case .display = self { return true } else { return false } }
}
