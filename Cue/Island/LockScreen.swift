import AppKit
import os
import SwiftUI

/// What plays, and a running focus session, over the lock screen. Experimental:
/// macOS has no way for an app to show there, so this takes the one Droppy and
/// others use, SkyLight's private calls (a window space set above the lock screen's
/// level). Off by default; if the calls aren't there, nothing shows.
@MainActor
final class LockScreenWidgets {
    private let nowPlaying: NowPlaying
    private let focus: FocusTimer?
    private var panel: NSPanel?
    private var observers: [NSObjectProtocol] = []
    private var space: Int32 = 0
    var isEnabled: () -> Bool = { false }

    init(nowPlaying: NowPlaying, focus: FocusTimer?) {
        self.nowPlaying = nowPlaying
        self.focus = focus
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.locked() }
        })
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.unlocked() }
        })
    }

    func stop() {
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        observers = []
        unlocked()
    }

    /// Whether SkyLight's calls could be found (for Settings to say so).
    static var isAvailable: Bool { SkyLight.shared != nil }

    #if DEBUG
    /// For diagnostics: makes a space above the lock screen and takes it away, saying
    /// what SkyLight gave back (0 means it refused).
    static func probe() -> String {
        guard let skyLight = SkyLight.shared else { return "SkyLight not found" }
        let space = skyLight.makeSpaceAboveLockScreen()
        skyLight.destroy(space: space)
        return "connection \(skyLight.connection()), space \(space)"
    }
    #endif

    private func locked() {
        guard isEnabled(), nowPlaying.track != nil || focus?.isRunning == true, let skyLight = SkyLight.shared else { return }
        let panel = panel ?? makePanel()
        self.panel = panel
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let size = LockScreenPanel.size
        panel.setFrame(CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.minY + screen.frame.height * 0.16,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        if space == 0 { space = skyLight.makeSpaceAboveLockScreen() }
        skyLight.move(windowID: Int32(panel.windowNumber), to: space)
        Log.app.info("Lock screen: showing (space \(self.space, privacy: .public))")
    }

    private func unlocked() {
        panel?.orderOut(nil)
        if space != 0 {
            SkyLight.shared?.destroy(space: space)
            space = 0
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: LockScreenPanel.size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.contentView = FirstMouseHostingView(rootView: LockScreenPanel(nowPlaying: nowPlaying, focus: focus))
        return panel
    }
}

/// SkyLight's private window-space calls, looked up at run time.
private struct SkyLight {
    typealias MainConnection = @convention(c) () -> Int32
    typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    typealias SpaceSetLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    typealias HideSpaces = @convention(c) (Int32, CFArray) -> Int32
    typealias SpaceDestroy = @convention(c) (Int32, Int32) -> Int32
    typealias AddWindows = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    let connection: MainConnection
    let create: SpaceCreate
    let setLevel: SpaceSetLevel
    let show: ShowSpaces
    let hide: HideSpaces
    let destroySpace: SpaceDestroy
    let addWindows: AddWindows

    static let shared: SkyLight? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { return nil }
        func symbol<T>(_ name: String, _: T.Type) -> T? { dlsym(handle, name).map { unsafeBitCast($0, to: T.self) } }
        guard let connection = symbol("SLSMainConnectionID", MainConnection.self),
              let create = symbol("SLSSpaceCreate", SpaceCreate.self),
              let setLevel = symbol("SLSSpaceSetAbsoluteLevel", SpaceSetLevel.self),
              let show = symbol("SLSShowSpaces", ShowSpaces.self),
              let hide = symbol("SLSHideSpaces", HideSpaces.self),
              let destroy = symbol("SLSSpaceDestroy", SpaceDestroy.self),
              let add = symbol("SLSSpaceAddWindowsAndRemoveFromSpaces", AddWindows.self) else { return nil }
        return SkyLight(connection: connection, create: create, setLevel: setLevel, show: show, hide: hide, destroySpace: destroy, addWindows: add)
    }()

    /// A space drawn over the lock screen (its level above the shield's), shown.
    func makeSpaceAboveLockScreen() -> Int32 {
        let cid = connection()
        let space = create(cid, 1, 0)
        _ = setLevel(cid, space, 300)
        _ = show(cid, [NSNumber(value: space)] as CFArray)
        return space
    }

    func move(windowID: Int32, to space: Int32) {
        _ = addWindows(connection(), space, [NSNumber(value: windowID)] as CFArray, 7)
    }

    func destroy(space: Int32) {
        let cid = connection()
        _ = hide(cid, [NSNumber(value: space)] as CFArray)
        _ = destroySpace(cid, space)
    }
}

/// The card over the lock screen: what plays with its controls, a focus session's time.
struct LockScreenPanel: View {
    static let size = CGSize(width: 380, height: 150)

    let nowPlaying: NowPlaying
    let focus: FocusTimer?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        VStack(spacing: 12) {
            if let track = nowPlaying.track {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.1))
                        if let image = nowPlaying.artwork { Image(nsImage: image).resizable().scaledToFill() }
                    }
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Text(track.artist).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        control("backward.fill", 14, nowPlaying.previous)
                        control(nowPlaying.isPlaying ? "pause.fill" : "play.fill", 20, nowPlaying.playPause)
                        control("forward.fill", 14, nowPlaying.next)
                    }
                }
            }
            if let focus, focus.isRunning {
                HStack(spacing: 10) {
                    ZStack {
                        Circle().stroke(.white.opacity(0.2), lineWidth: 3)
                        Circle().trim(from: 0, to: focus.progress)
                            .stroke(IslandStyle.accent, style: SwiftUI.StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 22, height: 22)
                    Text("Focus").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(focus.clock).font(.system(size: 18, weight: .semibold).monospacedDigit())
                }
            }
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(width: Self.size.width, height: Self.size.height)
        .background {
            if #available(macOS 26, *) {
                shape.fill(.clear).glassEffect(.regular.tint(.black.opacity(0.35)), in: shape)
            } else {
                shape.fill(.ultraThinMaterial)
            }
        }
        .clipShape(shape)
        .environment(\.colorScheme, .dark)
    }

    private func control(_ symbol: String, _ size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Icon(symbol, size: size, weight: .bold).frame(width: size + 18, height: size + 18).contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}
