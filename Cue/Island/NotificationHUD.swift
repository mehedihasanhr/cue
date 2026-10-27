import AppKit
import ApplicationServices
import os
import SwiftUI
import UniformTypeIdentifiers

/// A notification macOS showed as a banner, read off Notification Center.
struct BannerNotification: Identifiable, Equatable {
    let id: String
    let app: String
    let appURL: URL?
    let title: String
    let subtitle: String
    let body: String
    let date: Date

    var icon: NSImage {
        appURL.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .application)
    }

    /// The text as one would paste it.
    var text: String { [title, subtitle, body].filter { !$0.isEmpty }.joined(separator: "\n") }
}

/// The notifications macOS shows, as they arrive: read through Accessibility from
/// Notification Center's banners (each an `AXNotificationCenterBanner` with title,
/// subtitle and body), shown in the island, kept in a list while Cue runs, and,
/// if asked, the system's own banner closed. Nothing is written to disk.
@MainActor @Observable
final class NotificationFeed {
    private(set) var items: [BannerNotification] = []

    @ObservationIgnored var isEnabled: () -> Bool = { false }
    @ObservationIgnored var hidesBanners: () -> Bool = { false }
    @ObservationIgnored var onBanner: (BannerNotification) -> Void = { _ in }

    static let limit = 60
    private static let bundleID = "com.apple.notificationcenterui"
    /// More on screen at once than this is Notification Center's list opened, not banners.
    private static let bannerLimit = 3

    @ObservationIgnored private var observer: AXObserver?
    @ObservationIgnored private var pid: pid_t = 0
    @ObservationIgnored private var seen: [String] = []
    /// The banners still on screen, for Show.
    @ObservationIgnored private var live: [String: AXUIElement] = [:]
    @ObservationIgnored private var primed = false
    @ObservationIgnored private var scanQueued = false
    @ObservationIgnored private var retry: Timer?
    @ObservationIgnored private var launchObserver: NSObjectProtocol?

    func start() {
        attach()
        // Accessibility may be granted later, Notification Center relaunched: try again now and then.
        retry = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.attachIfNeeded() }
        }
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == "com.apple.notificationcenterui" else { return }
            MainActor.assumeIsolated { self?.attach() }
        }
    }

    func stop() {
        retry?.invalidate()
        retry = nil
        if let launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(launchObserver) }
        launchObserver = nil
        detach()
    }

    func open(_ item: BannerNotification) {
        if let element = live[item.id], let show = Self.action(of: element, named: "Show") ?? Self.action(of: element, named: "AXPress") {
            AXUIElementPerformAction(element, show as CFString)
        } else if let url = item.appURL {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func remove(_ item: BannerNotification) {
        items.removeAll { $0.id == item.id }
    }

    func clear() {
        items = []
    }

    // MARK: - Watching Notification Center

    private func attachIfNeeded() {
        let current = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first?.processIdentifier ?? 0
        if observer == nil || current != pid { attach() }
    }

    private func attach() {
        detach()
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else { return }
        pid = app.processIdentifier
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let feed = Unmanaged<NotificationFeed>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { feed.queueScan() }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
        let element = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXWindowCreatedNotification, kAXCreatedNotification, kAXLayoutChangedNotification] {
            AXObserverAddNotification(created, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
        primed = false
        scan()
        Log.app.info("Notifications: watching Notification Center (pid \(self.pid))")
    }

    private func detach() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        observer = nil
        live = [:]
    }

    private func queueScan() {
        guard !scanQueued else { return }
        scanQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.scanQueued = false
            self?.scan()
        }
    }

    /// Reads the banners on screen; new ones are shown and kept. While any window is
    /// up it looks again shortly, for a banner stacked onto one already showing.
    private func scan() {
        guard pid != 0 else { return }
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value)
        let windows = (value as? [AXUIElement]) ?? []
        let found = windows.flatMap { Self.banners(in: $0, depth: 0) }
        live = [:]
        var fresh: [(element: AXUIElement, id: String)] = []
        for element in found {
            let id = Self.string(element, kAXIdentifierAttribute) ?? Self.string(element, kAXDescriptionAttribute) ?? ""
            guard !id.isEmpty else { continue }
            live[id] = element
            if !seen.contains(id) { fresh.append((element, id)) }
        }
        seen.append(contentsOf: fresh.map(\.id))
        if seen.count > 400 { seen.removeFirst(seen.count - 400) }
        // The first look, or Notification Center's list opened (its window is the
        // screen's size either way, so it is told by how many there are): old news.
        let old = !primed || found.count > Self.bannerLimit
        primed = true
        if !old, isEnabled() {
            for banner in fresh {
                guard let item = Self.read(banner.element, id: banner.id) else { continue }
                items.insert(item, at: 0)
                if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
                if hidesBanners(), let close = Self.action(of: banner.element, named: "Close") {
                    AXUIElementPerformAction(banner.element, close as CFString)
                }
                Log.app.info("Notifications: one from \(item.app, privacy: .public)\(self.hidesBanners() ? ", banner closed" : "", privacy: .public)")
                onBanner(item)
            }
        }
        if !windows.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.queueScan() }
        }
    }

    // MARK: - Reading a banner

    private static func banners(in element: AXUIElement, depth: Int) -> [AXUIElement] {
        let subrole = string(element, kAXSubroleAttribute)
        if subrole == "AXNotificationCenterBanner" || subrole == "AXNotificationCenterAlert" { return [element] }
        guard depth < 8 else { return [] }
        return children(of: element).flatMap { banners(in: $0, depth: depth + 1) }
    }

    private static func read(_ banner: AXUIElement, id: String) -> BannerNotification? {
        var texts: [String: String] = [:]
        func collect(_ element: AXUIElement, depth: Int) {
            for child in children(of: element) {
                if let key = string(child, kAXIdentifierAttribute), ["title", "subtitle", "body"].contains(key), texts[key] == nil {
                    texts[key] = string(child, kAXValueAttribute) ?? ""
                }
                if depth < 3 { collect(child, depth: depth + 1) }
            }
        }
        collect(banner, depth: 0)
        let title = texts["title"] ?? "", subtitle = texts["subtitle"] ?? "", body = texts["body"] ?? ""
        guard !(title.isEmpty && body.isEmpty) else { return nil }
        // The description reads "App, title, subtitle, body".
        let description = string(banner, kAXDescriptionAttribute) ?? ""
        let rest = [title, subtitle, body].filter { !$0.isEmpty }.joined(separator: ", ")
        let app = description.hasSuffix(", " + rest)
            ? String(description.dropLast(rest.count + 2))
            : description.components(separatedBy: ", ").first ?? ""
        return BannerNotification(id: id, app: app, appURL: appURL(named: app), title: title, subtitle: subtitle, body: body, date: .now)
    }

    /// The app a banner came from, by its name: running, or in the usual folders.
    private static func appURL(named name: String) -> URL? {
        guard !name.isEmpty else { return nil }
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }), let url = running.bundleURL { return url }
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities"]
        return folders.map { URL(fileURLWithPath: $0).appendingPathComponent(name + ".app") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - Accessibility helpers

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        return (value as? [AXUIElement]) ?? []
    }

    /// A banner's actions are named "Name:Close\nTarget:…": the full name of the one called `name`.
    private static func action(of element: AXUIElement, named name: String) -> String? {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return nil }
        return ((names as? [String]) ?? []).first { $0 == name || $0.hasPrefix("Name:\(name)\n") }
    }
}

// MARK: - Views

/// A notification in the island: the app's icon, who and when, and what it says.
struct BannerRow: View {
    let banner: BannerNotification
    @State private var shown = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(nsImage: banner.icon)
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
                .shadow(color: .black.opacity(0.45), radius: 3, y: 2)
                .scaleEffect(shown ? 1 : 0.6)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(banner.app.isEmpty ? "Notification" : banner.app)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                    Text("now")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                }
                Text(banner.title.isEmpty ? banner.body : banner.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !banner.title.isEmpty, !(banner.subtitle + banner.body).isEmpty {
                    Text([banner.subtitle, banner.body].filter { !$0.isEmpty }.joined(separator: " — "))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: 300, alignment: .leading)
            .offset(x: shown ? 0 : -6)
            .opacity(shown ? 1 : 0)
            Spacer(minLength: 0)
        }
        .padding(.leading, 14)
        .padding(.trailing, 20)
        // Its height is its own, its width the island's: the island is as wide as the
        // row would be on one line, at most 300 for the words, so a long message wraps
        // onto its second line rather than being cut at the first.
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            withAnimation(IslandView.reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.45, dampingFraction: 0.75).delay(0.08)) { shown = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(banner.app): \(banner.title), \(banner.body)")
    }
}

/// A notification kept in the Notifications tab.
struct NotificationCard: View {
    let item: BannerNotification
    let feed: NotificationFeed
    @State private var hovering = false

    var body: some View {
        CardChrome(hovering: $hovering, label: "Notification from \(item.app): \(item.title)", onTap: { feed.open(item) }) {
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title.isEmpty ? item.body : item.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if !item.title.isEmpty, !(item.subtitle + item.body).isEmpty {
                    Text([item.subtitle, item.body].filter { !$0.isEmpty }.joined(separator: " — "))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
            .overlay(alignment: .bottom) {
                CardCaption(title: item.app.isEmpty ? "Notification" : item.app, date: item.date) {
                    Image(nsImage: item.icon).resizable().scaledToFit().frame(width: 18, height: 18)
                }
            }
        } actionRow: {
            CopyAction(perform: copy)
            CardAction(symbol: "arrow.up.forward.app", help: "Open", perform: { feed.open(item) })
            CardAction(symbol: "trash", help: "Remove", tint: .red) { feed.remove(item) }
        } menu: {
            Button("Open \(item.app.isEmpty ? "the App" : item.app)") { feed.open(item) }
            Button("Copy Text", action: copy)
            Divider()
            Button("Remove", role: .destructive) { feed.remove(item) }
            Button("Clear All", role: .destructive) { feed.clear() }
        }
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.text, forType: .string)
    }
}
