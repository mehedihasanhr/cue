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
    /// Cards or rows. Remembered, because it is a way of working rather than a passing view.
    @AppStorage("libraryLayout") private var layout: LibraryLayout = .grid

    var body: some View {
        VStack(spacing: 0) {
            if model?.permissionDenied == true, let model {
                PermissionBanner(model: model)
            }

            header

            if let catalog {
                if !catalog.entries.isEmpty || !catalog.interrupted.isEmpty {
                    LibraryToolbar(catalog: catalog, layout: $layout)
                    content(catalog)
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
        }
        .frame(minWidth: 520, minHeight: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Recordings")
        .task {
            if let asked = StudioAutomation.libraryLayout.flatMap(LibraryLayout.init(rawValue:)) { layout = asked }
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
            // A take that could not be closed is kept for recovery, and belongs here too.
            if case .failed = state { Task { await catalog?.reload() } }
        }
        .onChange(of: TakeRecoveryCenter.shared.finished) { Task { await catalog?.reload() } }
        .modifier(LibraryDialogs(catalog: catalog))
    }

    /// The window's name, how much is in it and where, and the way to make another.
    ///
    /// The count and the folder used to sit in a footer under the list, where nobody
    /// reads; under the title is where a window says what it holds. "Recorder Bar" became
    /// New Recording, because that is what anybody pressing it wants.
    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recordings")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(StudioTheme.Palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(StudioTheme.Palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            StudioButton("New Recording", systemImage: "record.circle", variant: .primary) {
                StudioAppDelegate.showBar()
            }
            .help("Bring up the recorder bar")
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func content(_ catalog: LibraryCatalog) -> some View {
        let interrupted = catalog.interrupted.filter {
            catalog.search.isEmpty || $0.name.localizedCaseInsensitiveContains(catalog.search)
        }
        let sections = RecordingSection.group(catalog.visible, by: catalog.order)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // Above everything else, whatever the sort: these need something doing.
                if !interrupted.isEmpty {
                    LibrarySectionView(title: "Needs attention") {
                        VStack(spacing: 6) {
                            ForEach(interrupted) { take in
                                InterruptedTakeRow(take: take)
                                    .background(StudioTheme.Palette.fill,
                                                in: StudioTheme.squircle(12))
                            }
                        }
                    }
                }
                ForEach(sections) { section in
                    LibrarySectionView(title: section.title) {
                        switch layout {
                        case .grid:
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 196, maximum: 300), spacing: 16)],
                                      alignment: .leading, spacing: 18) {
                                ForEach(section.entries) { entry in
                                    RecordingCard(entry: entry, catalog: catalog)
                                }
                            }
                        case .list:
                            LazyVStack(spacing: 2) {
                                ForEach(section.entries) { entry in
                                    RecordingRow(entry: entry, catalog: catalog)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 20)
        }
        .studioScrollEdges()
        .overlay {
            // A search that matches nothing must say so. An empty list under a search
            // field somebody has typed into reads as a library that lost everything.
            if catalog.visible.isEmpty, interrupted.isEmpty, !catalog.search.isEmpty {
                ContentUnavailableView.search(text: catalog.search)
            }
        }
        .animation(.snappy(duration: 0.25), value: layout)
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Spacer()
            ZStack {
                Circle()
                    .fill(StudioTheme.Palette.accentSoft)
                    .frame(width: 88, height: 88)
                Image(systemName: "film.stack")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(StudioTheme.Palette.accent)
            }
            .accessibilityHidden(true)
            Text("No recordings yet")
                .font(.system(size: 17, weight: .semibold))
            Text("Record your screen, a window or an area. What you record lands here, ready to edit.")
                .font(.system(size: 13))
                .foregroundStyle(StudioTheme.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            StudioButton("New Recording", systemImage: "record.circle", variant: .primary) {
                StudioAppDelegate.showBar()
            }
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 30)
    }

    /// How many there are and where they are kept, with the folder a click away.
    private var summary: String {
        let folder = settings.library.lastPathComponent
        switch catalog?.entries.count ?? 0 {
        case 0: return "Kept in \(folder)"
        case 1: return "1 recording \u{00B7} \(folder)"
        case let count: return "\(count) recordings \u{00B7} \(folder)"
        }
    }
}

/// Cards or rows.
enum LibraryLayout: String, CaseIterable {
    case grid, list

    var title: String { self == .grid ? "Grid" : "List" }
    var symbol: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
}

/// A heading and what is under it.
private struct LibrarySectionView<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StudioTheme.Palette.textSecondary)
                    .accessibilityAddTraits(.isHeader)
            }
            content
        }
    }
}

/// Finding one take among thirty: what to look for, in what order, and how to see them.
private struct LibraryToolbar: View {
    @Bindable var catalog: LibraryCatalog
    @Binding var layout: LibraryLayout
    @Environment(StudioSettings.self) private var settings
    @FocusState private var isSearching: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(StudioTheme.Palette.textSecondary)
                    .accessibilityHidden(true)
                TextField("Search recordings", text: $catalog.search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($isSearching)
                    .accessibilityLabel("Search recordings")
                if !catalog.search.isEmpty {
                    Button { catalog.search = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(StudioTheme.Palette.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear the search")
                    .accessibilityLabel("Clear the search")
                }
            }
            .studioField(isFocused: isSearching, size: .regular)
            .frame(maxWidth: .infinity)

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
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 11.5, weight: .medium))
                    Text(catalog.order.title)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(StudioTheme.Palette.textSecondary)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.studio(.secondary, size: .regular))
            .menuIndicator(.hidden)
            .fixedSize()
            .help("How the list is sorted")
            .accessibilityLabel("Sort by \(catalog.order.title)")

            StudioSegmented(selection: $layout,
                            items: LibraryLayout.allCases,
                            title: \.title,
                            systemImage: \.symbol,
                            showsTitles: false)
                .fixedSize()
                .accessibilityLabel("Layout")

            StudioIconButton(systemImage: "folder", help: "Show the recordings folder in Finder",
                             variant: .secondary) {
                NSWorkspace.shared.open(settings.library)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }
}

/// What every way of showing a take can do with it, in one place: the context menu, the
/// "⋯" button and VoiceOver's actions are the same list.
private struct RecordingActions {
    let entry: RecordingEntry
    let catalog: LibraryCatalog

    var menuActions: [[StudioActionMenu<AnyView>.Action]] {
        [[.init("Open", systemImage: "play.rectangle") { catalog.open(entry) }],
         [.init("Rename\u{2026}", systemImage: "pencil") { catalog.beginRenaming(entry) },
          .init("Duplicate", systemImage: "plus.square.on.square") { Task { await catalog.duplicate(entry) } },
          .init("Show in Finder", systemImage: "folder") { catalog.reveal(entry) }],
         // Named for where it goes, not for what it destroys: this is a move to the
         // Trash, and a menu item that says Delete promises something worse.
         [.init("Move to Trash", systemImage: "trash") { catalog.askToDelete(entry) }]]
    }

    /// "Sep 30, 2026 at 7:15 PM · 0:34 · 45 MB" — the three facts that tell two takes apart.
    var detail: String {
        [entry.createdAt.formatted(date: .abbreviated, time: .shortened),
         LibraryCatalog.length(entry.duration),
         LibraryCatalog.size(entry.byteCount)]
            .filter { !$0.isEmpty }
            .joined(separator: " \u{00B7} ")
    }

    /// The card's facts without the length, which the card shows on the picture.
    var shortDetail: String {
        [entry.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()),
         LibraryCatalog.size(entry.byteCount)]
            .filter { !$0.isEmpty }
            .joined(separator: " \u{00B7} ")
    }

    var hasSound: Bool { entry.kinds.contains(.microphone) || entry.kinds.contains(.systemAudio) }
}

private extension View {
    /// The same actions for VoiceOver and the right mouse button.
    func recordingActions(_ actions: RecordingActions) -> some View {
        self
            .contextMenu {
                ForEach(Array(actions.menuActions.enumerated()), id: \.offset) { index, group in
                    if index > 0 { Divider() }
                    ForEach(group, id: \.title) { action in
                        Button(action.title, action: action.perform)
                    }
                }
            }
            .accessibilityActions {
                ForEach(actions.menuActions.flatMap { $0 }.dropFirst(), id: \.title) { action in
                    Button(action.title, action: action.perform)
                }
            }
    }
}

/// One take, as a card: the picture first, because the picture is how a take is found.
private struct RecordingCard: View {
    let entry: RecordingEntry
    let catalog: LibraryCatalog
    @State private var isHovering = false
    @State private var poster: Data?
    @Environment(\.colorScheme) private var colorScheme

    private var actions: RecordingActions { RecordingActions(entry: entry, catalog: catalog) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { catalog.open(entry) } label: {
                VStack(alignment: .leading, spacing: 8) {
                    picture
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(StudioTheme.Palette.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(actions.shortDetail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(StudioTheme.Palette.textSecondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(StudioPressStyle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(entry.name)
            .accessibilityValue(actions.detail)
            .accessibilityHint("Opens in the editor")
            .accessibilityAddTraits(.isButton)
        }
        .overlay(alignment: .topTrailing) { more }
        .onHover { hovering in
            withAnimation(StudioMotion.hover) { isHovering = hovering }
        }
        .task(id: entry.url) { poster = await RecordingPoster.jpeg(for: entry.url) }
        .recordingActions(actions)
    }

    private var picture: some View {
        let shape = StudioTheme.squircle(10)
        return Color.clear
            .aspectRatio(16 / 10, contentMode: .fit)
            .background {
                ZStack {
                    StudioTheme.Palette.fill
                    if let poster, let image = NSImage(data: poster) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .scaleEffect(isHovering && !StudioMotion.reduceMotion ? 1.03 : 1)
                    } else {
                        // What a take with no readable video looks like, and what every
                        // take looks like for the moment before its frame arrives.
                        Image(systemName: "film")
                            .font(.system(size: 22))
                            .foregroundStyle(StudioTheme.Palette.textTertiary)
                    }
                }
            }
            .clipShape(shape)
            .overlay(alignment: .bottomTrailing) { badges.padding(7) }
            .overlay {
                shape.strokeBorder(isHovering ? StudioTheme.Palette.accent.opacity(0.85)
                                              : StudioTheme.Palette.stroke,
                                   lineWidth: isHovering ? 2 : 1)
            }
            .shadow(color: .black.opacity(isHovering ? (colorScheme == .dark ? 0.5 : 0.18) : 0.06),
                    radius: isHovering ? 12 : 3, y: isHovering ? 6 : 1)
            .offset(y: isHovering && !StudioMotion.reduceMotion ? -2 : 0)
    }

    /// The length, and whether there is sound, on the picture's corner, where a video
    /// player puts them.
    private var badges: some View {
        HStack(spacing: 5) {
            if actions.hasSound {
                Image(systemName: entry.kinds.contains(.microphone) ? "mic.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .help(entry.kinds.contains(.microphone) ? "Has a microphone track" : "Has system audio")
            }
            if !LibraryCatalog.length(entry.duration).isEmpty {
                Text(LibraryCatalog.length(entry.duration))
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(.black.opacity(0.62), in: Capsule())
        .accessibilityHidden(true)
    }

    /// Everything else that can be done to it, under the pointer — and always there for
    /// the keyboard and VoiceOver, which have no pointer to hover with.
    private var more: some View {
        StudioActionMenu(groups: actions.menuActions, style: .studio(.secondary, size: .small, isIconOnly: true)) {
            AnyView(Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold)))
        }
        .background(.regularMaterial, in: StudioTheme.squircle(StudioTheme.Radius.small))
        .padding(7)
        .opacity(isHovering ? 1 : 0)
        .help("More actions")
        .accessibilityLabel("More actions for \(entry.name)")
    }
}

/// One take, as a row.
private struct RecordingRow: View {
    let entry: RecordingEntry
    let catalog: LibraryCatalog
    @State private var isHovering = false
    /// The poster frame, once it has been read. `Data` crossing back from the decoder and
    /// an `NSImage` made here, because `NSImage` is not something to send between actors.
    @State private var poster: Data?

    private var actions: RecordingActions { RecordingActions(entry: entry, catalog: catalog) }

    var body: some View {
        HStack(spacing: 12) {
            Button { catalog.open(entry) } label: {
                HStack(spacing: 12) {
                    thumbnail
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(StudioTheme.Palette.textPrimary)
                            .lineLimit(1)
                        Text(actions.detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(StudioTheme.Palette.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    if actions.hasSound {
                        Image(systemName: "waveform")
                            .font(.system(size: 11))
                            .foregroundStyle(StudioTheme.Palette.textTertiary)
                            .help(entry.kinds.contains(.microphone) ? "Has a microphone track" : "Has system audio")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(StudioPressStyle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(entry.name)
            .accessibilityValue(actions.detail)
            .accessibilityHint("Opens in the editor")
            .accessibilityAddTraits(.isButton)

            StudioActionMenu(groups: actions.menuActions, style: .studio(.ghost, size: .small, isIconOnly: true)) {
                AnyView(Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold)))
            }
            .opacity(isHovering ? 1 : 0.0)
            .help("More actions")
            .accessibilityLabel("More actions for \(entry.name)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isHovering ? StudioTheme.Palette.ghostHover : .clear, in: StudioTheme.squircle(10))
        .onHover { hovering in
            withAnimation(StudioMotion.hover) { isHovering = hovering }
        }
        .task(id: entry.url) { poster = await RecordingPoster.jpeg(for: entry.url) }
        .recordingActions(actions)
    }

    private var thumbnail: some View {
        StudioTheme.squircle(6)
            .fill(StudioTheme.Palette.fill)
            .frame(width: 72, height: 45)
            .overlay {
                if let poster, let image = NSImage(data: poster) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "film")
                        .font(.system(size: 13))
                        .foregroundStyle(StudioTheme.Palette.textTertiary)
                }
            }
            .clipShape(StudioTheme.squircle(6))
            .overlay(StudioTheme.squircle(6).strokeBorder(StudioTheme.Palette.stroke))
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
