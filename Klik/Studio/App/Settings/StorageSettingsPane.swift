import AppKit
import RecordKit
import SwiftUI

/// How much room the recordings take, the caches that can go, and starting over.
struct StorageSettingsPane: View {
    @Environment(StudioSettings.self) private var settings
    @Environment(StudioService.self) private var studio
    @State private var usage: LibraryUsage?
    @State private var isClearing = false
    @State private var clearedBytes: Int64?
    @State private var confirmsReset = false
    @State private var didReset = false

    var body: some View {
        StudioSettingsPane(.storage) {
            DriveSettingsGroup()

            StudioSettingsGroup("Space used") {
                StudioSettingsRow("Recordings",
                            subtitle: libraryLine,
                            symbol: "film.stack.fill", tint: .orange) {
                    HStack(spacing: 8) {
                        Button("Open Recordings") { StudioController.shared?.showLibrary() }
                        RevealButton(help: "Show in Finder") { revealLibrary() }
                    }
                }
                StudioSettingsRow("Free on this disk", subtitle: diskLine, symbol: "internaldrive.fill", tint: .gray) {
                    if let usage, let total = usage.volumeTotal, total > 0, let free = usage.volumeFree {
                        ProgressView(value: Double(total - free), total: Double(total))
                            .frame(width: 120)
                            .accessibilityLabel("Disk used")
                    }
                }
            }

            StudioSettingsGroup("Caches") {
                StudioSettingsRow("Cached previews", subtitle: cacheLine, symbol: "square.stack.3d.up.fill", tint: .teal) {
                    HStack(spacing: 8) {
                        if isClearing { ProgressView().controlSize(.small) }
                        Button("Clear Caches") { clearCaches() }
                            .disabled(isClearing || (usage?.derivedBytes ?? 0) == 0)
                    }
                }
            }

            StudioSettingsGroup("Reset") {
                StudioSettingsRow("Reset recording and video settings", subtitle: didReset ? "Done. Recording and the video editor are back to their defaults." : "Klik's other settings are kept.",
                            symbol: "arrow.counterclockwise", tint: .red) {
                    Button("Reset…") { confirmsReset = true }
                }
            }
        }
        .task(id: settings.library) { await measure() }
        .confirmationDialog("Reset recording and video settings?", isPresented: $confirmsReset) {
            Button("Reset", role: .destructive) {
                settings.resetToDefaults()
                didReset = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every recording and video editor preference goes back to its default. Recordings, looks, speaker notes and Klik's other settings are kept. This can't be undone.")
        }
    }

    // MARK: - What the rows say

    private var libraryLine: String {
        guard let usage else { return "Measuring…" }
        let count = usage.recordingCount == 1 ? "1 recording" : "\(usage.recordingCount) recordings"
        return "\(count) · \(Self.bytes(usage.libraryBytes))"
    }

    private var diskLine: String {
        guard let usage else { return "Measuring…" }
        guard let free = usage.volumeFree else { return "Unknown" }
        if let total = usage.volumeTotal { return "\(Self.bytes(free)) of \(Self.bytes(total))" }
        return Self.bytes(free)
    }

    private var cacheLine: String {
        if let clearedBytes { return "Cleared \(Self.bytes(clearedBytes))." }
        guard let usage else { return "Measuring…" }
        return usage.derivedBytes == 0 ? "Nothing cached." : "\(Self.bytes(usage.derivedBytes)) across your recordings."
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    // MARK: - Doing it

    private func measure() async {
        let folder = settings.library
        usage = await Task.detached(priority: .utility) { LibraryUsage.measure(folder) }.value
    }

    private func clearCaches() {
        let folder = settings.library
        // Not the recording on screen, nor one being written: their caches are in use
        // this minute, and taking a waveform out from under a timeline that is drawing it
        // is a flicker at best.
        let busy = Set([StudioController.shared?.editors.front?.packageURL, studio.session.packageURL]
            .compactMap { $0?.standardizedFileURL })
        isClearing = true
        Task {
            let freed = await Task.detached(priority: .utility) {
                LibraryUsage.clearCaches(in: folder, sparing: busy)
            }.value
            clearedBytes = freed
            isClearing = false
            await measure()
        }
    }

    private func revealLibrary() {
        try? FileManager.default.createDirectory(at: settings.library, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([settings.library])
    }
}

/// What the recordings folder holds, and the room around it. Measured off the main actor:
/// it walks every file in every recording.
nonisolated struct LibraryUsage: Sendable {
    var recordingCount = 0
    var libraryBytes: Int64 = 0
    /// Of which regenerable — every recording's `derived/` folder.
    var derivedBytes: Int64 = 0
    var volumeFree: Int64?
    var volumeTotal: Int64?

    static func measure(_ folder: URL) -> LibraryUsage {
        var usage = LibraryUsage()
        let entries = RecordingLibrary(folder: folder).entries()
        usage.recordingCount = entries.count
        usage.libraryBytes = entries.reduce(0) { $0 + $1.byteCount }
        usage.derivedBytes = entries.reduce(0) { $0 + RecordingLibrary.size(of: RecordingPackage(url: $1.url).derivedFolder) }
        // The folder may not exist before the first recording; the disk it would be on
        // is its parent's.
        let probe = FileManager.default.fileExists(atPath: folder.path(percentEncoded: false))
            ? folder : folder.deletingLastPathComponent()
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        usage.volumeFree = values?.volumeAvailableCapacityForImportantUsage
        usage.volumeTotal = values?.volumeTotalCapacity.map(Int64.init)
        return usage
    }

    /// Deletes every recording's `derived/` folder but those in `sparing`, and says how
    /// much that freed.
    ///
    /// `derived/` and nothing else: `RecordingPackage` defines it as the regenerable part
    /// of a package — peaks, filmstrip tiles, the poster — and never part of whether a
    /// document is dirty. Removed rather than trashed, for the same reason: it is not the
    /// user's, and a Trash full of waveform caches would be one they had to empty.
    static func clearCaches(in folder: URL, sparing busy: Set<URL>) -> Int64 {
        var freed: Int64 = 0
        for entry in RecordingLibrary(folder: folder).entries() where !busy.contains(entry.url.standardizedFileURL) {
            let derived = RecordingPackage(url: entry.url).derivedFolder
            guard FileManager.default.fileExists(atPath: derived.path(percentEncoded: false)) else { continue }
            let size = RecordingLibrary.size(of: derived)
            if (try? FileManager.default.removeItem(at: derived)) != nil { freed += size }
        }
        return freed
    }
}
