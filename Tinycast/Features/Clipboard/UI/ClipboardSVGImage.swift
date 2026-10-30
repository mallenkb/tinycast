import SwiftUI

enum ClipboardSVGRenderer {
    static func isSVG(_ text: String) -> Bool {
        SVGThumbnail.isSVG(Data(text.utf8.prefix(1024)))
    }

    @concurrent static func render(_ text: String, maxPixel: CGFloat) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        return SVGThumbnail.rasterize(Data(text.utf8), longestEdge: max(1, (maxPixel / 2).rounded(.down)))
    }
}

struct ClipboardSVGImage<Placeholder: View>: View {
    let text: String
    let maxPixel: CGFloat
    @ViewBuilder let placeholder: () -> Placeholder

    private struct Request: Hashable {
        let text: String
        let maxPixel: CGFloat
    }

    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
            } else {
                placeholder()
            }
        }
        .task(id: Request(text: text, maxPixel: maxPixel)) {
            image = nil
            let rendered = await ClipboardSVGRenderer.render(text, maxPixel: maxPixel)
            guard !Task.isCancelled else { return }
            image = rendered
        }
    }
}
