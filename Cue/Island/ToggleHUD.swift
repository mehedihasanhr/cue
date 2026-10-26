import AppKit
import Intents
import os
import SwiftUI

/// Something switched on or off (Caps Lock, a Focus), as the island shows it.
struct ToggleHUD: Equatable {
    enum Kind: Equatable {
        case capsLock, focus
    }

    let kind: Kind
    let on: Bool

    var title: String {
        switch kind {
        case .capsLock: "Caps Lock"
        case .focus: "Focus"
        }
    }

    var symbol: String {
        switch kind {
        case .capsLock: on ? "capslock.fill" : "capslock"
        case .focus: on ? "moon.fill" : "moon"
        }
    }

    var tint: Color {
        switch kind {
        case .capsLock: Color(red: 0.36, green: 0.85, blue: 0.45)
        case .focus: Color(red: 0.62, green: 0.5, blue: 1.0)
        }
    }
}

/// Caps Lock and Focus, watched; calls back when either changes.
///
/// Caps Lock from the modifier keys (a global monitor of them needs the
/// Accessibility permission Cue has for pasting). Focus from INFocusStatusCenter,
/// which says only whether a Focus is on, not which; macOS asks once to share it.
@MainActor
final class ToggleMonitor {
    private let onChange: (ToggleHUD) -> Void
    private var monitors: [Any] = []
    private var capsLock = NSEvent.modifierFlags.contains(.capsLock)
    private var focused: Bool?
    private var focusTask: Task<Void, Never>?

    init(onChange: @escaping (ToggleHUD) -> Void) {
        self.onChange = onChange
        let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let on = event.modifierFlags.contains(.capsLock)
            MainActor.assumeIsolated { self?.capsLockChanged(on) }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let on = event.modifierFlags.contains(.capsLock)
            MainActor.assumeIsolated { self?.capsLockChanged(on) }
            return event
        }
        monitors = [global, local].compactMap { $0 }
        startFocus()
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        focusTask?.cancel()
    }

    private func capsLockChanged(_ on: Bool) {
        guard on != capsLock else { return }
        capsLock = on
        onChange(ToggleHUD(kind: .capsLock, on: on))
    }

    /// The Focus state has no notification Cue can have; it is looked at every two
    /// seconds once sharing it is allowed.
    private func startFocus() {
        let center = INFocusStatusCenter.default
        focusTask = Task { [weak self] in
            if center.authorizationStatus == .notDetermined {
                _ = await withCheckedContinuation { continuation in
                    center.requestAuthorization { continuation.resume(returning: $0) }
                }
            }
            Log.app.info("Focus status sharing: \(String(describing: center.authorizationStatus.rawValue), privacy: .public)")
            guard center.authorizationStatus == .authorized else { return }
            while !Task.isCancelled {
                guard let self else { return }
                let now = center.focusStatus.isFocused
                if let now, let focused, now != focused { onChange(ToggleHUD(kind: .focus, on: now)) }
                if let now { focused = now }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

/// The switch in the island: its symbol on a disc lit when on, what it is, and a
/// small switch sliding over.
struct ToggleRow: View {
    let toggle: ToggleHUD
    @State private var flipped = false

    var body: some View {
        let on = flipped ? toggle.on : !toggle.on
        HStack(spacing: 11) {
            Icon(toggle.symbol, size: 14, weight: .semibold)
                .foregroundStyle(on ? toggle.tint : .white.opacity(0.6))
                .frame(width: 30, height: 30)
                .background((on ? toggle.tint : .white).opacity(on ? 0.18 : 0.08), in: Circle())
                .overlay(Circle().strokeBorder((on ? toggle.tint : .white).opacity(0.3), lineWidth: 1))
                .shadow(color: on ? toggle.tint.opacity(0.6) : .clear, radius: 8)
            Text(toggle.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Spacer(minLength: 14)
            Text(toggle.on ? "On" : "Off")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .contentTransition(.opacity)
            // A little switch: the knob slides as it appears.
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(on ? toggle.tint : .white.opacity(0.18))
                Circle().fill(.white).padding(2).shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
            }
            .frame(width: 32, height: 19)
        }
        .padding(.leading, 14)
        .padding(.trailing, 20)
        .fixedSize()
        .onAppear {
            withAnimation(IslandView.reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.35, dampingFraction: 0.7).delay(0.15)) { flipped = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(toggle.title) \(toggle.on ? "on" : "off")")
    }
}
