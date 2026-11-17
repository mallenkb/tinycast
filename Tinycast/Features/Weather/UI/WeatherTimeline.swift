import SwiftUI

struct WeatherTimeline<Identity: Hashable, Content: View>: View {
    let identity: Identity
    @ViewBuilder let content: () -> Content

    @Environment(\.metrics) private var metrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position = ScrollPosition(x: 0)
    @State private var viewport = Viewport()
    @State private var hovered = false
    @FocusState private var focusedArrow: Int?

    private struct Viewport: Equatable {
        var offset: CGFloat = 0
        var width: CGFloat = 0
        var limit: CGFloat = 0
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: metrics.spacing.xxs) { content() }
        }
        .scrollIndicators(.hidden)
        .frame(height: metrics.scaled(Theme.Weather.timelineHeight), alignment: .top)
        .scrollPosition($position)
        .onScrollGeometryChange(for: Viewport.self) { geometry in
            Viewport(offset: geometry.contentOffset.x, width: geometry.containerSize.width,
                     limit: max(0, geometry.contentSize.width - geometry.containerSize.width))
        } action: { _, value in
            viewport = value
        }
        .overlay(alignment: .leading) { arrow(-1) }
        .overlay(alignment: .trailing) { arrow(1) }
        .armedHover($hovered)
        .onChange(of: identity) { position.scrollTo(x: 0) }
    }

    private func arrow(_ direction: Int) -> some View {
        let available = direction < 0 ? viewport.offset > 1 : viewport.offset < viewport.limit - 1
        return Button {
            let next = min(viewport.limit, max(0, viewport.offset + CGFloat(direction) * viewport.width * 0.75))
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { position.scrollTo(x: next) }
        } label: {
            SymbolImage(name: direction < 0 ? "chevron.left" : "chevron.right",
                        size: metrics.scaled(20), monochrome: true)
                .frame(width: metrics.size.rowIcon, height: metrics.scaled(Theme.Weather.illustrationHeight))
                .background(Theme.Colors.weatherControlSelection,
                            in: RoundedRectangle(cornerRadius: metrics.radius.row))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(direction < 0 ? Text("Earlier") : Text("Later"))
        .focused($focusedArrow, equals: direction)
        .disabled(!available)
        .opacity(available && (hovered || focusedArrow == direction) ? 1 : 0)
        .allowsHitTesting(available && hovered)
    }
}
