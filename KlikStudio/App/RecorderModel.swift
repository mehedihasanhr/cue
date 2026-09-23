import AppKit
import AVFoundation
import Foundation
import Observation
import os
import RecordKit
import ScreenCaptureKit

/// What can be recorded, what is chosen, and what has been recorded already.
///
/// Shared by the floating bar and the library window: both are views onto the same
/// choice, so picking a window in one is picking it in the other.
@MainActor
@Observable
final class RecorderModel {
    /// The four things a screen recorder can point at.
    enum Mode: String, CaseIterable, Identifiable {
        case display, window, area, device

        var id: String { rawValue }

        var title: String {
            switch self {
            case .display: "Display"
            case .window: "Window"
            case .area: "Area"
            case .device: "Device"
            }
        }

        var symbol: String {
            switch self {
            case .display: "menubar.dock.rectangle"
            case .window: "macwindow"
            case .area: "rectangle.dashed"
            case .device: "apps.iphone"
            }
        }

        /// The point size that puts this symbol on the same optical line as the others.
        ///
        /// SF Symbols share an optical grid, not a box: at one point size these ink
        /// different heights, which is why the row used to read as four sizes. Measured,
        /// not guessed — all four land their ink at exactly 15.5pt tall.
        ///
        /// `menubar.dock.rectangle` replaced `display` and `apps.iphone` replaced `iphone`
        /// so the four share a drawing: a plain rounded rectangle with something in it. A
        /// monitor on a stand and a bare phone were two different kinds of picture sitting
        /// in one row.
        var symbolSize: CGFloat {
            switch self {
            case .display: 17
            case .window: 17
            case .area: 17
            case .device: 15
            }
        }

        var help: String {
            switch self {
            case .display: "Record a whole display"
            case .window: "Record one window"
            case .area: "Drag out part of the screen"
            case .device: "Record a connected iPhone or iPad"
            }
        }

        /// Device capture needs the Continuity/CoreMediaIO path, which is not built yet.
        /// Shown but dimmed, because pretending it is not a feature is its own confusion.
        var isAvailable: Bool { self != .device }
    }

    struct Source: Identifiable, Hashable {
        let id: String
        let title: String
        let subtitle: String
        let target: CaptureTarget
    }

    private(set) var displays: [Source] = []
    private(set) var windows: [Source] = []
    private(set) var recents: [Recording] = []
    private(set) var microphones: [AVCaptureDevice] = []
    private(set) var permissionDenied = false

    private(set) var mode: Mode = .display
    /// What will be recorded when the button is pressed.
    private(set) var target: CaptureTarget?
    /// What that target is called, for the bar to show.
    private(set) var targetLabel = ""
    /// The line under it: what will actually be captured, and how fast.
    private(set) var targetDetail = ""

    /// Called once an area has been dragged out, so the target overlay can come up after
    /// the area picker rather than underneath it.
    var onAreaPicked: () -> Void = {}

    var windowSearch = ""

    private let content = ShareableContentStore()
    private let settings: StudioSettings
    private let studio: StudioService
    private var areaPicker: AreaSelectionController?
    private static let log = Logger(subsystem: "com.stackrover.klik.studio", category: "recorder")

    init(settings: StudioSettings, studio: StudioService) {
        self.settings = settings
        self.studio = studio
    }

    // MARK: - Choosing

    var canRecord: Bool { target != nil && !studio.session.state.isBusy }

    var cameraLabel: String { settings.recordsCamera ? "Camera" : "No camera" }

    var microphoneLabel: String {
        guard settings.recordsMicrophone else { return "No microphone" }
        if settings.microphoneID.isEmpty { return "Microphone" }
        return microphones.first { $0.uniqueID == settings.microphoneID }?.localizedName ?? "Microphone"
    }

    /// Picks a mode, and with it the obvious target for that mode.
    func choose(_ mode: Mode) {
        self.mode = mode
        switch mode {
        case .display:
            select(displays.first { $0.target.displayID == Self.displayUnderPointer() } ?? displays.first)
        case .window:
            // A window has to be named; the bar's menu does that.
            target = nil
            targetLabel = ""
        case .area:
            pickArea()
        case .device:
            break
        }
    }

    func select(_ source: Source?) {
        guard let source else {
            target = nil
            targetLabel = ""
            targetDetail = ""
            return
        }
        target = source.target
        targetLabel = source.title
        targetDetail = Self.detail(for: source)
        switch source.target {
        case .display: mode = .display
        case .window: mode = .window
        case .area: mode = .area
        }
    }

    /// Drags out part of the screen, then keeps it as the target.
    func pickArea() {
        let controller = AreaSelectionController()
        areaPicker = controller
        controller.begin { [weak self] selection in
            guard let self else { return }
            areaPicker = nil
            guard let selection else {
                // Cancelled: fall back to whatever was chosen before rather than leaving
                // the bar armed with nothing.
                if target == nil { choose(.display) }
                return
            }
            mode = .area
            target = .area(display: selection.displayID, rect: selection.rect)
            targetLabel = "Selected area"
            targetDetail = Self.detail(width: Int(selection.rect.width),
                                       height: Int(selection.rect.height),
                                       displayID: selection.displayID)
            onAreaPicked()
        }
    }

    /// "1512 × 982 · 120 FPS" — the two numbers anyone checks before a take.
    private static func detail(for source: Source) -> String {
        switch source.target {
        case .display(let id):
            let size = source.subtitle.replacingOccurrences(of: " ", with: "")
            return [size.isEmpty ? nil : source.subtitle, frameRate(of: id)]
                .compactMap { $0 }.joined(separator: "  ·  ")
        default:
            return source.subtitle
        }
    }

    private static func detail(width: Int, height: Int, displayID: CGDirectDisplayID) -> String {
        ["\(width) × \(height)", frameRate(of: displayID)].compactMap { $0 }.joined(separator: "  ·  ")
    }

    /// Read from the screen rather than assumed: a 120 Hz laptop panel and a 60 Hz
    /// external are both ordinary, and saying the wrong one is worse than saying nothing.
    private static func frameRate(of displayID: CGDirectDisplayID) -> String? {
        let screen = NSScreen.screens.first { screenID(of: $0) == displayID }
        guard let rate = screen?.maximumFramesPerSecond, rate > 0 else { return nil }
        return "\(rate) FPS"
    }

    private static func screenID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }

    func record() {
        guard let target else { return }
        studio.record(target: target)
    }

    // MARK: - Sources

    /// Reads what is on screen.
    ///
    /// Also the permission check: ScreenCaptureKit answers that question with an error
    /// when the grant is missing, which is the only honest way to ask it.
    func refreshSources() async {
        do {
            let shareable = try await content.content()
            permissionDenied = false

            displays = shareable.displays.enumerated().map { index, display in
                Source(id: "display-\(display.displayID)",
                       title: Self.name(for: display, index: index),
                       subtitle: "\(display.width) × \(display.height)",
                       target: .display(display.displayID))
            }

            // Windows worth offering: on screen, big enough to be a window rather than a
            // shadow or a tooltip, and not one of ours.
            windows = shareable.windows
                .filter { $0.isOnScreen && $0.frame.width > 120 && $0.frame.height > 80 }
                .filter { $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier }
                .sorted { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }
                .map { window in
                    Source(id: "window-\(window.windowID)",
                           title: window.owningApplication?.applicationName ?? "Window",
                           subtitle: window.title ?? "",
                           target: .window(window.windowID))
                }

            if target == nil, mode == .display { choose(.display) }
        } catch {
            permissionDenied = (error == .permissionDenied)
            displays = []
            windows = []
            Self.log.error("Couldn't read shareable content: \(error.localizedDescription ?? "unknown", privacy: .public)")
        }
        microphones = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                                      mediaType: .audio,
                                                      position: .unspecified).devices
    }

    var filteredWindows: [Source] {
        guard !windowSearch.isEmpty else { return windows }
        return windows.filter {
            $0.title.localizedCaseInsensitiveContains(windowSearch)
                || $0.subtitle.localizedCaseInsensitiveContains(windowSearch)
        }
    }

    /// Opens System Settings at the pane the user needs, because "grant permission" with
    /// no way to get there is not help.
    func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Recent recordings

    struct Recording: Identifiable, Hashable {
        let url: URL
        let name: String
        let recorded: Date
        let duration: Double

        var id: URL { url }
    }

    /// The library, newest first.
    ///
    /// Read from each manifest rather than from the file name, so a renamed package still
    /// says how long it is and when it was taken.
    func refreshRecents(limit: Int = 8) {
        let contents = (try? FileManager.default.contentsOfDirectory(at: settings.library,
                                                                     includingPropertiesForKeys: [.contentModificationDateKey],
                                                                     options: [.skipsHiddenFiles])) ?? []
        recents = contents
            .filter { $0.pathExtension == RecordingPackage.fileExtension }
            .compactMap { url in
                guard let manifest = try? RecordingPackage(url: url).readManifest() else { return nil }
                return Recording(url: url, name: manifest.name, recorded: manifest.createdAt, duration: manifest.duration)
            }
            .sorted { $0.recorded > $1.recorded }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Formatting

    static func elapsed(since start: Date, at now: Date = .now) -> String {
        length(now.timeIntervalSince(start))
    }

    static func length(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Displays

    private static func displayUnderPointer() -> CGDirectDisplayID {
        let location = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) } ?? NSScreen.main
        let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number.map { CGDirectDisplayID($0.uint32Value) } ?? CGMainDisplayID()
    }

    private static func name(for display: SCDisplay, index: Int) -> String {
        let screen = NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
        }
        return screen?.localizedName ?? (index == 0 ? "Main Display" : "Display \(index + 1)")
    }
}
