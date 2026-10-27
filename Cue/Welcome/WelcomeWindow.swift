import AppKit
import SwiftUI

extension Notification.Name {
    /// Settings asks for the welcome tour again.
    static let cueShowWelcome = Notification.Name("cue.showWelcome")
}

/// The window the welcome plays in: no title bar to speak of, dark, moved by its
/// background, the size of the tour.
@MainActor
final class WelcomeWindowController {
    static let size = CGSize(width: 760, height: 540)

    private let controller: HostedWindowController
    /// Called once the window has gone, however it was closed.
    var onClose: (() -> Void)? {
        get { controller.onClose }
        set { controller.onClose = newValue }
    }

    init(start: WelcomeView.Step = .hello) {
        var close: () -> Void = {}
        controller = HostedWindowController(
            title: "Welcome to Cue",
            contentSize: Self.size,
            styleMask: [.titled, .closable, .fullSizeContentView],
            rootView: WelcomeView(start: start) { close() }
        )
        if let window = controller.window {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.backgroundColor = .black
            window.appearance = NSAppearance(named: .darkAqua)
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
        }
        close = { [weak controller] in controller?.close() }
    }

    func present() { controller.present() }
    func close() { controller.close() }
    var window: NSWindow? { controller.window }
}
