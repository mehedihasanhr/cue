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
    @AppStorage(PreferenceKey.includeCursor) private var includeCursor = false
    @State private var launchError: String?

    var body: some View {
        @Bindable var preferences = preferences
        Form {
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

            Section {
                Toggle(isOn: $preferences.dynamicIslandEnabled) {
                    Text("Show the Dynamic Island")
                    Text("Hover over the notch — or the pill at the top of the screen — to open your captures. The island is never part of a screenshot.")
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
        .formStyle(.grouped)
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

// MARK: - Capture

struct CaptureSettingsView: View {
    @Environment(AppPreferences.self) private var preferences
    @AppStorage(PreferenceKey.includeCursor) private var includeCursor = false

    var body: some View {
        @Bindable var preferences = preferences
        Form {
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
                    SymbolTile(symbol: "speaker.wave.2.fill", tint: .pink)
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
        .formStyle(.grouped)
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

// MARK: - Clipboard

struct ClipboardSettingsView: View {
    @Environment(ClipboardHistory.self) private var clipboard
    @Environment(AppPreferences.self) private var preferences
    @State private var confirmClear = false

    var body: some View {
        @Bindable var preferences = preferences
        Form {
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
        .formStyle(.grouped)
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
        Form {
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
        .formStyle(.grouped)
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

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

// MARK: - Editor defaults

struct EditorSettingsView: View {
    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        let d = $preferences.editorDefaults
        Form {
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
        .formStyle(.grouped)
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
        Form {
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
        .formStyle(.grouped)
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
        case .pickColor: .pink
        case .quickTask: .mint
        case .clipboardPanel: .purple
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
    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .shadow(color: .blue.opacity(0.25), radius: 12, y: 6)

            VStack(spacing: 4) {
                Text("Klik")
                    .font(.title.weight(.semibold))
                Text(version)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("Screenshots you can annotate, blur and share — built natively for macOS.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)

            Spacer(minLength: 0)

            Text("© \(String(Calendar.current.component(.year, from: .now))) Stackrover")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview("General") {
    GeneralSettingsView().environment(AppModel()).environment(CaptureLibrary()).environment(AppPreferences()).frame(width: 560, height: 470)
}

#Preview("Shortcuts") {
    ShortcutSettingsView().environment(ShortcutController()).frame(width: 560, height: 400)
}

#Preview("About") {
    AboutSettingsView().frame(width: 560, height: 300)
}
