import AddOnKit
import AppKit
import RecordKit
import SwiftUI

/// The library: what has been recorded, and a way back to the bar.
///
/// The recorder itself is the floating bar, so this window's first job is to find a take
/// and open it — a row opens the editor, and that is the reason the window exists. What
/// has been added around that is everything needed to *find* the take: a picture, a
/// length, a size, a search field, a sort, and the handful of operations that used to
/// mean leaving for the Finder. It is also where the permission problem is explained,
/// because that is the one message too long to put on a bar.
struct LibraryWindow: View {
    @Environment(StudioService.self) private var studio
    @Environment(StudioSettings.self) private var settings
    let model: RecorderModel?

    /// Built here rather than handed in, because it is this window's own state: it exists
    /// while the window does, and the bar has no use for it.
    @State private var catalog: LibraryCatalog?

    var body: some View {
        VStack(spacing: 0) {
            if model?.permissionDenied == true, let model {
                PermissionBanner(model: model)
            }

            if let catalog {
                if !catalog.entries.isEmpty {
                    LibraryToolbar(catalog: catalog)
                    list(catalog)
                } else if catalog.isLoading {
                    // Deliberately nothing: a spinner that flashes for the 20 ms a local
                    // folder takes to read is worse than a frame of empty window.
                    Spacer()
                } else {
                    empty
                }
            } else {
                Spacer()
            }

            footer
        }
        .frame(minWidth: 440, minHeight: 420)
        .background(.background)
        .navigationTitle("Recordings")
        .task {
            let catalog = catalog ?? LibraryCatalog(folder: settings.library)
            self.catalog = catalog
            await model?.refreshSources()
            await catalog.reload()
        }
        // The folder can be changed in Settings while this window is open.
        .task(id: settings.library) { await catalog?.look(at: settings.library) }
        .onChange(of: studio.session.state) { _, state in
            // A take that has just finished belongs at the top of this list without
            // anybody asking for it.
            if case .finished = state { Task { await catalog?.reload() } }
        }
        .modifier(LibraryDialogs(catalog: catalog))
    }

    /// One scrolling list, and only one: the overlapping mess this window used to be came
    /// from stacking fixed-height lists inside a scroll view, where anything taller than
    /// its frame simply drew over its neighbours.
    private func list(_ catalog: LibraryCatalog) -> some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(catalog.visible) { entry in
                    RecordingRow(entry: entry, catalog: catalog)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .studioScrollEdges()
        .overlay {
            // A search that matches nothing must say so. An empty list under a search
            // field somebody has typed into reads as a library that lost everything.
            if catalog.visible.isEmpty, !catalog.search.isEmpty {
                ContentUnavailableView.search(text: catalog.search)
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "film.stack")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No recordings yet").font(.title3.weight(.medium))
            Text("Press Record on the bar. What you record lands here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 30)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(settings.library.lastPathComponent)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Show in Finder") { NSWorkspace.shared.open(settings.library) }
                .studioButton()
            Button("Recorder Bar") { StudioAppDelegate.showBar() }
                .studioButton()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Finding one take among thirty: what to look for, and in what order.
private struct LibraryToolbar: View {
    @Bindable var catalog: LibraryCatalog

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                TextField("Search", text: $catalog.search)
                    .textFieldStyle(.plain)
                if !catalog.search.isEmpty {
                    Button { catalog.search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear the search")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            // A menu rather than a segmented control: three keys and a direction is four
            // things, and the direction only makes sense next to the key it reverses.
            Menu {
                Picker("Sort by", selection: $catalog.order) {
                    ForEach(RecordingOrder.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Picker("Direction", selection: $catalog.descending) {
                    Text(catalog.order == .name ? "A to Z" : "Newest first").tag(false)
                    Text(catalog.order == .name ? "Z to A" : "Oldest first").tag(true)
                }
                .pickerStyle(.inline)
            } label: {
                Label(catalog.order.title, systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.button)
            .studioButton()
            .fixedSize()
            .help("How the list is sorted")
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

/// One take.
private struct RecordingRow: View {
    let entry: RecordingEntry
    let catalog: LibraryCatalog
    @State private var isHovering = false
    /// The poster frame, once it has been read. `Data` crossing back from the decoder and
    /// an `NSImage` made here, because `NSImage` is not something to send between actors.
    @State private var poster: Data?

    var body: some View {
        Button { catalog.open(entry) } label: {
            HStack(spacing: 12) {
                thumbnail
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.callout.weight(.medium)).lineLimit(1)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if entry.kinds.contains(.microphone) || entry.kinds.contains(.systemAudio) {
                    Image(systemName: "waveform")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help(entry.kinds.contains(.microphone) ? "Has a microphone track" : "Has system audio")
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isHovering ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .task(id: entry.url) { poster = await RecordingPoster.jpeg(for: entry.url) }
        .contextMenu {
            Button("Open") { catalog.open(entry) }
            Divider()
            Button("Rename\u{2026}") { catalog.beginRenaming(entry) }
            Button("Duplicate") { Task { await catalog.duplicate(entry) } }
            Button("Show in Finder") { catalog.reveal(entry) }
            Divider()
            // Named for where it goes, not for what it destroys: this is a move to the
            // Trash, and a menu item that says Delete promises something worse.
            Button("Move to Trash") { catalog.askToDelete(entry) }
        }
    }

    /// "24 Sep 2026 at 11.06 · 4:07 · 82.1 MB" — the three facts that tell two takes apart.
    private var detail: String {
        [entry.createdAt.formatted(date: .abbreviated, time: .shortened),
         LibraryCatalog.length(entry.duration),
         LibraryCatalog.size(entry.byteCount)]
            .filter { !$0.isEmpty }
            .joined(separator: " \u{00B7} ")
    }

    private var thumbnail: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(.quaternary)
            .frame(width: 58, height: 36)
            .overlay {
                if let poster, let image = NSImage(data: poster) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    // What a take with no readable video looks like, and what every take
                    // looks like for the moment before its frame arrives.
                    Image(systemName: "film").font(.callout).foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Everything this window has to ask before it changes something.
///
/// Gathered into one modifier rather than hung off the list: an alert attached to a row
/// goes away with the row, and a row goes away the moment the list is reloaded — which is
/// exactly what a rename does.
private struct LibraryDialogs: ViewModifier {
    let catalog: LibraryCatalog?

    func body(content: Content) -> some View {
        guard let catalog else { return AnyView(content) }
        return AnyView(content
            .alert("Rename Recording", isPresented: renaming(catalog)) {
                // A field in an alert rather than an editable row: the name is validated
                // and can be refused, and a row that silently reverts does not say why.
                TextField("Name", text: Binding { catalog.draftName } set: { catalog.draftName = $0 })
                Button("Rename") { Task { await catalog.commitRename() } }
                Button("Cancel", role: .cancel) { catalog.renaming = nil }
            } message: {
                Text("This renames the recording on disk.")
            }
            .alert("Move \u{201C}\(catalog.deleting?.name ?? "")\u{201D} to the Trash?",
                   isPresented: deleting(catalog)) {
                Button("Move to Trash", role: .destructive) { Task { await catalog.confirmDelete() } }
                Button("Cancel", role: .cancel) { catalog.deleting = nil }
            } message: {
                // Said plainly, because it is the truth and it is the reassurance: this is
                // recoverable, and the user is the one who recovers it.
                Text("It goes to the Trash, so you can put it back until the Trash is emptied.")
            }
            .alert("Can\u{2019}t do that", isPresented: hasProblem(catalog)) {
                Button("OK", role: .cancel) { catalog.problem = nil }
            } message: {
                Text(catalog.problem ?? "")
            })
    }

    /// `isPresented` bindings derived from the thing being acted on, so there is one piece
    /// of state per question rather than a flag beside it that can disagree with it.
    private func renaming(_ catalog: LibraryCatalog) -> Binding<Bool> {
        Binding { catalog.renaming != nil } set: { if !$0 { catalog.renaming = nil } }
    }

    private func deleting(_ catalog: LibraryCatalog) -> Binding<Bool> {
        Binding { catalog.deleting != nil } set: { if !$0 { catalog.deleting = nil } }
    }

    private func hasProblem(_ catalog: LibraryCatalog) -> Binding<Bool> {
        Binding { catalog.problem != nil } set: { if !$0 { catalog.problem = nil } }
    }
}

/// The one message too long for the bar.
private struct PermissionBanner: View {
    let model: RecorderModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Klik Studio can't see the screen yet").font(.callout.weight(.semibold))
                Text("Turn it on in Privacy & Security, then reopen Klik Studio — macOS applies the change on the next launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Open Settings") { model.openScreenRecordingSettings() }
                .studioButton()
        }
        .padding(14)
        .background(.orange.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}
