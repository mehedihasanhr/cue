import SwiftUI
import TimelineKit

/// The transcript as words to pick, for cutting the video by what was said.
///
/// A line the recogniser timed is shown word by word; a line typed or corrected by hand is
/// shown as its text, greyed, with the reason it cannot be picked from — its word timings
/// are a guess, and a cut made by a guess could take a real word with it.
struct TranscriptWords: View {
    let model: EditorModel

    var body: some View {
        let words = model.spokenWords
        let byLine = Dictionary(grouping: words, by: \.cue)
        let picked = model.transcriptWords.current(among: words)
        let saying = TranscriptEditing.word(at: model.playhead, among: words)?.id
        let untimed = model.timeline.captions.contains { byLine[$0.id] == nil }

        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.timeline.captions) { cue in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Button {
                        model.scrub(to: cue.start)
                    } label: {
                        Text(Timecode.short(cue.start))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 48, alignment: .leading)
                    .help("Go to this caption")

                    if let line = byLine[cue.id] {
                        TranscriptLineWords(words: line,
                                            picked: picked.filter { $0.cue == cue.id },
                                            saying: saying?.cue == cue.id ? saying : nil,
                                            pick: { model.pickWord($0) })
                            .equatable()
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(cue.text.isEmpty ? "Empty caption" : cue.text)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                            Image(systemName: "clock.badge.questionmark")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .help("No recorded word timings: this line was typed or corrected, so its words can't be cut one by one.")
                        }
                    }
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .contextMenu {
                    Button("Go to This Line") { model.scrub(to: cue.start) }
                    Button("Edit Timing") { model.select(.caption(cue.id)) }
                    Divider()
                    if picked.contains(where: { $0.cue == cue.id }) {
                        Button("Cut Picked Words from Video", role: .destructive) { model.cutPickedWords() }
                    }
                    Button("Remove Line from Video", role: .destructive) { model.removeCaptionFromVideo(cue.id) }
                }
            }

            Button {
                model.cutPickedWords()
            } label: {
                Text(picked.isEmpty ? "Cut from Video"
                     : picked.count == 1 ? "Cut 1 Word from Video" : "Cut \(picked.count) Words from Video")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .disabled(picked.isEmpty)
            .padding(.top, 4)

            Text(picked.isEmpty
                 ? "Click a word to go to it. Shift-click to pick a run of words, ⌘-click to add one."
                 : "Delete cuts the picked words from the video, picture and sound together. Undo puts them back.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if untimed {
                Text("Greyed lines were typed or corrected by hand, so nothing knows exactly when their words were said. Cut them a whole line at a time from the line's menu, or listen again to time them.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One line's words, as things to click.
///
/// Equatable on what it shows, so the playhead moving along a transcript of a thousand
/// words redraws the one or two lines whose spoken word changed rather than every line.
private struct TranscriptLineWords: View, Equatable {
    let words: [TranscriptEditing.SpokenWord]
    let picked: Set<TranscriptEditing.WordID>
    let saying: TranscriptEditing.WordID?
    let pick: (TranscriptEditing.SpokenWord) -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.words == b.words && a.picked == b.picked && a.saying == b.saying
    }

    var body: some View {
        WordFlow(spacing: 2, lineSpacing: 2) {
            ForEach(words, id: \.id) { word in
                token(word)
            }
        }
    }

    private func token(_ word: TranscriptEditing.SpokenWord) -> some View {
        let isPicked = picked.contains(word.id)
        let isSaying = saying == word.id
        return Button {
            pick(word)
        } label: {
            Text(word.text)
                .font(.system(size: 11))
                .foregroundStyle(isPicked ? AnyShapeStyle(Color.white)
                                 : isSaying ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(isPicked ? AnyShapeStyle(Color.accentColor)
                              : isSaying ? AnyShapeStyle(Color.accentColor.opacity(0.16)) : AnyShapeStyle(.clear))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(word.text)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }
}

/// Words set like a paragraph: left to right, onto the next line when the next word would
/// not fit.
struct WordFlow: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty, needed > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
