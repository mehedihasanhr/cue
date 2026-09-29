import Foundation
import Observation

/// Whatever actually tells macOS about a global shortcut.
///
/// The app's is Carbon's `RegisterEventHotKey`, which needs no Accessibility grant and
/// works inside the sandbox. Tests hand in one that only writes down what it was asked,
/// so the rules below are checked without taking a single key away from the person using
/// this Mac.
@MainActor
public protocol HotkeyRegistrar: AnyObject {
    /// Asks for `combo`, calling `handler` whenever it is pressed. `false` when the system
    /// refused — another app registered it first.
    func register(_ combo: KeyCombo, id: UInt32, handler: @escaping @MainActor () -> Void) -> Bool
    func unregister(id: UInt32)
}

/// Keeps the registered shortcuts in step with the settings and the session.
///
/// Told the state of things whenever it changes and works out the difference itself, so
/// the rule for what is registered when is written once: `RecorderAction.isWanted(in:)`.
@MainActor
@Observable
public final class RecorderHotkeys {
    @ObservationIgnored private let registrar: any HotkeyRegistrar
    /// What to do when a shortcut is pressed.
    @ObservationIgnored public var perform: (RecorderAction) -> Void = { _ in }

    /// What is registered right now.
    public private(set) var registered: [RecorderAction: KeyCombo] = [:]
    /// The shortcuts the system refused, so Settings can say another app has them.
    public private(set) var refused: [RecorderAction: KeyCombo] = [:]

    public init(registrar: any HotkeyRegistrar) {
        self.registrar = registrar
    }

    public static func id(for action: RecorderAction) -> UInt32 {
        UInt32(RecorderAction.allCases.firstIndex(of: action) ?? 0) + 1
    }

    /// Registers what is wanted now and lets go of what is not.
    ///
    /// A shortcut with a problem — one macOS or Klik already has, one that takes typing
    /// away — is never registered even if it was stored: Settings refuses them, and a
    /// stored one from an older build must not slip past that.
    public func update(shortcuts: RecorderShortcuts, isEnabled: Bool, state: RecordingSession.State) {
        var wanted: [RecorderAction: KeyCombo] = [:]
        if isEnabled {
            for action in RecorderAction.allCases where action.isWanted(in: state) {
                guard let combo = shortcuts[action], shortcuts.problem(with: combo, for: action) == nil else { continue }
                wanted[action] = combo
            }
        }

        for (action, combo) in registered where wanted[action] != combo {
            registrar.unregister(id: Self.id(for: action))
            registered[action] = nil
        }
        for (action, combo) in refused where wanted[action] != combo {
            refused[action] = nil
        }
        for (action, combo) in wanted where registered[action] == nil && refused[action] == nil {
            let accepted = registrar.register(combo, id: Self.id(for: action)) { [weak self] in
                self?.perform(action)
            }
            if accepted {
                registered[action] = combo
            } else {
                refused[action] = combo
            }
        }
    }

    /// Lets go of everything, for quitting.
    public func removeAll() {
        for action in registered.keys { registrar.unregister(id: Self.id(for: action)) }
        registered = [:]
        refused = [:]
    }
}
