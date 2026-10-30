import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

@main
struct FilePreviewThumbnailTests {
    static func main() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "file-preview-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let context = CGContext(
            data: nil, width: 2400, height: 1600, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2400, height: 1600))
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)

        for pixels in [64, 900] {
            guard let image = await FilePreviewThumbnail.loadAsync(url, maxPixel: CGFloat(pixels)),
                let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else {
                print("FAIL: Quick Look did not generate a thumbnail")
                exit(1)
            }
            guard max(bitmap.width, bitmap.height) <= pixels,
                abs(Double(bitmap.width) / Double(bitmap.height) - 1.5) < 0.05
            else {
                print("FAIL: Quick Look exceeded the pixel budget or changed the aspect ratio")
                exit(1)
            }
            print("\(pixels)px: \(bitmap.width)×\(bitmap.height), \(bitmap.bytesPerRow * bitmap.height) bytes")
        }
        let previousRequest = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 900, height: 900), scale: 2,
            representationTypes: .all)
        let previous = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: previousRequest)
        let oldBitmap = previous.cgImage
        print("Previous request: \(oldBitmap.width)×\(oldBitmap.height), "
            + "\(oldBitmap.bytesPerRow * oldBitmap.height) bytes")
        FilePreviewThumbnail.purgePreviews()
        guard FilePreviewThumbnail.cached(url, maxPixel: 900) == nil else {
            print("FAIL: dismissing retained the preview")
            exit(1)
        }
        print("PASS file preview pixel budget and dismissal")
    }
}
