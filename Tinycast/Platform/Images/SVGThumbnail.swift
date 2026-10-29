import AppKit

/// SVG bytes, which ImageIO cannot decode: sniffing plus capture-time raster.
enum SVGThumbnail {
    /// The opening tag within the first kilobyte, past declarations and comments.
    static func isSVG(_ data: Data) -> Bool {
        let prefix = data.prefix(1024)
        guard let text = String(bytes: prefix, encoding: .utf8)?.lowercased() else { return false }
        var rest = text[...]
        while !rest.isEmpty {
            rest = rest.drop(while: { $0.isWhitespace })
            if rest.hasPrefix("<?") {
                guard let end = rest.range(of: "?>") else { return false }
                rest = rest[end.upperBound...]
            } else if rest.hasPrefix("<!--") {
                guard let end = rest.range(of: "-->") else { return false }
                rest = rest[end.upperBound...]
            } else if rest.hasPrefix("<!doctype") {
                guard let end = rest.firstIndex(of: ">") else { return false }
                rest = rest[rest.index(after: end)...]
            } else {
                return rest.hasPrefix("<svg")
            }
        }
        return false
    }

    /// Vector drawn to exactly `longestEdge` pixels, whatever the display scale.
    @MainActor static func rasterize(_ data: Data, longestEdge: CGFloat) -> CGImage? {
        guard let image = NSImage(data: data) else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = longestEdge / max(size.width, size.height)
        var rect = NSRect(
            x: 0, y: 0, width: max(1, (size.width * scale).rounded()),
            height: max(1, (size.height * scale).rounded()))
        // An identity transform, or a Retina main screen doubles every pixel.
        return image.cgImage(forProposedRect: &rect, context: nil, hints: [.ctm: NSAffineTransform()])
    }
}
