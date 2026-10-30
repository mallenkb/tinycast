import AppKit
import Synchronization
import UniformTypeIdentifiers

@main
@MainActor
struct LinkPreviewCacheTests {
    static var failures = 0

    static func expect(_ condition: Bool, _ message: String) {
        if !condition {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() async {
        bannerDecodeBudget()
        let calls = Mutex(0)
        let store = LinkPreviewStore(fetch: { _ in
            calls.withLock { $0 += 1 }
            return LinkPreviewStore.Preview(
                title: "Example", image: NSImage(size: NSSize(width: 900, height: 600)),
                icon: NSImage(size: NSSize(width: 32, height: 32)))
        })
        let url = URL(string: "https://example.invalid/preview")!
        let first = await store.preview(for: url)
        expect(first.image != nil, "initial banner loads")
        _ = await store.preview(for: url)
        expect(calls.withLock { $0 } == 1, "warm preview avoids a refetch")
        store.purgeBanners()
        expect(first.image != nil, "purge does not mutate a caller-owned preview")
        expect(store.cached(url)?.title == "Example", "purge preserves title")
        expect(store.cached(url)?.icon != nil, "purge preserves favicon")
        expect(store.cached(url)?.image == nil, "purge removes banner from cache")
        _ = await store.preview(for: url)
        expect(calls.withLock { $0 } == 2, "reopening reloads purged banner")

        let other = URL(string: "https://example.invalid/other")!
        _ = await store.preview(for: other)
        expect(store.cached(url)?.image == nil, "browsing releases the previous banner")
        expect(store.cached(url)?.icon != nil, "browsing keeps previous favicons")
        expect(store.cached(other)?.image != nil, "selected banner remains cached")

        let gate = Gate()
        let delayed = LinkPreviewStore(fetch: { _ in await gate.fetch() })
        let request = Task { await delayed.preview(for: url) }
        while gate.pending == nil { await Task.yield() }
        delayed.purgeBanners()
        gate.finish()
        let late = await request.value
        expect(late.image == nil, "late completion does not hand back a hidden banner")
        expect(delayed.cached(url)?.image == nil, "late completion cannot refill cache")
        expect(delayed.cached(url)?.title == "Late", "late metadata remains available")
        expect(delayed.loadingCount == 0, "loading count balances after completion")
        print(failures == 0 ? "PASS link preview cache lifecycle" : "FAIL \(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    static func bannerDecodeBudget() {
        for (width, height, depth, maxPixel) in [
            (2400, 2400, 8, 1000), (2400, 1350, 8, 1000), (800, 2400, 8, 1000),
            (900, 900, 8, 1000), (700, 700, 16, 1000), (256, 128, 8, 64)
        ] {
            autoreleasepool {
                let bitmap = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                    bitsPerSample: depth, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bitmapFormat: depth == 16 ? [.sixteenBitLittleEndian] : [],
                    bytesPerRow: 0, bitsPerPixel: depth * 4)!
                bitmap.bitmapData!.initialize(repeating: 0, count: bitmap.bytesPerRow * height)
                let data = NSMutableData()
                let destination = CGImageDestinationCreateWithData(
                    data, UTType.png.identifier as CFString, 1, nil)!
                CGImageDestinationAddImage(destination, bitmap.cgImage!, nil)
                expect(CGImageDestinationFinalize(destination), "the decoding fixture encodes")
                if depth == 16 {
                    let source = CGImageSourceCreateWithData(data as CFData, nil)!
                    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
                    expect(properties[kCGImagePropertyDepth] as? Int == 16,
                           "the decoding fixture preserves high-bit-depth pixels")
                }
                let decoded = LinkPreviewStore.still(data as Data, maxPixel: maxPixel)?
                    .cgImage(forProposedRect: nil, context: nil, hints: nil)
                expect(decoded != nil, "banners and favicons render for each input shape and bit depth")
                if let decoded {
                    expect(max(decoded.width, decoded.height) <= maxPixel, "the requested edge is bounded")
                    expect(decoded.bytesPerRow * decoded.height <= 3_000_000,
                           "decoded banner fits the three MB budget")
                    if depth == 16 {
                        expect(decoded.bitsPerComponent == 16, "high-bit-depth pixels stay high-bit-depth")
                        expect(decoded.width < width, "the smaller high-bit-depth source needs downsampling")
                    }
                    let difference = abs(Double(decoded.width) / Double(decoded.height)
                        - Double(width) / Double(height))
                    expect(difference < 0.01, "downsampling preserves banner aspect ratio")
                }
            }
        }
    }

    @MainActor
    final class Gate {
        var pending: CheckedContinuation<LinkPreviewStore.Preview, Never>?

        func fetch() async -> LinkPreviewStore.Preview {
            await withCheckedContinuation { pending = $0 }
        }

        func finish() {
            pending?.resume(returning: LinkPreviewStore.Preview(
                title: "Late", image: NSImage(size: NSSize(width: 900, height: 600))))
            pending = nil
        }
    }
}
