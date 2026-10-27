import AppKit
import CoreWLAN
import Network
import SwiftUI

/// A passing notice in the island: the network changing, a drive mounting or
/// ejecting, a download finishing.
struct NoticeHUD: Equatable {
    enum Kind: Equatable {
        case offline, online, vpnOn, vpnOff
        case driveMounted, driveEjected
        case downloaded
    }

    let kind: Kind
    let title: String
    let subtitle: String
    /// The file a download HUD reveals when clicked; a drive's volume.
    var url: URL?
    /// 0…1 of a drive used, for its bar.
    var used: Double?

    var symbol: String {
        switch kind {
        case .offline: "wifi.slash"
        case .online: subtitle == "Ethernet" ? "cable.connector" : "wifi"
        case .vpnOn: "lock.shield.fill"
        case .vpnOff: "lock.open.fill"
        case .driveMounted: url.map { $0.pathExtension == "dmg" } == true ? "opticaldiscdrive.fill" : "externaldrive.fill"
        case .driveEjected: "eject.fill"
        case .downloaded: "arrow.down.circle.fill"
        }
    }

    var tint: Color {
        switch kind {
        case .offline: Color(red: 1.0, green: 0.36, blue: 0.32)
        case .online: Color(red: 0.32, green: 0.62, blue: 1.0)
        case .vpnOn: Color(red: 0.36, green: 0.85, blue: 0.45)
        case .vpnOff, .driveEjected: Color(white: 0.4)
        case .driveMounted: Color(red: 1.0, green: 0.6, blue: 0.22)
        case .downloaded: Color(red: 0.32, green: 0.62, blue: 1.0)
        }
    }

    /// Clicking it does something (reveals the download).
    var isClickable: Bool { kind == .downloaded && url != nil }
}

/// Watches the network, mounted volumes and the Downloads folder, and calls back
/// with what the island should show.
@MainActor
final class NoticeMonitor {
    private let onNotice: (NoticeHUD) -> Void
    private var observers: [NSObjectProtocol] = []

    init(onNotice: @escaping (NoticeHUD) -> Void) {
        self.onNotice = onNotice
        startNetwork()
        startDrives()
        startDownloads()
    }

    func stop() {
        pathMonitor.cancel()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        downloadsSource?.cancel()
        downloadsSource = nil
    }

    // MARK: - Network

    private let pathMonitor = NWPathMonitor()
    private struct NetworkState: Equatable {
        let online: Bool
        let name: String
        let vpn: Bool
    }
    private var network: NetworkState?
    private var networkTask: Task<Void, Never>?

    private func startNetwork() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let first = path.availableInterfaces.first
            let vpn = online && ["utun", "ipsec", "ppp"].contains { first?.name.hasPrefix($0) == true }
            let wired = path.usesInterfaceType(.wiredEthernet)
            Task { @MainActor in self?.pathChanged(online: online, wired: wired, vpn: vpn) }
        }
        pathMonitor.start(queue: .main)
    }

    /// Settles for a second first: a path flaps as it changes.
    private func pathChanged(online: Bool, wired: Bool, vpn: Bool) {
        networkTask?.cancel()
        networkTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            let name = wired ? "Ethernet" : (CWWiFiClient.shared().interface()?.ssid() ?? "Wi-Fi")
            let now = NetworkState(online: online, name: name, vpn: vpn)
            defer { network = now }
            guard let before = network, before != now else { return }
            if before.online != now.online {
                onNotice(now.online
                         ? NoticeHUD(kind: .online, title: "Back online", subtitle: now.name)
                         : NoticeHUD(kind: .offline, title: "No internet", subtitle: "Check your Wi-Fi or cable"))
            } else if before.vpn != now.vpn {
                onNotice(NoticeHUD(kind: now.vpn ? .vpnOn : .vpnOff, title: now.vpn ? "VPN connected" : "VPN disconnected", subtitle: now.name))
            } else if now.online, before.name != now.name {
                onNotice(NoticeHUD(kind: .online, title: "Connected", subtitle: now.name))
            }
        }
    }

    // MARK: - Drives

    private func startDrives() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] note in
            let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            let name = note.userInfo?[NSWorkspace.localizedVolumeNameUserInfoKey] as? String
            MainActor.assumeIsolated { self?.mounted(url, name: name) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] note in
            let name = note.userInfo?[NSWorkspace.localizedVolumeNameUserInfoKey] as? String ?? "The drive"
            MainActor.assumeIsolated {
                self?.onNotice(NoticeHUD(kind: .driveEjected, title: "\(name) ejected", subtitle: "Safe to unplug"))
            }
        })
    }

    private func mounted(_ url: URL?, name: String?) {
        guard let url else { return }
        let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsInternalKey])
        // The Mac's own volumes (a snapshot, Recovery) aren't news.
        if values?.volumeIsInternal == true { return }
        let name = name ?? url.lastPathComponent
        var subtitle = "Connected"
        var used: Double?
        if let total = values?.volumeTotalCapacity, let free = values?.volumeAvailableCapacity, total > 0 {
            let format = ByteCountFormatter()
            format.countStyle = .file
            subtitle = "\(format.string(fromByteCount: Int64(free))) free of \(format.string(fromByteCount: Int64(total)))"
            used = 1 - Double(free) / Double(total)
        }
        onNotice(NoticeHUD(kind: .driveMounted, title: name, subtitle: subtitle, url: url, used: used))
    }

    // MARK: - Downloads

    private var downloadsSource: DispatchSourceFileSystemObject?
    private var knownDownloads: Set<String> = []
    private var downloadsFolder: URL? {
        // The real Downloads (the sandbox's own would be inside the container).
        guard let record = getpwuid(getuid()), let directory = record.pointee.pw_dir else { return nil }
        let home = URL(fileURLWithPath: String(cString: directory))
        return home.appendingPathComponent("Downloads", isDirectory: true)
    }

    /// Still being written: Safari's bundle, Chrome's and Firefox's partial files.
    private static let partial = ["download", "crdownload", "part", "partial", "opdownload"]

    private func startDownloads() {
        guard let folder = downloadsFolder else { return }
        knownDownloads = Set(Self.names(in: folder))
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.downloadsChanged(folder) } }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        downloadsSource = source
    }

    private func downloadsChanged(_ folder: URL) {
        let now = Set(Self.names(in: folder))
        let new = now.subtracting(knownDownloads).filter { name in
            !name.hasPrefix(".") && !Self.partial.contains((name as NSString).pathExtension.lowercased())
        }
        knownDownloads = now
        for name in new.sorted() {
            let url = folder.appendingPathComponent(name)
            // A moment to be sure it is finished, and still there.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }
                let subtitle = size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) + " · Click to show" } ?? "Click to show in Finder"
                self?.onNotice(NoticeHUD(kind: .downloaded, title: name, subtitle: subtitle, url: url))
            }
        }
    }

    private static func names(in folder: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    }
}

/// A notice in the island: its object (a bead for the network and drives, the file
/// itself for a download), what happened, and a drive's fill.
struct NoticeRow: View {
    let notice: NoticeHUD
    @State private var shown = false
    @State private var burst = false

    var body: some View {
        HStack(spacing: 13) {
            art
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .truncationMode(.middle)
                Text(notice.subtitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                if let used = notice.used {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.14))
                            Capsule().fill(LinearGradient(colors: [notice.tint.opacity(0.7), notice.tint], startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(4, proxy.size.width * (shown ? used : 0)))
                        }
                    }
                    .frame(width: 150, height: 4)
                    .padding(.top, 4)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: 230, alignment: .leading)
            .offset(x: shown ? 0 : -6)
            .opacity(shown ? 1 : 0)
            Spacer(minLength: 12)
            if notice.isClickable {
                Icon("arrow.up.forward.square", size: 14, weight: .semibold)
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.08), in: Circle())
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 20)
        .fixedSize()
        .onAppear {
            let motion = !IslandView.reduceMotion
            withAnimation(motion ? .spring(response: 0.45, dampingFraction: 0.75).delay(0.1) : .easeOut(duration: 0.15)) { shown = true }
            if motion { withAnimation(.easeOut(duration: 0.7).delay(0.15)) { burst = true } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(notice.title), \(notice.subtitle)")
    }

    @ViewBuilder
    private var art: some View {
        if notice.kind == .downloaded, let url = notice.url {
            // The file itself, dropping in.
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
                .shadow(color: .black.opacity(0.45), radius: 3, y: 2)
                .offset(y: shown ? 0 : -10)
                .scaleEffect(shown ? 1 : 0.7)
        } else {
            ZStack {
                Circle()
                    .strokeBorder(notice.tint.opacity(0.7), lineWidth: 1.5)
                    .scaleEffect(burst ? 1.9 : 1)
                    .opacity(burst ? 0 : 0.8)
                GlossyDisc(symbol: notice.symbol, tint: notice.tint, size: 38,
                           lit: notice.kind != .vpnOff && notice.kind != .driveEjected)
                    .scaleEffect(shown ? 1 : 0.5)
            }
            .frame(width: 38, height: 38)
        }
    }
}
