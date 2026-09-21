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
            SettingsGroup {
                SettingsRow("Launch Klik at login", subtitle: "Klik lives in the menu bar and has no Dock icon; starting at login keeps the shortcuts ready.") {
                    Toggle("Launch at login", isOn: launchAtLoginBinding).toggleStyle(.switch)
                }
                if model.launchAtLogin == .requiresApproval {
                    SettingsRow("Approval needed", subtitle: "System Settings › General › Login Items", symbol: "exclamationmark.triangle.fill", tint: .orange) {
                        Button("Open Login Items") { PermissionManager.openLoginItemsSettings() }
                    }
                }
                if let launchError {
                    SettingsRow(launchError, symbol: "xmark.octagon.fill", tint: .red)
                }
            }

            SettingsGroup("Appearance") {
                SettingsPreviewPicker(title: "Theme", subtitle: "For the editor, the captures panel and this window.",
                                      selection: $preferences.appearance, options: AppPreferences.Appearance.allCases, label: \.title) { option in
                    AppearancePreview(appearance: option)
                }
            }

            if let sync {
                SettingsGroup("Sync", footer: "Keep snippets, colors and tasks as JSON in a folder — one in iCloud Drive or Dropbox shares them with your other Macs; Klik reloads when the files change. Task attachments stay on this Mac.") {
                    SettingsRow(sync.url?.lastPathComponent ?? "Not syncing",
                                subtitle: sync.url?.path(percentEncoded: false) ?? "Snippets, colors and tasks stay in Klik's own container.",
                                symbol: "arrow.triangle.2.circlepath", tint: .blue) {
                        HStack(spacing: 8) {
                            Button(sync.isOn ? "Change…" : "Choose Folder…") { sync.choose() }
                            if sync.isOn {
                                Button("Stop") { sync.turnOff() }
                            }
                        }
                    }
                }
            }

            SettingsGroup("Menu bar icon", footer: "Custom icons work best as a black-on-transparent PNG or PDF around 18 × 18 points; Klik tints it to match the menu bar.") {
                SettingsCell(vertical: 14) { MenuBarIconPicker() }
            }

            SettingsGroup("Storage", footer: "Every capture is saved here as PNG and listed in the menu bar panel. Deleting a capture from the panel moves the file to the Trash.") {
                SettingsRow(library.folderIsCustom ? library.folderURL.lastPathComponent : "Pictures › Klik",
                            subtitle: library.folderURL.path(percentEncoded: false), symbol: "folder", tint: .orange) {
                    HStack(spacing: 8) {
                        Button("Choose…") { library.chooseFolder() }
                        Button(action: { library.revealFolder() }) {
                            Image(systemName: "arrow.up.forward.app")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Reveal in Finder")
                    }
                }
                if library.folderIsCustom {
                    SettingsRow("Back to the default folder", subtitle: "Pictures › Klik") {
                        Button("Use Default Folder") { library.useDefaultFolder() }
                    }
                }
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

/// A little window in the light, the dark, or half of each.
private struct AppearancePreview: View {
    let appearance: AppPreferences.Appearance

    var body: some View {
        ZStack {
            switch appearance {
            case .light: pane(dark: false)
            case .dark: pane(dark: true)
            case .system:
                ZStack {
                    pane(dark: false)
                    pane(dark: true).clipShape(HalfMask())
                }
            }
        }
    }

    private func pane(dark: Bool) -> some View {
        ZStack {
            LinearGradient(colors: dark ? [Color(white: 0.16), Color(white: 0.1)] : [Color(white: 0.96), Color(white: 0.88)], startPoint: .top, endPoint: .bottom)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(dark ? Color(white: 0.22) : .white)
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 3) {
                        ForEach(0..<3) { _ in Circle().fill(dark ? Color(white: 0.4) : Color(white: 0.75)).frame(width: 4, height: 4) }
                    }
                    .padding(6)
                }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach([0.6, 0.4, 0.5], id: \.self) { width in
                            Capsule().fill(dark ? Color(white: 0.4) : Color(white: 0.8)).frame(width: 60 * width, height: 3)
                        }
                    }
                    .padding(8)
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, -6)
                .shadow(color: .black.opacity(dark ? 0.5 : 0.15), radius: 6, y: 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The lower-right half, split from the top-right corner to the bottom-left.
    nonisolated private struct HalfMask: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
            return path
        }
    }
}

// MARK: - Island & panels

struct IslandSettingsView: View {
    @Environment(AppPreferences.self) private var preferences
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = preferences
        SettingsPane(.island) {
            SettingsGroup("Snippets", footer: "Make snippets in the island's Snippets tab, or from a clipboard entry or an asset with Make Snippet…") {
                SettingsRow("Expand snippets as you type", subtitle: "Type a snippet's keyword (\(preferences.snippetPrefix)welcome) in any app and Klik replaces it with the snippet. Blanks like {{Name}} are asked for first; {{date}}, {{time}} and {{clipboard}} fill themselves.") {
                    Toggle("Expand snippets", isOn: $preferences.snippetsEnabled).toggleStyle(.switch)
                }
                SettingsRow("Keyword trigger", subtitle: "Before every keyword, so ordinary words never expand.") {
                    TextField("", text: $preferences.snippetPrefix, prompt: Text(";"))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .frame(width: 60)
                }
                if !PermissionManager.hasAccessibilityAccess {
                    SettingsRow("Needs Accessibility access", subtitle: "To see what you type and to paste the snippet.", symbol: "exclamationmark.triangle.fill", tint: .orange) {
                        Button("Grant…") {
                            PermissionManager.requestAccessibilityAccess()
                            PermissionManager.revealAppInFinder()
                        }
                    }
                }
            }

            SettingsGroup("Dynamic Island") {
                SettingsRow("Show the Dynamic Island", subtitle: "Hover over the notch — or the pill at the top of the screen — to open your captures. The island never appears in Klik's own screenshots.") {
                    Toggle("Show the island", isOn: $preferences.dynamicIslandEnabled).toggleStyle(.switch)
                }
                SettingsRow("Also show a pill on displays without a notch") {
                    Toggle("Pill on plain displays", isOn: $preferences.dynamicIslandOnPlainDisplays).toggleStyle(.switch)
                }
                .disabled(!preferences.dynamicIslandEnabled)
            }

            SettingsGroup("Panels") {
                SettingsPreviewPicker(title: "Open panels at", subtitle: "Where the library panel (⌥⇧K) and the quick task (⌥/) appear — on the screen the pointer is on.",
                                      selection: $preferences.panelPosition, options: PanelPosition.allCases, label: { $0 == .pointer ? "Pointer" : $0.title }, columns: 4) { position in
                    PanelPositionPreview(position: position)
                }
            }

            SettingsGroup("Color picker", footer: "Every other format is one right-click away on a color card.") {
                SettingsRow("Copy picked colors as") {
                    Picker("Color format", selection: $preferences.colorFormat) {
                        ForEach(ColorFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                }
            }
        }
    }
}

/// A screen with a panel where the position puts it.
private struct PanelPositionPreview: View {
    let position: PanelPosition

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.2), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
            GeometryReader { proxy in
                let panel = CGSize(width: proxy.size.width * 0.34, height: proxy.size.height * 0.42)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.brand.opacity(0.9))
                    .overlay(alignment: .top) {
                        Capsule().fill(.white.opacity(0.5)).frame(width: panel.width * 0.6, height: 2).padding(.top, 3)
                    }
                    .frame(width: panel.width, height: panel.height)
                    .position(point(in: proxy.size, panel: panel))
                if position == .pointer {
                    Image(systemName: "cursorarrow")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .position(x: proxy.size.width * 0.5 + panel.width * 0.35, y: proxy.size.height * 0.5 + panel.height * 0.3)
                }
            }
        }
    }

    private func point(in size: CGSize, panel: CGSize) -> CGPoint {
        let inset: CGFloat = 6
        let left = inset + panel.width / 2, right = size.width - inset - panel.width / 2
        let top = inset + panel.height / 2, bottom = size.height - inset - panel.height / 2
        let midX = size.width / 2, midY = size.height / 2
        switch position {
        case .pointer, .center: return CGPoint(x: midX, y: midY)
        case .top: return CGPoint(x: midX, y: top)
        case .bottom: return CGPoint(x: midX, y: bottom)
        case .topLeft: return CGPoint(x: left, y: top)
        case .topRight: return CGPoint(x: right, y: top)
        case .bottomLeft: return CGPoint(x: left, y: bottom)
        case .bottomRight: return CGPoint(x: right, y: bottom)
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
            SettingsGroup("Full screen") {
                SettingsRow("Include mouse pointer") {
                    Toggle("Include pointer", isOn: $includeCursor).toggleStyle(.switch)
                }
            }

            SettingsGroup("Sound", footer: "Pick one of the macOS alert sounds or any audio file from your Mac.") {
                SettingsRow("Play a sound after each capture") {
                    Toggle("Play a sound", isOn: $preferences.soundEnabled).toggleStyle(.switch)
                }
                SettingsRow("Sound", symbol: "speaker.wave.2.fill", tint: .orange) {
                    HStack(spacing: 8) {
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
                        .frame(width: 180)
                        .onChange(of: preferences.sound) { _, new in preferences.play(new) }
                        Button {
                            preferences.play(preferences.sound)
                        } label: {
                            Image(systemName: "play.fill")
                        }
                        .help("Preview")
                        Button("Choose File…") { preferences.chooseCustomSound() }
                    }
                }
                .disabled(!preferences.soundEnabled)
            }
        }
    }
}

// MARK: - Menu bar icon

private struct MenuBarIconPicker: View {
    @Environment(AppPreferences.self) private var preferences

    private let columns = Array(repeating: GridItem(.fixed(44), spacing: 8), count: 8)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Custom Image…") { preferences.chooseCustomIcon() }
            }
        }
    }

    private func iconCell(selected: Bool, @ViewBuilder content: () -> some View, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            content()
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(width: 44, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? Color.accentColor : Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : SettingsPalette.edge)
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
            SettingsGroup("Time on the island", footer: "On the hour, the half hour and so on, the island shows the time for a moment — with the prayer period when prayer times are on. It waits while the island is open.") {
                SettingsRow("Show the time every") {
                    Picker("Interval", selection: $preferences.timeStatusInterval) {
                        ForEach(AppPreferences.timeIntervals, id: \.self) { minutes in
                            Text(Self.intervalTitle(minutes)).tag(minutes)
                        }
                    }
                    .fixedSize()
                }
                SettingsRow("Preview", subtitle: "Show the time on the island now.") {
                    Button("Show on the Island") { clock?.preview() }
                }
            }

            SettingsGroup("Prayer times") {
                SettingsRow("Prayer times", subtitle: "Computed on this Mac from the sun's position at your location; nothing is fetched from the internet. They refresh at midnight, on wake and when the location changes.") {
                    Toggle("Prayer times", isOn: $preferences.prayerTimesEnabled).toggleStyle(.switch)
                }
                SettingsRow("Calculation method") {
                    Picker("Method", selection: $preferences.prayerMethod) {
                        ForEach(CalculationMethod.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                }
                .disabled(!preferences.prayerTimesEnabled)
                SettingsRow("Asr") {
                    Picker("Asr", selection: $preferences.prayerMadhab) {
                        ForEach(Madhab.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                }
                .disabled(!preferences.prayerTimesEnabled)
                SettingsRow("Announce prayers on the island", subtitle: "Each prayer as it begins, and the times prayer is not allowed: \(Int(PrayerTimes.sunriseWindow / 60)) min after sunrise, \(Int(PrayerTimes.zenithWindow / 60)) min before Dhuhr, \(Int(PrayerTimes.sunsetWindow / 60)) min before Maghrib.") {
                    Toggle("Announce prayers", isOn: $preferences.prayerAnnouncements).toggleStyle(.switch)
                }
                .disabled(!preferences.prayerTimesEnabled)
            }

            SettingsGroup("Where", footer: preferences.prayerLocationMode == .manual
                          ? "Decimal degrees, e.g. 23.8103, 90.4125 for Dhaka. Positive is north / east."
                          : "macOS asks once for permission. The last fix is kept, so the times are ready at launch and offline.") {
                SettingsRow("Location") {
                    Picker("Location", selection: $preferences.prayerLocationMode) {
                        ForEach(AppPreferences.PrayerLocationMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                }
                if preferences.prayerLocationMode == .manual {
                    SettingsRow("Coordinates") {
                        HStack(spacing: 8) {
                            TextField("Latitude", text: $latitude, prompt: Text("Latitude (−90…90)")).frame(width: 140)
                            TextField("Longitude", text: $longitude, prompt: Text("Longitude (−180…180)")).frame(width: 150)
                            Button("Use") { applyManual() }
                                .disabled(Double(latitude) == nil || Double(longitude) == nil)
                        }
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(applyManual)
                    }
                } else {
                    SettingsRow(clock?.placeDescription ?? "—", symbol: "location.fill", tint: .blue) {
                        Button("Locate Now") { clock?.locate() }
                    }
                }
            }
            .disabled(!preferences.prayerTimesEnabled)

            if preferences.prayerTimesEnabled, let clock, let today = clock.today {
                SettingsGroup("Today", footer: "Nudge a time by a few minutes to match your mosque's timetable. \(clock.prayerLine() ?? "")") {
                    ForEach(today.ordered, id: \.prayer) { entry in
                        adjustmentRow(entry.prayer, time: entry.time)
                    }
                    if preferences.prayerAdjustments.values.contains(where: { $0 != 0 }) {
                        SettingsRow("Adjustments") {
                            Button("Reset") { preferences.prayerAdjustments = [:] }
                        }
                    }
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
        return SettingsRow(prayer.title, symbol: prayer.symbol, tint: .cyan) {
            HStack(spacing: 12) {
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
            SettingsGroup("History", footer: "Pinned items are always kept. Content that apps mark as concealed (secrets from credential managers) is never recorded, and nothing leaves this Mac.") {
                SettingsRow("Keep a clipboard history", subtitle: "Text, links, colors, images and files you copy in any app appear in the Dynamic Island's Clipboard tab. Click one to copy it again.") {
                    Toggle("Keep history", isOn: $preferences.clipboardHistoryEnabled).toggleStyle(.switch)
                }
                SettingsRow("Keep the last") {
                    Picker("Limit", selection: $preferences.clipboardHistoryLimit) {
                        ForEach(AppPreferences.clipboardLimits, id: \.self) { Text("\($0) items").tag($0) }
                    }
                    .fixedSize()
                }
                .disabled(!preferences.clipboardHistoryEnabled)
            }

            SettingsGroup {
                SettingsRow("\(clipboard.items.count) item\(clipboard.items.count == 1 ? "" : "s") stored", subtitle: "Pinned items stay when the history is cleared.") {
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
            SettingsGroup(footer: "Klik only captures when you ask it to and never uploads anything.") {
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
                    detail: "Optional: snippets, paste and the front field. Add Klik to the list with “+” or by dragging it in.",
                    granted: model.hasAccessibilityAccess,
                    request: {
                        PermissionManager.requestAccessibilityAccess()
                        PermissionManager.revealAppInFinder()
                    },
                    openSettings: PermissionManager.openAccessibilitySettings
                )
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
        SettingsRow(title, subtitle: detail, symbol: symbol, tint: tint) {
            HStack(spacing: 10) {
                if granted {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 13, weight: .medium))
                        .labelStyle(.titleAndIcon)
                } else {
                    Button("Grant Access…") {
                        request()
                        openSettings()
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button(action: openSettings) {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Open in System Settings")
            }
        }
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
            SettingsGroup {
                SettingsRow("Start each editor with the options last used", subtitle: "Off: every editor starts with the defaults below.") {
                    Toggle("Remember last used", isOn: d.rememberLastUsed).toggleStyle(.switch)
                }
            }

            SettingsGroup("Colors") {
                SettingsRow("Annotations") { SwatchRow(color: d.color) }
                SettingsRow("Highlight box") { SwatchRow(color: d.highlightColor) }
            }

            SettingsGroup("Shapes, lines & arrows") {
                SliderRow("Stroke width", value: d.strokeWidth, range: EditorDefaults.strokeRange, unit: "px")
                SettingsRow("Shape") {
                    Picker("Shape", selection: d.shapeKind) {
                        Label("Rectangle", systemImage: "rectangle").tag(ShapeKind.rectangle)
                        Label("Ellipse", systemImage: "oval").tag(ShapeKind.ellipse)
                        Label("Line", systemImage: "line.diagonal").tag(ShapeKind.line)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                SettingsRow("Fill") {
                    Picker("Fill", selection: d.fillMode) {
                        Text("None").tag(FillMode.none)
                        Text("Solid").tag(FillMode.solid)
                        Text("Translucent").tag(FillMode.translucent)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                SettingsRow("Arrow head") {
                    Picker("Arrow head", selection: d.arrowStyle) {
                        Label("One end", systemImage: "arrow.right").tag(ArrowStyle.single)
                        Label("Both ends", systemImage: "arrow.left.and.right").tag(ArrowStyle.double)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }

            SettingsGroup("Text") {
                SliderRow("Font size", value: d.fontSize, range: EditorDefaults.fontSizeRange, unit: "pt")
                SettingsRow("Weight") {
                    HStack(spacing: 10) {
                        Slider(value: d.fontWeight, in: TextStyle.weightRange).frame(width: 160)
                        Text(TextStyle(color: .black, fontSize: 12, background: .none, weight: preferences.editorDefaults.fontWeight).weightName)
                            .foregroundStyle(.secondary)
                            .frame(width: 66, alignment: .trailing)
                    }
                }
                SettingsRow("Background") {
                    Picker("Background", selection: d.textBackground) {
                        Text("None").tag(TextBackground.none)
                        Text("Solid").tag(TextBackground.solid)
                        Text("Translucent").tag(TextBackground.translucent)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }

            SettingsGroup("Marker, blur & counter") {
                SliderRow("Marker width", value: d.highlighterWidth, range: EditorDefaults.highlighterRange, unit: "px")
                SettingsRow("Blur style") {
                    Picker("Blur style", selection: d.blurKind) {
                        Text("Blur").tag(BlurKind.blur)
                        Text("Pixelate").tag(BlurKind.pixelate)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                SliderRow("Blur strength", value: d.blurIntensity, range: EditorDefaults.blurRange, unit: "")
                SliderRow("Counter size", value: d.counterSize, range: EditorDefaults.counterRange, unit: "px")
            }

            SettingsGroup {
                SettingsRow("Defaults", subtitle: "Back to Klik's own colors, widths and sizes; the option above is kept.") {
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
        SettingsRow(label) {
            HStack(spacing: 10) {
                Slider(value: Binding(get: { value }, set: { value = $0.rounded() }), in: range).frame(width: 160)
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
            if hasReservedBinding {
                SettingsGroup {
                    SettingsRow("A binding matches a macOS screenshot shortcut",
                                subtitle: "macOS handles ⌘⇧3, ⌘⇧4, ⌘⇧5 and ⌘⇧6 before Klik sees them. Turn them off under Keyboard › Keyboard Shortcuts › Screenshots to use them here.",
                                symbol: "exclamationmark.triangle.fill", tint: .orange) {
                        Button("Keyboard Settings…") { PermissionManager.openKeyboardShortcutSettings() }
                    }
                }
            }

            SettingsGroup("Global shortcuts", footer: "Click a field and press a new combination. Shortcuts need ⌘, ⌥ or ⌃ (or a function key); ⌫ removes one, ⎋ keeps the current one.") {
                ForEach(HotkeyID.configurable, id: \.self) { id in
                    let entry = shortcuts.entries[id]
                    SettingsRow(id.title, symbol: symbol(for: id), tint: tint(for: id)) {
                        HStack(spacing: 10) {
                            ShortcutRecorderView(
                                hotkey: entry?.hotkey,
                                onChange: { shortcuts.set($0, for: id) },
                                onRecordingChanged: { shortcuts.isRecording = $0 }
                            )
                            statusIcon(entry?.status ?? .unassigned)
                                .frame(width: 18)
                        }
                    }
                }
            }

            SettingsGroup {
                SettingsRow("Defaults", subtitle: "Every shortcut back to what Klik ships with.") {
                    Button("Restore Defaults") { shortcuts.restoreDefaults() }
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
            SettingsGroup {
                SettingsCell(vertical: 16) {
                    HStack(spacing: 16) {
                        AppIconTile(size: 56)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Klik").font(.system(size: 17, weight: .semibold))
                            Text("Screenshots you can annotate, blur and share — built natively for macOS.")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 16)
                        Text("Version \(short) (\(build))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .font(.system(size: 13))
                    }
                }
                SettingsRow("Version", subtitle: "With the macOS version, for a bug report.") {
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("Klik \(short) (\(build)) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)", forType: .string)
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                    }
                }
                SettingsRow("macOS") {
                    Text(ProcessInfo.processInfo.operatingSystemVersionString).foregroundStyle(.secondary)
                }
            }

            SettingsGroup("On this Mac") {
                SettingsRow("Klik", subtitle: Bundle.main.bundleURL.path(percentEncoded: false)) {
                    Button("Show in Finder") { PermissionManager.revealAppInFinder() }
                }
                SettingsRow("Captures", subtitle: library.folderURL.path(percentEncoded: false)) {
                    Button("Show in Finder") { library.revealFolder() }
                }
            }

            SettingsGroup {
                SettingsRow("© \(String(Calendar.current.component(.year, from: .now))) Stackrover", subtitle: "Klik keeps everything on this Mac unless you set up share links.")
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
