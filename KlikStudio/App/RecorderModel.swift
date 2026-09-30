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
        /// Where the window is, in display coordinates with the origin at the top left —
        /// `SCWindow.frame`'s convention, kept rather than converted so the one place that
        /// draws it does the flip once. `.zero` for a display or an area.
        var frame: CGRect = .zero
        /// Front to back, as the window server sees it. Kept because the list is sorted by
        /// application name for reading, and pointing at overlapping windows needs the
        /// order they are actually stacked in.
        var depth: Int = 0
        /// Whether this window is on a Space you are looking at. A full-screen app on
        /// another Space is listed but cannot be pointed at.
        var isOnScreen: Bool = true
        /// Whether the system will let a recording see it. A private browser window says
        /// no, and captures as a black rectangle — see `WindowSharing`.
        var isShareable: Bool = true
        /// The application that owns the window, so the picker can show its icon — the
        /// fastest way to find one window among thirty. Zero for a display or an area.
        var processID: pid_t = 0
    }

    private(set) var displays: [Source] = []
    private(set) var windows: [Source] = []
    private(set) var recents: [Recording] = []
    private(set) var microphones: [AVCaptureDevice] = []
    /// The cameras this Mac can see. Listed, never opened — see `WebcamRecorder`.
    private(set) var cameras: [AVCaptureDevice] = []
    private(set) var permissionDenied = false
    /// Said out loud when the camera has been turned on but the grant is refused, so the
    /// bar can say so before a take fails instead of after.
    private(set) var cameraDenied = false

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
    private var thumbnailTask: Task<Void, Never>?
    /// A picture of each window, by id, filled in after the list itself.
    private(set) var thumbnails: [CGWindowID: CGImage] = [:]
    private static let log = Logger(subsystem: "com.stackrover.klik.studio", category: "recorder")

    init(settings: StudioSettings, studio: StudioService) {
        self.settings = settings
        self.studio = studio
    }

    // MARK: - Choosing

    var canRecord: Bool { target != nil && !studio.session.state.isBusy }

    /// What the camera chip says. The device's own name when one has been chosen, because
    /// "Camera" on a Mac with a Studio Display and a Continuity iPhone says nothing.
    var cameraLabel: String {
        guard settings.recordsCamera else { return "No camera" }
        if cameraDenied { return "Camera not allowed" }
        if settings.cameraID.isEmpty { return "Camera" }
        return cameras.first { $0.uniqueID == settings.cameraID }?.localizedName ?? "Camera"
    }

    /// Turns the camera on or off for the takes that follow.
    ///
    /// Asking for permission happens *here*, when the user has just said they want the
    /// camera — that is the honest moment for the dialog, and it means a refusal is known
    /// before a take rather than three seconds into one. Turning it *off* asks nothing and
    /// opens nothing.
    ///
    /// Note what this does not do: it does not start a capture session. The one path that
    /// shows the user what their camera sees is the preview beside the bar
    /// (`CameraPreviewPanel`), and it opens the camera only once the grant exists and only
    /// while the bar is on screen — so the indicator lights for a picture the user can see,
    /// never for a switch flicked in a settings bar.
    func setCamera(_ on: Bool) {
        guard on else {
            settings.recordsCamera = false
            cameraDenied = false
            return
        }
        settings.recordsCamera = true
        guard !WebcamRecorder.isAuthorized else {
            cameraDenied = false
            return
        }
        // Already refused for good: the system will not show the dialog again, so say so
        // rather than appearing to ask.
        guard !WebcamRecorder.isDenied else {
            cameraDenied = true
            return
        }
        Task {
            let granted = await WebcamRecorder.requestAccess()
            cameraDenied = !granted
            // Left on when refused, deliberately: the switch reflects what was asked for,
            // and the chip now says the camera is not allowed with somewhere to go about
            // it. Silently flicking it back off would look like the click was lost.
            cameras = WebcamRecorder.devices
        }
    }

    var microphoneLabel: String {
        guard settings.recordsMicrophone else { return "No microphone" }
        let chosen = settings.microphoneIDs
        if chosen.isEmpty { return "Microphone" }
        // Named while there is one to name, counted once there are several: three device
        // names run off the end of the chip, and "3 microphones" is the fact that matters
        // there — that this take will arrive with three lanes in it.
        if chosen.count > 1 { return "\(chosen.count) microphones" }
        return microphones.first { $0.uniqueID == chosen[0] }?.localizedName ?? "Microphone"
    }

    /// Picks a mode, and with it the obvious target for that mode.
    func choose(_ mode: Mode) {
        self.mode = mode
        switch mode {
        case .display:
            select(displays.first { $0.target.displayID == Self.displayUnderPointer() } ?? displays.first)
        case .window:
            // Straight to the list. Pointing at the window itself was the obvious idea and
            // it was the wrong one: the dim-and-highlight put a frame on screen that the
            // user had not asked for and could not explain, and the thing it most often
            // highlighted was whatever system window happened to span the display. A grid
            // of pictures of the windows answers "which one" without taking the screen.
            target = nil
            targetLabel = ""
        case .area:
            pickArea()
        case .device:
            break
        }
    }

    func select(_ source: Source?) {
        // A note about resizing one window says nothing about the next one picked.
        resizeNote = nil
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

    // MARK: - Resizing the window

    /// What the last resize did, in a sentence for the picker — or that it could not.
    struct ResizeNote: Equatable {
        let text: String
        /// Whether it worked; a note that did not is drawn as a warning.
        let isGood: Bool
        /// Whether what is missing is the Accessibility grant, so the note offers to ask.
        let needsAccess: Bool
    }

    private(set) var resizeNote: ResizeNote?

    /// The chosen window, when the choice is a window that can be sized: one on a Space you
    /// are looking at, since Accessibility cannot reach a window on another.
    var resizableWindow: Source? {
        guard case .window = target,
              let source = windows.first(where: { $0.target == target }),
              source.isOnScreen, source.processID > 0 else { return nil }
        return source
    }

    /// Puts the chosen window at a preset size before it is recorded.
    ///
    /// The window is the person's and so is the decision: this runs only from the picker's
    /// menu, never on its own, and says what happened either way — including that the app
    /// kept a size of its own, which some do, and that the grant is missing, which the
    /// note then offers to fix. The list is read again afterwards, so the tile's picture
    /// and the size under the name are the window's new ones.
    func resizeWindow(to preset: WindowSizePreset) {
        guard let source = resizableWindow else { return }
        let outcome = WindowResizer.resize(processID: source.processID, windowFrame: source.frame,
                                           title: source.subtitle.isEmpty ? nil : source.subtitle, to: preset)
        resizeNote = Self.note(for: outcome)
        Task { await refreshSources() }
    }

    /// Asks macOS for the Accessibility grant, and opens the list it lives in: under App
    /// Sandbox the system may add nothing by itself, and the person has to add the app.
    func requestAccessibility() {
        if !AccessibilityAccess.request() { AccessibilityAccess.openSystemSettings() }
    }

    private static func note(for outcome: WindowResizer.Outcome) -> ResizeNote {
        func size(_ pixels: CGSize) -> String { "\(Int(pixels.width)) × \(Int(pixels.height))" }
        switch outcome {
        case .resized(_, let pixels, let isShrunk):
            return ResizeNote(text: isShrunk
                                  ? "Made smaller to fit the screen, same shape: it will record at \(size(pixels))."
                                  : "Resized. It will record at \(size(pixels)).",
                              isGood: true, needsAccess: false)
        case .keptItsOwnSize(_, let pixels):
            return ResizeNote(text: "The app kept this window at \(size(pixels)) — it has a smallest or largest size of its own.",
                              isGood: false, needsAccess: false)
        case .needsAccess:
            return ResizeNote(text: "Resizing another app's window needs Accessibility access for Klik Studio.",
                              isGood: false, needsAccess: true)
        case .windowNotFound:
            return ResizeNote(text: "Couldn't find that window to resize. It may have moved or closed — choose it again.",
                              isGood: false, needsAccess: false)
        case .failed:
            return ResizeNote(text: "The app didn't let its window be resized.",
                              isGood: false, needsAccess: false)
        }
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
            // Which windows would record as a black rectangle. Read once per refresh
            // rather than per window: it is one call to the window server either way.
            let refusing = WindowSharing.refusing()

            // Worth offering: big enough to be a window rather than a shadow or a
            // tooltip, on the normal window layer, and not one of ours. Deliberately *not*
            // filtered on `isOnScreen` any more — that is what hid every full-screen app,
            // which lives on a Space of its own and is therefore never "on screen" while
            // you are looking at the bar.
            let offered = shareable.windows
                .filter { $0.frame.width > 120 && $0.frame.height > 80 }
                .filter { $0.windowLayer == 0 }
                // Klik's windows as well as the recorder's own. The store has always
                // known both — it excludes them from what a *display* capture sees — and
                // the list was asking a narrower question, so Klik's editors and panels
                // turned up as a dozen rows called "Klik" for a recording nobody wants.
                .filter { window in
                    guard let bundle = window.owningApplication?.bundleIdentifier else { return true }
                    return !content.excludedBundleIDs.contains(bundle)
                }
                // A window nobody can name is a window nobody asked for. Opening the list
                // to every Space brought the machinery with it — autofill panels, the
                // login window, helper processes — and they are all alike in this: the
                // application has a name and the *window* does not. A real window you are
                // not looking at still has a title; these never do.
                //
                // On-screen windows are kept regardless, because a genuinely untitled
                // window you can see and point at is a window you can mean.
                .filter { $0.isOnScreen || !($0.title ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
                .filter { Self.isOfferable($0) }

            // One row per window, not per copy of a name. Several windows of one
            // application showing the same document are the same choice as far as anyone
            // reading the list is concerned, and five rows saying "Google Chrome" are five
            // ways to pick wrong.
            var seen: Set<String> = []
            windows = offered
                .filter { window in
                    let key = "\(window.owningApplication?.applicationName ?? "")|\(window.title ?? "")"
                    return seen.insert(key).inserted
                }
                .enumerated()
                .map { depth, window in
                    Source(id: "window-\(window.windowID)",
                           title: window.owningApplication?.applicationName ?? "Window",
                           subtitle: window.title ?? "",
                           target: .window(window.windowID),
                           frame: window.frame,
                           depth: depth,
                           isOnScreen: window.isOnScreen,
                           isShareable: !refusing.contains(window.windowID),
                           processID: window.owningApplication?.processID ?? 0)
                }
                .sorted {
                    // On-screen first, then by application, so the list reads as "what you
                    // can point at" followed by "what you would have to switch to".
                    if $0.isOnScreen != $1.isOnScreen { return $0.isOnScreen }
                    return $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }

            // Pictures of the windows, once the list of them is settled. Off the main
            // actor and after the fact: the bar must not wait on a dozen captures to show
            // a list it already has, and a tile that gains its picture a moment later is
            // the ordinary behaviour of every file browser on the machine.
            loadThumbnails(for: windows.compactMap {
                if case .window(let id) = $0.target { return id } else { return nil }
            })

            if target == nil, mode == .display { choose(.display) }
        } catch {
            permissionDenied = (error == .permissionDenied)
            displays = []
            windows = []
            Self.log.error("Couldn't read shareable content: \(error.localizedDescription, privacy: .public)")
        }
        // The recorder's own list, not a second query that happens to agree with it today:
        // a device offered here that `RecordingSession` cannot resolve when the take starts
        // is a microphone the user ticked and did not get.
        microphones = MicrophoneRecorder.devices
        // Discovering a camera is not opening one: this reads the system's list and no
        // indicator lights. The list is refreshed alongside the windows because both change
        // for the same reasons — a lid closed, a cable plugged in.
        cameras = WebcamRecorder.devices
        // Re-checked rather than remembered: the grant can be given in System Settings
        // while the bar is open, and a chip still saying "not allowed" after that is wrong.
        if settings.recordsCamera { cameraDenied = WebcamRecorder.isDenied }
    }

    /// Whether a window is one of the machine's own rather than one of the user's.
    ///
    /// Named by bundle identifier rather than by how its title reads, because the title is
    /// the thing that varies: the login window and the autofill panels are the same
    /// processes on every Mac, and matching on their names would be matching on a
    /// translation.
    private static func isOfferable(_ window: SCWindow) -> Bool {
        guard let bundle = window.owningApplication?.bundleIdentifier else { return true }
        if Self.systemBundleIDs.contains(bundle) { return false }
        // Autofill panels are vended by a helper whose identifier is the host application's
        // with a suffix, and there is no honest general rule for that — so this matches the
        // one shape they all share and says so.
        return !bundle.hasSuffix(".AutoFillPanelService")
    }

    private static let systemBundleIDs: Set<String> = [
        "com.apple.loginwindow",
        "com.apple.WindowManager",
        "com.apple.notificationcenterui",
        "com.apple.controlcenter",
        "com.apple.dock",
        "com.apple.systemuiserver",
        "com.apple.wallpaper.agent",
    ]

    /// A picture per window, arriving as each one is taken.
    private func loadThumbnails(for ids: [CGWindowID]) {
        thumbnailTask?.cancel()
        // A hard ceiling: the list shows a screenful, and photographing forty windows to
        // fill twelve tiles is work nobody sees.
        let subjects = Array(ids.prefix(24))
        thumbnailTask = Task { [weak self] in
            await WindowThumbnail.images(of: subjects) { id, image in
                await MainActor.run { self?.thumbnails[id] = image }
            }
        }
    }

    /// The picture of a window, once one has been taken.
    func thumbnail(for source: Source) -> CGImage? {
        guard case .window(let id) = source.target else { return nil }
        return thumbnails[id]
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
        open(privacyPane: "Privacy_ScreenCapture")
    }

    /// The other pane a recording can be refused by. A microphone denial pointed at the
    /// screen-recording list would send the user to a switch that is already on.
    func openMicrophoneSettings() {
        open(privacyPane: "Privacy_Microphone")
    }

    /// The third pane a recording can be refused by. Camera and microphone are separate
    /// lists, so a camera denial must not send anybody to the microphone one.
    func openCameraSettings() {
        open(privacyPane: "Privacy_Camera")
    }

    private func open(privacyPane pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
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
