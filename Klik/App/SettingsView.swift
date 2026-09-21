import SwiftUI

/// UserDefaults keys for user preferences read outside SwiftUI.
enum PreferenceKey {
    static let includeCursor = "capture.includeCursor"
}

// MARK: - General

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(CaptureLibrary.self) private var library
    @Environment(AppPreferences.self) private var preferences
    @Environment(SyncFolder.self) private var sync: SyncFolder?
    @AppStorage(PreferenceKey.includeCursor) private var includeCursor = false
    @State private var launchError: String?

    var body: some View {
        @Bindable var preferences = preferences
        SettingsPane(.general) {
            Section {
                Picker("Appearance", selection: $preferences.appearance) {
                    ForEach(AppPreferences.Appearance.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Appearance")
            } footer: {
                Text("Applies to the editor, the captures panel and this window.")
            }

            Section {
                Toggle(isOn: launchAtLoginBinding) {
                    Text("Launch Klik at login")
                    Text("Klik lives in the menu bar and has no Dock icon; starting at login keeps the shortcuts ready.")
                }
                if model.launchAtLogin == .requiresApproval {
                    HStack {
                        Label("Approval needed in System Settings › General › Login Items", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                        Spacer()
                        Button("Open Login Items") { PermissionManager.openLoginItemsSettings() }
                            .controlSize(.small)
                    }
                }
                if let launchError {
                    Text(launchError).foregroundStyle(.red).font(.callout)
                }
            } header: {
                Text("Startup")
            }

            if let sync {
                Section {
                    HStack(spacing: 12) {
                        SymbolTile(symbol: "arrow.triangle.2.circlepath", tint: .blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sync.url?.lastPathComponent ?? "Not syncing")
                            Text(sync.url?.path(percentEncoded: false) ?? "Snippets, colors and tasks stay in Klik's own container.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 16)
                        Button(sync.isOn ? "Change…" : "Choose Folder…") { sync.choose() }
                        if sync.isOn {
                            Button("Stop") { sync.turnOff() }
                        }
                    }
                } header: {
                    Text("Sync")
                } footer: {
                    Text("Keep snippets, colors and tasks as JSON in a folder — one in iCloud Drive or Dropbox shares them with your other Macs; Klik reloads when the files change. Task attachments stay on this Mac.")
                }
            }

            Section {
                MenuBarIconPicker()
            } header: {
                Text("Menu bar icon")
            } footer: {
                Text("Custom icons work best as a black-on-transparent PNG or PDF around 18 × 18 points; Klik tints it to match the menu bar.")
            }

            Section {
                HStack(spacing: 12) {
                    SymbolTile(symbol: "folder", tint: .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(library.folderIsCustom ? library.folderURL.lastPathComponent : "Pictures › Klik")
                        Text(library.folderURL.path(percentEncoded: false))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 16)
                    Button("Choose…") { library.chooseFolder() }
                    Button(action: { library.revealFolder() }) {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Reveal in Finder")
                }
                .padding(.vertical, 4)
                if library.folderIsCustom {
                    Button("Use Default Folder") { library.useDefaultFolder() }
                        .controlSize(.small)
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("Every capture is saved here as PNG and listed in the menu bar panel. Deleting a capture from the panel moves the file to the Trash.")
            }

        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { model.launchAtLogin != .disabled },
            set: { enabled in
                do {
                    try LaunchAtLogin.setEnabled(enabled)
                    launchError = nil
                } catch {
                    launchError = error.localizedDescription
                }
                model.launchAtLogin = LaunchAtLogin.state
            }
        )
    }
}

// MARK: - Island & panels

struct IslandSettingsView: View {
    @Environment(AppPreferences.self) private var preferences
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = preferences
        SettingsPane(.island) {
            Section {
                Toggle(isOn: $preferences.snippetsEnabled) {
                    Text("Expand snippets as you type")
                    Text("Type a snippet's keyword (\(preferences.snippetPrefix)welcome) in any app and Klik replaces it with the snippet. Blanks like {{Name}} are asked for first; {{date}}, {{time}} and {{clipboard}} fill themselves.")
                }
                HStack {
                    Text("Keyword trigger")
                    Spacer()
                    TextField("", text: $preferences.snippetPrefix, prompt: Text(";"))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .frame(width: 60)
                    Text("before every keyword, so ordinary words never expand")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if !PermissionManager.hasAccessibilityAccess {
                    HStack {
                        Label("Needs Accessibility access to see what you type and to paste", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                        Spacer()
                        Button("Grant…") {
                            PermissionManager.requestAccessibilityAccess()
                            PermissionManager.revealAppInFinder()
                        }
                        .controlSize(.small)
                    }
                }
            } header: {
                Text("Snippets")
            } footer: {
                Text("Make snippets in the island's Snippets tab, or from a clipboard entry or an asset with Make Snippet…")
            }

            Section {
                Toggle(isOn: $preferences.dynamicIslandEnabled) {
                    Text("Show the Dynamic Island")
                    Text("Hover over the notch — or the pill at the top of the screen — to open your captures. The island never appears in Klik's own screenshots.")
                }
                Toggle(isOn: $preferences.dynamicIslandOnPlainDisplays) {
                    Text("Also show a pill on displays without a notch")
                }
                .disabled(!preferences.dynamicIslandEnabled)
            } header: {
                Text("Dynamic Island")
            }

            Section {
                Picker("Open panels at", selection: $preferences.panelPosition) {
                    ForEach(PanelPosition.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Panels")
            } footer: {
                Text("Where the library panel (⌥⇧K) and the quick task (⌥/) appear — on the screen the pointer is on.")
            }

            Section {
                Picker("Copy picked colors as", selection: $preferences.colorFormat) {
                    ForEach(ColorFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Color picker")
            } footer: {
                Text("Every other format is one right-click away on a color card.")
            }

        }
    }
}

// MARK: - Capture

struct CaptureSettingsView: View {
    @Environment(AppPreferences.self) private var preferences
    @AppStorage(PreferenceKey.includeCursor) private var includeCursor = false

    var body: some View {
        @Bindable var preferences = preferences
        SettingsPane(.capture) {
            Section("Full screen") {
                Toggle(isOn: $includeCursor) {
                    Text("Include mouse pointer")
                }
            }

            Section {
                Toggle(isOn: $preferences.soundEnabled) {
                    Text("Play a sound after each capture")
                }
                HStack(spacing: 12) {
                    SymbolTile(symbol: "speaker.wave.2.fill", tint: .orange)
                    Picker("Sound", selection: $preferences.sound) {
                        Text(AppPreferences.Sound.shutter.title).tag(AppPreferences.Sound.shutter)
                        Divider()
                        ForEach(AppPreferences.Sound.systemNames, id: \.self) { name in
                            Text(name).tag(AppPreferences.Sound.system(name))
                        }
                        if let url = preferences.customSoundURL {
                            Divider()
                            Text(url.lastPathComponent).tag(AppPreferences.Sound.custom)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                    .onChange(of: preferences.sound) { _, new in preferences.play(new) }
                    Button {
                        preferences.play(preferences.sound)
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .help("Preview")
                    Spacer(minLength: 8)
                    Button("Choose File…") { preferences.chooseCustomSound() }
                }
                .disabled(!preferences.soundEnabled)
                .padding(.vertical, 2)
            } header: {
                Text("Sound")
            } footer: {
                Text("Pick one of the macOS alert sounds or any audio file from your Mac.")
            }
        }
    }
}

// MARK: - Menu bar icon

private struct MenuBarIconPicker: View {
    @Environment(AppPreferences.self) private var preferences

    private let columns = Array(repeating: GridItem(.fixed(44), spacing: 8), count: 8)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(AppPreferences.Icon.symbols, id: \.self) { name in
                    iconCell(selected: preferences.icon == .symbol(name)) {
                        Image(systemName: name).font(.system(size: 15, weight: .medium))
                    } action: {
                        preferences.icon = .symbol(name)
                    }
                    .help(name)
                }
                if let url = preferences.customIconURL, let image = NSImage(contentsOf: url) {
                    iconCell(selected: preferences.icon == .custom) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: 18, height: 18)
                    } action: {
                        preferences.icon = .custom
                    }
                    .help(url.lastPathComponent)
                }
            }
            HStack {
                Text("The icon lives in the menu bar; click it to open your captures.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Custom Image…") { preferences.chooseCustomIcon() }
            }
        }
        .padding(.vertical, 4)
    }

    private func iconCell(selected: Bool, @ViewBuilder content: () -> some View, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            content()
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(width: 44, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? Color.accentColor : Color.primary.opacity(0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Time & prayer

struct TimeSettingsView: View {
    @Environment(AppPreferences.self) private var preferences
    @Environment(PrayerClock.self) private var clock: PrayerClock?
    @State private var latitude = ""
    @State private var longitude = ""

    var body: some View {
        @Bindable var preferences = preferences
        SettingsPane(.time) {
            Section {
                Picker("Show the time every", selection: $preferences.timeStatusInterval) {
                    ForEach(AppPreferences.timeIntervals, id: \.self) { minutes in
                        Text(Self.intervalTitle(minutes)).tag(minutes)
                    }
                }
                HStack {
                    Text("Preview").foregroundStyle(.secondary)
                    Spacer()
                    Button("Show on the Island Now") { clock?.preview() }
                }
            } header: {
                Text("Time on the island")
            } footer: {
                Text("On the hour, the half hour and so on, the island shows the time for a moment — with the prayer period when prayer times are on. It waits while the island is open.")
            }

            Section {
                Toggle(isOn: $preferences.prayerTimesEnabled) {
                    Text("Prayer times")
                    Text("Computed on this Mac from the sun's position at your location; nothing is fetched from the internet. They refresh at midnight, on wake and when the location changes.")
                }
                Picker("Calculation method", selection: $preferences.prayerMethod) {
                    ForEach(CalculationMethod.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .disabled(!preferences.prayerTimesEnabled)
                Picker("Asr", selection: $preferences.prayerMadhab) {
                    ForEach(Madhab.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .disabled(!preferences.prayerTimesEnabled)
                Toggle(isOn: $preferences.prayerAnnouncements) {
                    Text("Announce prayers on the island")
                    Text("Each prayer as it begins, and the times prayer is not allowed: \(Int(PrayerTimes.sunriseWindow / 60)) min after sunrise, \(Int(PrayerTimes.zenithWindow / 60)) min before Dhuhr, \(Int(PrayerTimes.sunsetWindow / 60)) min before Maghrib.")
                }
                .disabled(!preferences.prayerTimesEnabled)
            } header: {
                Text("Prayer times")
            }

            Section {
                Picker("Location", selection: $preferences.prayerLocationMode) {
                    ForEach(AppPreferences.PrayerLocationMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if preferences.prayerLocationMode == .manual {
                    HStack {
                        TextField("Latitude", text: $latitude, prompt: Text("Latitude (−90…90)"))
                        TextField("Longitude", text: $longitude, prompt: Text("Longitude (−180…180)"))
                        Button("Use") { applyManual() }
                            .disabled(Double(latitude) == nil || Double(longitude) == nil)
                    }
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(applyManual)
                } else {
                    HStack {
                        Text(clock?.placeDescription ?? "—").foregroundStyle(.secondary)
                        Spacer()
                        Button("Locate Now") { clock?.locate() }
                    }
                }
            } header: {
                Text("Where")
            } footer: {
                Text(preferences.prayerLocationMode == .manual
                     ? "Decimal degrees, e.g. 23.8103, 90.4125 for Dhaka. Positive is north / east."
                     : "macOS asks once for permission. The last fix is kept, so the times are ready at launch and offline.")
            }
            .disabled(!preferences.prayerTimesEnabled)

            if preferences.prayerTimesEnabled, let clock, let today = clock.today {
                Section {
                    ForEach(today.ordered, id: \.prayer) { entry in
                        adjustmentRow(entry.prayer, time: entry.time)
                    }
                    if preferences.prayerAdjustments.values.contains(where: { $0 != 0 }) {
                        Button("Reset Adjustments") { preferences.prayerAdjustments = [:] }
                            .controlSize(.small)
                    }
                } header: {
                    Text("Today")
                } footer: {
                    Text("Nudge a time by a few minutes to match your mosque's timetable. \(clock.prayerLine() ?? "")")
                }
            }
        }
        .onAppear {
            latitude = preferences.prayerManualPlace.latitude == 0 ? "" : String(preferences.prayerManualPlace.latitude)
            longitude = preferences.prayerManualPlace.longitude == 0 ? "" : String(preferences.prayerManualPlace.longitude)
            // The status this tab configures, on the island, while it is being chosen.
            clock?.preview()
        }
    }

    /// A prayer's time with a ± minutes stepper.
    private func adjustmentRow(_ prayer: Prayer, time: Date) -> some View {
        let offset = Binding(
            get: { preferences.prayerAdjustments[prayer] ?? 0 },
            set: { preferences.prayerAdjustments[prayer] = $0 }
        )
        return HStack {
            Label(prayer.title, systemImage: prayer.symbol)
            Spacer()
            Text(PrayerClock.clock(time)).monospacedDigit()
            Stepper(value: offset, in: -60...60) {
                Text(offset.wrappedValue == 0 ? "±0" : String(format: "%+d min", offset.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(offset.wrappedValue == 0 ? .secondary : .primary)
                    .frame(width: 56, alignment: .trailing)
            }
            .controlSize(.small)
        }
    }

    private func applyManual() {
        guard let lat = Double(latitude), let lon = Double(longitude), (-90...90).contains(lat), (-180...180).contains(lon) else { return }
        preferences.prayerManualPlace = Coordinates(latitude: lat, longitude: lon)
    }

    private static func intervalTitle(_ minutes: Int) -> String {
        switch minutes {
        case 0: "Never"
        case 60: "Hour"
        case let m where m < 60: "\(m) minutes"
        default: "\(minutes / 60) hours"
        }
    }
}

// MARK: - Clipboard

struct ClipboardSettingsView: View {
    @Environment(ClipboardHistory.self) private var clipboard
    @Environment(AppPreferences.self) private var preferences
    @State private var confirmClear = false

    var body: some View {
        @Bindable var preferences = preferences
        SettingsPane(.clipboard) {
            Section {
                Toggle(isOn: $preferences.clipboardHistoryEnabled) {
                    Text("Keep a clipboard history")
                    Text("Text, links, colors, images and files you copy in any app appear in the Dynamic Island's Clipboard tab. Click one to copy it again.")
                }
                Picker("Keep the last", selection: $preferences.clipboardHistoryLimit) {
                    ForEach(AppPreferences.clipboardLimits, id: \.self) { Text("\($0) items").tag($0) }
                }
                .disabled(!preferences.clipboardHistoryEnabled)
            } header: {
                Text("History")
            } footer: {
                Text("Pinned items are always kept. Content that apps mark as concealed (secrets from credential managers) is never recorded, and nothing leaves this Mac.")
            }

            Section {
                HStack {
                    Text("\(clipboard.items.count) item\(clipboard.items.count == 1 ? "" : "s") stored")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear History…", role: .destructive) { confirmClear = true }
                        .disabled(clipboard.items.allSatisfy(\.pinned))
                }
            }
        }
        .confirmationDialog("Clear the clipboard history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { clipboard.clear() }
        } message: {
            Text("Pinned items stay. This cannot be undone.")
        }
    }
}

// MARK: - Permissions

struct PermissionSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsPane(.permissions) {
            Section {
                PermissionRow(
                    symbol: "rectangle.dashed.badge.record", tint: .blue,
                    title: "Screen Recording",
                    detail: "Required for every capture. Takes effect after relaunching Klik.",
                    granted: model.hasScreenCaptureAccess,
                    request: { PermissionManager.requestScreenCaptureAccess() },
                    openSettings: PermissionManager.openScreenRecordingSettings
                )
                PermissionRow(
                    symbol: "accessibility", tint: .purple,
                    title: "Accessibility",
                    detail: "Optional. Add Klik to the list with “+” or by dragging it in.",
                    granted: model.hasAccessibilityAccess,
                    request: {
                        PermissionManager.requestAccessibilityAccess()
                        PermissionManager.revealAppInFinder()
                    },
                    openSettings: PermissionManager.openAccessibilitySettings
                )
            } header: {
                Text("Permissions")
            } footer: {
                Text("Klik only captures when you ask it to and never uploads anything.")
            }
        }
        .onAppear { model.refreshPermissionState() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                model.refreshPermissionState()
            }
        }
    }
}

private struct PermissionRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let granted: Bool
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            SymbolTile(symbol: symbol, tint: tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout.weight(.medium))
                    .labelStyle(.titleAndIcon)
            } else {
                Button("Grant Access…") {
                    request()
                    openSettings()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Button(action: openSettings) {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Open in System Settings")
        }
        .padding(.vertical, 4)
    }
}

struct SymbolTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size / 2, weight: size >= 48 ? .semibold : .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size / 4, style: .continuous))
    }
}

// MARK: - Editor defaults

struct EditorSettingsView: View {
    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        let d = $preferences.editorDefaults
        SettingsPane(.editor) {
            Section {
                Toggle(isOn: d.rememberLastUsed) {
                    Text("Start each editor with the options last used")
                    Text("Off: every editor starts with the defaults below.")
                }
            }

            Section("Colors") {
                LabeledContent("Annotations") { SwatchRow(color: d.color) }
                LabeledContent("Highlight box") { SwatchRow(color: d.highlightColor) }
            }

            Section("Shapes, lines & arrows") {
                SliderRow("Stroke width", value: d.strokeWidth, range: EditorDefaults.strokeRange, unit: "px")
                Picker("Shape", selection: d.shapeKind) {
                    Text("Rectangle").tag(ShapeKind.rectangle)
                    Text("Ellipse").tag(ShapeKind.ellipse)
                    Text("Line").tag(ShapeKind.line)
                }
                Picker("Fill", selection: d.fillMode) {
                    Text("None").tag(FillMode.none)
                    Text("Solid").tag(FillMode.solid)
                    Text("Translucent").tag(FillMode.translucent)
                }
                Picker("Arrow head", selection: d.arrowStyle) {
                    Text("One end").tag(ArrowStyle.single)
                    Text("Both ends").tag(ArrowStyle.double)
                }
            }

            Section("Text") {
                SliderRow("Font size", value: d.fontSize, range: EditorDefaults.fontSizeRange, unit: "pt")
                LabeledContent("Weight") {
                    HStack(spacing: 10) {
                        Slider(value: d.fontWeight, in: TextStyle.weightRange)
                        Text(TextStyle(color: .black, fontSize: 12, background: .none, weight: preferences.editorDefaults.fontWeight).weightName)
                            .foregroundStyle(.secondary)
                            .frame(width: 66, alignment: .trailing)
                    }
                }
                Picker("Background", selection: d.textBackground) {
                    Text("None").tag(TextBackground.none)
                    Text("Solid").tag(TextBackground.solid)
                    Text("Translucent").tag(TextBackground.translucent)
                }
            }

            Section("Marker, blur & counter") {
                SliderRow("Marker width", value: d.highlighterWidth, range: EditorDefaults.highlighterRange, unit: "px")
                Picker("Blur style", selection: d.blurKind) {
                    Text("Blur").tag(BlurKind.blur)
                    Text("Pixelate").tag(BlurKind.pixelate)
                }
                SliderRow("Blur strength", value: d.blurIntensity, range: EditorDefaults.blurRange, unit: "")
                SliderRow("Counter size", value: d.counterSize, range: EditorDefaults.counterRange, unit: "px")
            }

            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults") {
                        let remember = preferences.editorDefaults.rememberLastUsed
                        preferences.editorDefaults = EditorDefaults()
                        preferences.editorDefaults.rememberLastUsed = remember
                    }
                }
            }
        }
    }
}

/// The editor's palette plus a color well, bound to one color.
private struct SwatchRow: View {
    @Binding var color: RGBA

    var body: some View {
        HStack(spacing: 5) {
            ForEach(RGBA.palette, id: \.self) { swatch in
                Button { color = swatch } label: {
                    Circle()
                        .fill(Color(nsColor: swatch.nsColor))
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(.primary.opacity(color == swatch ? 0.95 : 0.3), lineWidth: color == swatch ? 2 : 1))
                        .padding(2)
                }
                .buttonStyle(.plain)
            }
            ColorPicker("", selection: Binding(
                get: { Color(nsColor: color.nsColor) },
                set: { color = RGBA(NSColor($0)) }
            ), supportsOpacity: false)
            .labelsHidden()
            .frame(width: 24)
        }
    }
}

private struct SliderRow: View {
    let label: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    let unit: String

    init(_ label: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>, unit: String) {
        self.label = label
        _value = value
        self.range = range
        self.unit = unit
    }

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 10) {
                Slider(value: Binding(get: { value }, set: { value = $0.rounded() }), in: range)
                Text("\(Int(value))\(unit.isEmpty ? "" : " \(unit)")")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 66, alignment: .trailing)
            }
        }
    }
}

// MARK: - Shortcuts

struct ShortcutSettingsView: View {
    @Environment(ShortcutController.self) private var shortcuts

    private var hasReservedBinding: Bool {
        shortcuts.entries.values.contains { $0.status == .reservedByMacOS }
    }

    var body: some View {
        SettingsPane(.shortcuts) {
            Section {
                ForEach(HotkeyID.configurable, id: \.self) { id in
                    let entry = shortcuts.entries[id]
                    HStack(spacing: 12) {
                        SymbolTile(symbol: symbol(for: id), tint: tint(for: id))
                        Text(id.title)
                        Spacer(minLength: 16)
                        ShortcutRecorderView(
                            hotkey: entry?.hotkey,
                            onChange: { shortcuts.set($0, for: id) },
                            onRecordingChanged: { shortcuts.isRecording = $0 }
                        )
                        statusIcon(entry?.status ?? .unassigned)
                            .frame(width: 18)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Global shortcuts")
            } footer: {
                HStack(alignment: .top) {
                    Text("Click a field and press a new combination. Shortcuts need ⌘, ⌥ or ⌃ (or a function key); ⌫ removes one, ⎋ keeps the current one.")
                    Spacer(minLength: 12)
                    Button("Restore Defaults") { shortcuts.restoreDefaults() }
                        .controlSize(.small)
                }
            }

            if hasReservedBinding {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("A binding matches a macOS screenshot shortcut")
                                .fontWeight(.medium)
                            Text("macOS handles ⌘⇧3, ⌘⇧4, ⌘⇧5 and ⌘⇧6 before Klik sees them. Turn them off under Keyboard › Keyboard Shortcuts › Screenshots to use them here.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button("Keyboard Settings…") { PermissionManager.openKeyboardShortcutSettings() }
                            .controlSize(.small)
                    }
                }
            }

        }
    }

    private func symbol(for id: HotkeyID) -> String {
        switch id {
        case .fullScreen: "display"
        case .region: "viewfinder"
        case .scrolling: "rectangle.expand.vertical"
        case .showPanel: "cursorarrow.rays"
        case .captureText: "text.viewfinder"
        case .pickColor: "eyedropper"
        case .quickTask: "checklist"
        case .clipboardPanel: "doc.on.clipboard"
        case .commandPalette: "command"
        case .pasteNext: "square.stack.3d.down.right"
        case .window: "macwindow"
        case .confirmCapture, .cancelCapture: "xmark"
        }
    }

    private func tint(for id: HotkeyID) -> Color {
        switch id {
        case .fullScreen: .blue
        case .region: .teal
        case .scrolling: .indigo
        case .showPanel: .orange
        case .captureText: .green
        case .pickColor: .red
        case .quickTask: .mint
        case .clipboardPanel: .purple
        case .commandPalette: .brand
        case .pasteNext: .teal
        case .window: .cyan
        case .confirmCapture, .cancelCapture: .gray
        }
    }

    @ViewBuilder
    private func statusIcon(_ status: ShortcutController.Status) -> some View {
        switch status {
        case .active:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                .help("Active")
        case .reservedByMacOS:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .help("macOS uses this shortcut for its own screenshots")
        case .conflict:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                .help("Another app already uses this shortcut")
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                .help("Could not register")
        case .unassigned:
            Image(systemName: "minus.circle").foregroundStyle(.tertiary)
                .help("No shortcut assigned")
        }
    }
}

// MARK: - About

struct AboutSettingsView: View {
    @Environment(CaptureLibrary.self) private var library
    @State private var copied = false

    private var short: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }

    var body: some View {
        SettingsPane(.about) {
            Section {
                LabeledContent("Version") {
                    HStack(spacing: 10) {
                        Text("\(short) (\(build))").monospacedDigit().foregroundStyle(.secondary)
                        Button(copied ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("Klik \(short) (\(build)) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)", forType: .string)
                            copied = true
                            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                        }
                        .controlSize(.small)
                        .help("Copy the version and macOS version, for a bug report")
                    }
                }
                LabeledContent("macOS") {
                    Text(ProcessInfo.processInfo.operatingSystemVersionString).foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("Klik") {
                    Button("Show in Finder") { PermissionManager.revealAppInFinder() }
                        .controlSize(.small)
                }
                LabeledContent("Captures") {
                    Button("Show in Finder") { library.revealFolder() }
                        .controlSize(.small)
                }
            } header: {
                Text("On this Mac")
            }

            Section {
                Text("© \(String(Calendar.current.component(.year, from: .now))) Stackrover. Klik keeps everything on this Mac unless you set up share links.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview("Settings") {
    SettingsRootView(buttons: WindowButtons(close: {}, minimize: {}, zoom: {}))
        .environment(SettingsNavigation()).environment(AppModel()).environment(CaptureLibrary()).environment(AppPreferences())
        .environment(ShortcutController()).environment(ClipboardHistory())
        .frame(width: 920, height: 640)
}
