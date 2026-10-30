import SwiftUI

struct FeatureIconView: View {
    let name: String
    let size: CGFloat?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if name == "FeatureCalendar" {
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                artwork
            }
        } else {
            artwork
        }
    }

    private var artwork: some View {
        IconCache.observeStyle()
        return Image(nsImage: IconCache.symbolIcon(named: name))
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .id(colorScheme)
            .accessibilityHidden(true)
    }
}
