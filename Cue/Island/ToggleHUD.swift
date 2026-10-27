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

/// The switch in the island: the thing itself (the Caps Lock key, its light
/// coming on; the Focus orb), what it is and what that means, and On or Off on a chip.
struct ToggleRow: View {
    let toggle: ToggleHUD
    @State private var shown = false

    private var detail: String {
        switch (toggle.kind, toggle.on) {
        case (.capsLock, true): "Typing in capitals"
        case (.capsLock, false): "Typing normally"
        case (.focus, true): "Notifications silenced"
        case (.focus, false): "Notifications on"
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            switch toggle.kind {
            case .capsLock: CapsKeycap(on: toggle.on, size: 42)
            case .focus: FocusOrb(on: toggle.on, size: 42)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(toggle.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .lineLimit(1)
            .offset(x: shown ? 0 : -6)
            .opacity(shown ? 1 : 0)
            Spacer(minLength: 16)
            Text(toggle.on ? "On" : "Off")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(toggle.on ? toggle.tint : .white.opacity(0.55))
                .padding(.horizontal, 11)
                .frame(height: 24)
                .background((toggle.on ? toggle.tint : .white).opacity(toggle.on ? 0.16 : 0.08), in: Capsule())
                .overlay(Capsule().strokeBorder((toggle.on ? toggle.tint : .white).opacity(0.3), lineWidth: 1))
                .scaleEffect(shown ? 1 : 0.7)
                .opacity(shown ? 1 : 0)
        }
        .padding(.leading, 14)
        .padding(.trailing, 22)
        .fixedSize()
        .onAppear {
            withAnimation(IslandView.reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.4, dampingFraction: 0.75).delay(0.1)) { shown = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(toggle.title) \(toggle.on ? "on" : "off")")
    }
}
