import AppKit

@main
struct ClipboardSVGRenderTests {
    static func main() async {
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" width="100" height="50">
            <rect width="100" height="50" fill="red"/>
            </svg>
            """
        guard let full = SVGThumbnail.rasterize(Data(svg.utf8), longestEdge: 900),
            let preview = await ClipboardSVGRenderer.render(svg, maxPixel: 900)
        else { fatalError("SVG did not render") }
        precondition(preview.width == 450 && preview.height == 225, "preview uses half resolution")
        let originalBytes = full.bytesPerRow * full.height
        let previewBytes = preview.bytesPerRow * preview.height
        precondition(previewBytes <= originalBytes / 4 + preview.height * 64, "bitmap costs about one quarter")
        let small = await ClipboardSVGRenderer.render(svg, maxPixel: 1)
        precondition(small?.width == 1 && small?.height == 1, "small previews stay valid")
        print("PASS SVG preview: \(full.width)x\(full.height) to \(preview.width)x\(preview.height)")
        print("Bitmap bytes: \(originalBytes) to \(previewBytes)")
    }
}
