import SwiftUI

/// A scroll view whose content fades out at the top or the bottom while there is
/// more that way — often the only sign a panel gives that it scrolls. The fade
/// grows in and out as an edge is reached; a mask, so it works over glass and any
/// wallpaper behind it rather than painting a band of its own.
struct FadingScrollView<Content: View>: View {
    /// How deep the fade is at an edge that has more behind it.
    var depth: CGFloat = 28
    @ViewBuilder let content: () -> Content

    @State private var offset: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var viewport: CGFloat = 0
    @Namespace private var space

    /// A couple of points of slack, so a fade never flickers at rest.
    private var more: (above: Bool, below: Bool) {
        (offset > 2, contentHeight - offset - viewport > 2)
    }

    var body: some View {
        GeometryReader { outer in
            ScrollView {
                content()
                    .background {
                        GeometryReader { inner in
                            let frame = inner.frame(in: .named(space))
                            Color.clear
                                .onAppear { offset = -frame.minY; contentHeight = frame.height }
                                .onChange(of: frame.minY) { _, minY in offset = -minY }
                                .onChange(of: frame.height) { _, height in contentHeight = height }
                        }
                    }
            }
            .coordinateSpace(name: space)
            .onAppear { viewport = outer.size.height }
            .onChange(of: outer.size.height) { _, height in viewport = height }
            .mask {
                let more = more
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: fraction(more.above ? depth : 0, in: outer.size.height)),
                    .init(color: .black, location: 1 - fraction(more.below ? depth : 0, in: outer.size.height)),
                    .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom)
                .animation(IslandView.reduceMotion ? nil : .easeOut(duration: 0.18), value: more.above)
                .animation(IslandView.reduceMotion ? nil : .easeOut(duration: 0.18), value: more.below)
            }
        }
    }

    private func fraction(_ length: CGFloat, in height: CGFloat) -> CGFloat {
        min(max(length / max(height, 1), 0), 0.5)
    }
}
