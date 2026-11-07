import SwiftUI

struct SVGFileSurface: View {
    @Environment(\.metrics) private var metrics
    let url: URL
    @State private var rendered: Rendered?

    private struct Rendered {
        let url: URL
        let image: CGImage?
    }

    private struct Request: Equatable {
        let url: URL
        let pixels: CGFloat
    }

    var body: some View {
        let request = Request(url: url, pixels: metrics.size.clipboardPreviewPixel)
        Group {
            if let rendered, rendered.url == url {
                if let image = rendered.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    QuickLookSurface(url: url)
                }
            } else {
                Color.clear
            }
        }
        .task(id: request) {
            let image = await Self.render(request)
            guard !Task.isCancelled else { return }
            rendered = Rendered(url: request.url, image: image)
        }
    }

    @concurrent private static func render(_ request: Request) async -> CGImage? {
        guard !Task.isCancelled, let handle = try? FileHandle(forReadingFrom: request.url) else { return nil }
        defer { try? handle.close() }
        let limit = 4 * 1024 * 1024
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit, !Task.isCancelled else {
            return nil
        }
        return SVGThumbnail.rasterize(data, longestEdge: max(1, (request.pixels / 2).rounded(.down)))
    }
}
