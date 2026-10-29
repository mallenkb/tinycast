import AppKit
import Foundation
import ImageIO

/// A page's title and favicon, fetched for the selected row only and kept in memory.
@MainActor
@Observable
final class LinkPreviewStore {
    struct Preview {
        var title: String?
        var description: String?
        var image: NSImage?
        var icon: NSImage?
    }

    /// Cacheless, never `URLSession.shared`, so a preview leaves nothing on disk.
    private nonisolated static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    private nonisolated static let htmlCap = 131_072
    private nonisolated static let iconCap = 524_288
    private nonisolated static let imageCap = 2_097_152
    private nonisolated static let timeout: TimeInterval = 10
    /// Twice the widest preview pane, so a banner stays sharp on Retina without holding 4K.
    private nonisolated static let bannerPixels = 1600

    @ObservationIgnored private let cache = NSCache<NSURL, Cached>()
    /// Bumped per finished fetch: `NSCache` is invisible to Observation, so readers track this.
    private var revision = 0
    private(set) var loadingCount = 0

    private final class Cached {
        let preview: Preview
        init(_ preview: Preview) { self.preview = preview }
    }

    init() {
        cache.countLimit = 24
        cache.totalCostLimit = 24 * 1024 * 1024
    }

    /// Cache-only, so a list row can show a favicon without ever reaching the network.
    func cached(_ url: URL) -> Preview? {
        _ = revision
        return cache.object(forKey: url as NSURL)?.preview
    }

    /// Selection cancellation also cancels its network requests.
    func preview(for url: URL) async -> Preview {
        if let hit = cache.object(forKey: url as NSURL) { return hit.preview }
        guard !Task.isCancelled else { return Preview() }
        loadingCount += 1
        defer { loadingCount -= 1 }
        let result = await Self.fetch(url)
        guard !Task.isCancelled else { return result }
        let images = [result.image, result.icon].compactMap { $0 }
        let cost = images.reduce(0) { total, image in
            total + Int(image.size.width * image.size.height) * 4
        }
        cache.setObject(Cached(result), forKey: url as NSURL, cost: cost)
        revision += 1
        return result
    }

    /// The head gives title, description and image; the origin icon is tried regardless.
    private nonisolated static func fetch(_ url: URL) async -> Preview {
        let page = await head(of: url)
        async let favicon = icon(for: url, href: page?.head.iconPath)
        var head = page?.head ?? LinkPreviewDocument.Head()
        // A private or login-walled page (a Figma file answers 403) borrows its site's card.
        if head.imagePath == nil, let root = LinkPreviewDocument.siteRoot(for: url),
            let site = await self.head(of: root)?.head
        {
            head.imagePath = site.imagePath
            head.title = head.title ?? site.title
            head.description = head.description ?? site.description
        }
        var banner: NSImage?
        if let imageURL = head.imagePath.flatMap({ URL(string: $0) }) {
            banner = await download(imageURL, cap: imageCap).flatMap {
                still($0, maxPixel: bannerPixels)
            }
        }
        return await Preview(
            title: head.title, description: head.description, image: banner, icon: favicon)
    }

    private struct Page {
        var head: LinkPreviewDocument.Head
    }

    private nonisolated static func head(of url: URL) async -> Page? {
        guard
            let (bytes, response) = try? await session.bytes(
                for: URLRequest(url: url, timeoutInterval: timeout)),
            let http = response as? HTTPURLResponse, http.statusCode == 200,
            response.mimeType?.hasPrefix("text/") == true
                || response.mimeType == "application/xhtml+xml"
        else { return nil }
        defer { bytes.task.cancel() }
        var data = Data()
        data.reserveCapacity(min(htmlCap, 16_384))
        do {
            for try await byte in bytes.prefix(htmlCap) { data.append(byte) }
        } catch {
            return nil
        }
        guard
            let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        else { return nil }
        let base = response.url ?? url
        return Page(head: LinkPreviewDocument.parseHead(html, baseURL: base))
    }

    /// The declared icon first, the origin's `favicon.ico` when that fails or is absent.
    private nonisolated static func icon(for pageURL: URL, href: String?) async -> NSImage? {
        let candidates = [href.flatMap { URL(string: $0) }]
            + [LinkPreviewDocument.faviconFallback(for: pageURL)]
        for candidate in candidates.compactMap({ $0 }) {
            // Sniffs content, so SVG and ICO favicons decode beside PNG.
            if let data = await download(candidate, cap: iconCap), let icon = still(data, maxPixel: 64) {
                return icon
            }
        }
        return nil
    }

    /// First frame only: an animated banner hands SwiftUI a view that ignores clip and fit.
    private nonisolated static func still(_ data: Data, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let frame = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
    }

    /// Streamed against `cap`, so a 9 MB banner is abandoned at the cap rather than downloaded.
    private nonisolated static func download(_ url: URL, cap: Int) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        // Image CDNs pick the format from this; Figma's banner is 9 MB as GIF, 1.8 MB as WebP.
        request.setValue(
            "image/avif,image/webp,image/png,image/svg+xml,image/*;q=0.8",
            forHTTPHeaderField: "Accept")
        guard let (bytes, response) = try? await session.bytes(for: request),
            let http = response as? HTTPURLResponse, http.statusCode == 200,
            response.expectedContentLength <= Int64(cap)
        else { return nil }
        defer { bytes.task.cancel() }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > cap { return nil }
            }
        } catch {
            return nil
        }
        return data.isEmpty ? nil : data
    }
}
