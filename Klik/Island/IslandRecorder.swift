import AddOnKit
import AppKit
import Observation
import ScreenCaptureKit

/// What the island offers to record, and what it hands to the add-on.
///
/// Recording used to begin by launching Klik Studio and letting *it* ask which screen or
/// window — which meant a second app taking over the display to answer a question Klik was
/// already in the middle of. The island is where every other Klik thing is chosen, and the
/// bridge has always been able to carry an explicit target, so the question is asked here
/// and the add-on is told the answer rather than asked to find it.
///
/// Klik enumerates the targets itself through its own `ScreenCaptureService`. That is not a
/// duplicate of the add-on's list: the two apps hold separate screen-recording grants, and
/// a list fetched across the bridge would be a list of windows that had moved by the time
/// it arrived.
@MainActor
@Observable
final class IslandRecorder {
    struct Target: Identifiable, Equatable {
        let id: String
        let title: String
        let subtitle: String
        let request: RecordingRequest.Target
        var thumbnail: CGImage?
        /// A window on a Space you are not looking at. Recording it switches to it, which
        /// is worth saying before rather than after.
        var isElsewhere = false

        static func == (a: Target, b: Target) -> Bool { a.id == b.id && (a.thumbnail == nil) == (b.thumbnail == nil) }
    }

    private(set) var displays: [Target] = []
    private(set) var windows: [Target] = []
    private(set) var isLoading = false
    var search = ""
    var selected: Target?

    /// What the island does with the choice. Set by the controller, which owns the client.
    var onRecord: (RecordingRequest.Target) -> Void = { _ in }
    /// What it says about the sound and camera the take will use, read from the same
    /// preferences the request is built from — so the line cannot disagree with the file.
    var summary = ""

    private let capture = ScreenCaptureService()
    private var thumbnails: Task<Void, Never>?

    var filteredWindows: [Target] {
        guard !search.isEmpty else { return windows }
        return windows.filter {
            $0.title.localizedCaseInsensitiveContains(search)
                || $0.subtitle.localizedCaseInsensitiveContains(search)
        }
    }

    /// Reads what is on the machine now. Called each time the island opens on recording,
    /// because windows are exactly the thing that has changed since last time.
    func refresh() async {
        isLoading = displays.isEmpty && windows.isEmpty
        defer { isLoading = false }
        guard let content = try? await capture.shareableContent() else { return }

        displays = content.displays.enumerated().map { index, display in
            Target(id: "display-\(display.displayID)",
                   title: content.displays.count > 1 ? "Display \(index + 1)" : "This display",
                   subtitle: "\(display.width) × \(display.height)",
                   request: .display(display.displayID))
        }

        // The same rules the add-on's own list learned the hard way: a window worth
        // offering is big enough to be a window, on the ordinary layer, named, and not
        // one of Klik's own.
        let ours: Set<String> = [Bundle.main.bundleIdentifier ?? "", AddOnBridge.studioBundleID]
        var seen: Set<String> = []
        let offered = content.windows
            .filter { $0.frame.width > 120 && $0.frame.height > 80 }
            .filter { $0.windowLayer == 0 }
            .filter { !ours.contains($0.owningApplication?.bundleIdentifier ?? "") }
            .filter { !($0.title ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
            .filter { window in
                let key = "\(window.owningApplication?.applicationName ?? "")|\(window.title ?? "")"
                return seen.insert(key).inserted
            }

        windows = offered.map { window in
            Target(id: "window-\(window.windowID)",
                   title: window.owningApplication?.applicationName ?? "Window",
                   subtitle: window.title ?? "",
                   request: .window(window.windowID),
                   isElsewhere: !window.isOnScreen)
        }

        if selected == nil { selected = displays.first }
        load(thumbnailsFor: offered)
    }

    /// A picture of each window, arriving after the list rather than holding it up.
    private func load(thumbnailsFor windows: [SCWindow]) {
        thumbnails?.cancel()
        let ids = windows.prefix(18).map(\.windowID)
        thumbnails = Task { [weak self] in
            for id in ids {
                guard !Task.isCancelled else { return }
                guard let image = await Self.thumbnail(of: id) else { continue }
                guard !Task.isCancelled, let self else { return }
                if let index = self.windows.firstIndex(where: { $0.id == "window-\(id)" }) {
                    self.windows[index].thumbnail = image
                }
            }
        }
    }

    /// One window's picture, taken with the same framework the recording uses — so a
    /// window that cannot be photographed is exactly the one that would record black.
    private nonisolated static func thumbnail(of id: CGWindowID) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              let window = content.windows.first(where: { $0.windowID == id })
        else { return nil }

        let scale = min(1, 320 / max(window.frame.width, 1))
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(window.frame.width * scale))
        configuration.height = max(1, Int(window.frame.height * scale))
        configuration.scalesToFit = true
        configuration.showsCursor = false
        configuration.captureResolution = .nominal

        return try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window),
            configuration: configuration)
    }

    func record() {
        guard let selected else { return }
        onRecord(selected.request)
    }

    func cancel() {
        thumbnails?.cancel()
        thumbnails = nil
    }
}
