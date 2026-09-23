import SwiftUI
import TimelineKit

/// The pieces every inspector section is built from.
///
/// One place for the undo pattern, so it is decided once rather than at forty call
/// sites: a discrete control is one command, and a continuous one is a command per
/// change bracketed by an interaction, which collapses the whole drag into a single
/// entry named for the thing being dragged.
@MainActor
struct StyleBinding {
    let model: EditorModel

    /// A tap: one entry on the undo stack, named for what it changed.
    func set<Value: Sendable & Equatable>(_ path: WritableKeyPath<Timeline, Value> & Sendable,
                                          to value: Value,
                                          _ name: String) {
        model.apply(Commands.Restyle(name) { $0[keyPath: path] = value })
    }

    /// A slider or a toggle. The coalescing comes from the interaction around the drag,
    /// which `slider(_:)` below wires up.
    func binding<Value: Sendable & Equatable>(_ path: WritableKeyPath<Timeline, Value> & Sendable,
                                              _ name: String) -> Binding<Value> {
        Binding {
            model.timeline[keyPath: path]
        } set: { value in
            model.apply(Commands.Restyle(name) { $0[keyPath: path] = value })
        }
    }
}

extension View {
    /// A section heading with its icon, matching the reference's "Background" rows.
    func inspectorSection(_ title: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            self
        }
    }
}

/// A labelled slider that records one undo entry per drag.
struct InspectorSlider: View {
    let model: EditorModel
    let title: String
    let systemImage: String?
    let value: Binding<Double>
    let range: ClosedRange<Double>

    init(model: EditorModel,
         _ title: String,
         systemImage: String? = nil,
         value: Binding<Double>,
         range: ClosedRange<Double>) {
        self.model = model
        self.title = title
        self.systemImage = systemImage
        self.value = value
        self.range = range
    }

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }
            Text(title)
                .font(.system(size: 12))
                .frame(width: 74, alignment: .leading)
            Slider(value: value, in: range) { editing in
                // The edit is recorded once per drag, not once per pixel of movement:
                // undo should step back over "Padding", not over four hundred tiny
                // changes.
                if editing {
                    model.document.beginInteraction(title)
                } else {
                    model.document.endInteraction()
                }
            }
        }
    }
}

/// One background choice in the grid.
struct SwatchTile<Content: View>: View {
    let isSelected: Bool
    let title: String
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Button(action: action) {
            content
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(.primary.opacity(0.12))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0)
                        .padding(-3)
                }
                .animation(StudioMotion.selection, value: isSelected)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Collapses a burst of writes into one undo entry.
///
/// For the one control that cannot say when a drag starts and stops: `ColorPicker` has
/// no `onEditingChanged`, and dragging inside the system colour panel writes
/// continuously. Without this, picking a colour by eye costs several hundred undo steps
/// and shoves everything else off the stack.
@MainActor
@Observable
final class InteractionCoalescer {
    private var closing: Task<Void, Never>?
    private var isOpen = false

    func touch(_ name: String, on document: EditorDocument, wait: Duration = .milliseconds(400)) {
        if !isOpen {
            document.beginInteraction(name)
            isOpen = true
        }
        closing?.cancel()
        closing = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            document.endInteraction()
            self?.isOpen = false
        }
    }
}
