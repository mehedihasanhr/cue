import SwiftUI

/// A scroll view whose content fades out at the top or the bottom while there is
/// more that way — often the only sign a panel gives that it scrolls. The fade
/// grows in and out as an edge is reached; a mask, so it works over glass and any
/// wallpaper behind it rather than painting a band of its own.
struct FadingScrollView<Content: View>: View {
    /// How deep the fade is at an edge that has more behind it.
    var depth: CGFloat = 28
    @ViewBuilder let content: () -> Content

    @State private var edges = Edges()
    @Namespace private var space

    /// Which edges have more content behind them.
    ///
    /// A couple of points of slack, so a fade never flickers at rest. The slack lives
    /// here, in the value being observed, rather than downstream of it: measuring the
    /// scroll offset into state and deciding afterwards meant every pixel of scrolling
    /// wrote state, re-laid out the reader that produced it, and measured again — which
    /// SwiftUI reports as an action updating several times in one frame.
    private struct Edges: Equatable {
        var above = false
        var below = false

        init() {}

        init(content frame: CGRect, viewport height: CGFloat) {
            above = -frame.minY > 2
            below = frame.height + frame.minY - height > 2
        }
    }

    var body: some View {
        GeometryReader { outer in
            ScrollView {
                content()
                    .background {
                        GeometryReader { inner in
                            let next = Edges(content: inner.frame(in: .named(space)),
                                             viewport: outer.size.height)
                            Color.clear
                                .onChange(of: next, initial: true) { _, edges in
                                    self.edges = edges
                                }
                        }
                    }
            }
            .coordinateSpace(name: space)
            .mask {
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: fraction(edges.above ? depth : 0, in: outer.size.height)),
                    .init(color: .black, location: 1 - fraction(edges.below ? depth : 0, in: outer.size.height)),
                    .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom)
                .animation(IslandView.reduceMotion ? nil : .easeOut(duration: 0.18), value: edges.above)
                .animation(IslandView.reduceMotion ? nil : .easeOut(duration: 0.18), value: edges.below)
            }
        }
    }

    private func fraction(_ length: CGFloat, in height: CGFloat) -> CGFloat {
        min(max(length / max(height, 1), 0), 0.5)
    }
}
