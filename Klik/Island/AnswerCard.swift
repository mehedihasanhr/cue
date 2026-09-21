import SwiftUI

/// A quick answer in the search results: the value large, what it is beneath; a
/// click copies it. Colors get a swatch and can be kept in the Colors tab.
struct AnswerCard: View {
    let answer: QuickAnswer
    let clipboard: ClipboardHistory
    let colors: ColorStore
    @State private var hovering = false

    var body: some View {
        CardChrome(hovering: $hovering, label: "\(answer.label): \(answer.value)", onTap: copy) {
            ZStack(alignment: .bottomLeading) {
                if let color = answer.color {
                    color.swiftUIColor
                    LinearGradient(colors: [.black.opacity(0), .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                } else {
                    Color.white.opacity(0.05)
                }
                VStack(alignment: .leading, spacing: 4) {
                    if answer.color == nil {
                        Icon(answer.symbol, size: 20, weight: .semibold)
                            .foregroundStyle(Color.brand.opacity(0.95))
                            .padding(.bottom, 2)
                    }
                    Text(answer.value)
                        .font(.system(size: answer.value.count > 40 ? 11 : 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(answer.value.count > 40 ? 4 : 2)
                        .minimumScaleFactor(0.7)
                        .textSelection(.enabled)
                    Text(answer.label)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
                .padding(12)
                .shadow(color: .black.opacity(answer.color == nil ? 0 : 0.4), radius: 2, y: 1)
            }
        } actionRow: {
            CopyAction(perform: copy)
            if clipboard.canPaste {
                CardAction(symbol: "arrow.down.doc", help: "Paste") {
                    clipboard.copy(text: answer.value)
                    clipboard.pressPaste()
                }
            }
            if let color = answer.color {
                CardAction(symbol: "plus.circle", help: "Keep in Colors") {
                    _ = colors.add(color)
                    FeedbackHUD.show("Kept in Colors", symbol: "paintpalette.fill", duration: .seconds(1.2), swatch: color)
                }
            }
        } menu: {
            Button("Copy", action: copy)
            if clipboard.canPaste {
                Button("Paste") {
                    clipboard.copy(text: answer.value)
                    clipboard.pressPaste()
                }
            }
            if let color = answer.color {
                Divider()
                Button("Keep in Colors") { _ = colors.add(color) }
            }
        }
    }

    private func copy() {
        clipboard.copy(text: answer.value)
        FeedbackHUD.show("Copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2), subtitle: answer.label, swatch: answer.color)
    }
}
