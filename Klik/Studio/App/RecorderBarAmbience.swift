import SwiftUI

/// What the bar is doing: ready, live, held, or something wrong.
///
/// Said by the controls' colour alone. The glass stays the same in every mood: a red
/// smoke and a lit rim once tinted it during a take, which made the recording bar a
/// different object from the one that started it.
enum BarMood: Equatable {
    case ready, live, held, alert

    /// The bar's one colour for this mood: what is chosen or switched on.
    var accent: Color {
        switch self {
        case .ready: Color(red: 0.25, green: 0.47, blue: 1)
        case .live: Color(red: 1, green: 0.27, blue: 0.3)
        case .held: Color(red: 1, green: 0.62, blue: 0.16)
        case .alert: Color(red: 1, green: 0.5, blue: 0.16)
        }
    }
}
