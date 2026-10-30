import SwiftUI

/// A page's banner image, or its favicon, title and description, shared by every link preview.
struct LinkPreviewCard: View {
    @Environment(\.metrics) private var metrics
    @Environment(LinkPreviewStore.self) private var previews
    let url: URL

    @State private var preview: LinkPreviewStore.Preview?
    @State private var loaded = false

    /// Open Graph's recommended 1200×630, so the loading tile rarely jumps when a banner lands.
    private static let bannerAspect: CGFloat = 1200.0 / 630.0

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: metrics.radius.card, style: .continuous)
    }

    var body: some View {
        Group {
            if let banner = preview?.image {
                Image(nsImage: banner)
                    .resizable()
                    .scaledToFit()
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Theme.Colors.cardStroke, lineWidth: 1))
                    // After the clip, so a height-bound pane centers the card rather than its stroke.
                    .frame(maxWidth: .infinity)
            } else if loaded {
                summary
            } else {
                shape
                    .fill(Theme.Colors.controlSurface)
                    .aspectRatio(Self.bannerAspect, contentMode: .fit)
            }
        }
        .task(id: url) {
            preview = previews.cached(url)
            loaded = preview != nil
            let result = await previews.preview(for: url)
            guard !Task.isCancelled else { return }
            preview = result
            loaded = true
        }
    }

    /// A page with no banner: its favicon, title and description on a card of the same shape.
    private var summary: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.md) {
            LinkFavicon(icon: preview?.icon, side: metrics.size.rowIcon)
            VStack(alignment: .leading, spacing: metrics.spacing.xs) {
                Text(verbatim: preview?.title ?? url.host ?? url.absoluteString)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                if let description = preview?.description, !description.isEmpty {
                    Text(verbatim: description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            Text(verbatim: url.host ?? url.absoluteString)
                .font(metrics.typography.rowTrailing)
                .foregroundStyle(Theme.Colors.textTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(metrics.spacing.xl)
        .background(shape.fill(Theme.Colors.controlSurface))
        .overlay(shape.strokeBorder(Theme.Colors.cardStroke, lineWidth: 1))
    }
}

/// A fetched favicon, else the globe tile, clipped the way every row icon is.
struct LinkFavicon: View {
    @Environment(\.metrics) private var metrics
    let icon: NSImage?
    let side: CGFloat

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: metrics.radius.thumbnail, style: .continuous)
                    .fill(Theme.Colors.controlSurface)
                    .overlay(
                        SymbolImage(name: "globe", size: side * 0.5)
                            .font(.system(size: side * 0.5))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: metrics.radius.thumbnail, style: .continuous))
    }
}
