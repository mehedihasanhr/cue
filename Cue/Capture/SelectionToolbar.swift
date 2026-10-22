import SwiftUI

/// The floating pill of actions shown beneath a finished selection.
struct SelectionToolbar: View {
    let mode: CaptureMode
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .glassButton()
            .help("Cancel (esc)")

            Button(action: onConfirm) {
                Label(confirmTitle, systemImage: confirmIcon)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 4)
            }
            .glassButton(prominent: true)
            .tint(.brand)
            .help("Confirm (↩)")
        }
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .cueGlass(cornerRadius: 16)
        .padding(20) // room for the shadow inside the hosting view
        .environment(\.colorScheme, .dark)
    }

    private var confirmTitle: String {
        switch mode {
        case .region, .window: "Capture"
        case .text: "Copy Text"
        case .scrolling: "Start Capture"
        }
    }

    private var confirmIcon: String {
        switch mode {
        case .region, .window: "camera.fill"
        case .text: "text.viewfinder"
        case .scrolling: "arrow.down"
        }
    }
}

#Preview {
    ZStack {
        LinearGradient(colors: [.orange, .pink, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
        VStack(spacing: 20) {
            SelectionToolbar(mode: .region, onConfirm: {}, onCancel: {})
            SelectionToolbar(mode: .scrolling, onConfirm: {}, onCancel: {})
        }
    }
    .frame(width: 700, height: 260)
}
