import Foundation

/// A sentence for the window's alert, from a place that has only a sentence to report.
///
/// `EditorModel.report(_:)` takes an error, which is right for the failures that arrive
/// as one. A save that did not land and a frame that could not be written arrive as a
/// reason in words, and this carries the words there without inventing an error kind
/// for each.
struct EditorProblem: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
