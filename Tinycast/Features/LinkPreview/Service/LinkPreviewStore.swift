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

    private nonisolated static let htmlCap = LinkPreviewDocument.headByteLimit
    private nonisolated static let iconCap = 524_288
    private nonisolated static let imageCap = 2_097_152
    private nonisolated static let timeout: TimeInterval = 10
    private nonisolated static let bannerPixels = 1000
    private nonisolated static let bannerBytes = 3_000_000

    @ObservationIgnored private let cache = NSCache<NSURL, Cached>()
    @ObservationIgnored private let banners = NSCache<NSURL, NSImage>()
    @ObservationIgnored private var bannerGeneration = 0
    @ObservationIgnored private let fetchPreview: @Sendable (URL) async -> Preview
    /// Bumped per finished fetch: `NSCache` is invisible to Observation, so readers track this.
    private var revision = 0
    private(set) var loadingCount = 0

    private final class Cached {
        let preview: Preview
        let hadBanner: Bool
        let retryAfter: Date?

        init(_ preview: Preview) {
            hadBanner = preview.image != nil
            retryAfter = preview.image == nil ? Date().addingTimeInterval(60) : nil
            var metadata = preview
            metadata.image = nil
            self.preview = metadata
        }
    }

    init(fetch: (@Sendable (URL) async -> Preview)? = nil) {
        fetchPreview = fetch ?? { await Self.fetch($0) }
        cache.countLimit = 24
        cache.totalCostLimit = 1024 * 1024
        banners.countLimit = 1
        banners.totalCostLimit = Self.bannerBytes
    }

    func purgeBanners() {
        bannerGeneration &+= 1
        banners.removeAllObjects()
        revision += 1
    }

    /// Cache-only, so a list row can show a favicon without ever reaching the network.
    func cached(_ url: URL) -> Preview? {
        _ = revision
        guard var preview = cache.object(forKey: url as NSURL)?.preview else { return nil }
        preview.image = banners.object(forKey: url as NSURL)
        return preview
    }

    /// Selection cancellation also cancels its network requests.
    func preview(for url: URL) async -> Preview {
        if let hit = cache.object(forKey: url as NSURL),
            hit.retryAfter.map({ Date() < $0 }) ?? true,
            !hit.hadBanner || banners.object(forKey: url as NSURL) != nil,
            let preview = cached(url)
        { return preview }
        guard !Task.isCancelled else { return Preview() }
        loadingCount += 1
        defer { loadingCount -= 1 }
        let generation = bannerGeneration
        let result = await fetchPreview(url)
        guard !Task.isCancelled else { return result }
        var metadata = result
        metadata.image = nil
        cache.setObject(Cached(result), forKey: url as NSURL, cost: Self.cost(result.icon))
        guard generation == bannerGeneration else { return metadata }
        banners.removeAllObjects()
        if let image = result.image, Self.cost(image) <= Self.bannerBytes {
            banners.setObject(image, forKey: url as NSURL, cost: Self.cost(image))
        }
        revision += 1
        return result
    }

    private static func cost(_ image: NSImage?) -> Int {
        guard let image else { return 0 }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil).map {
            $0.bytesPerRow * $0.height
        } ?? Int(image.size.width * image.size.height) * 4
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
        var request = URLRequest(url: url, timeoutInterval: timeout)
        // YouTube redirects the default client to a mobile shell without metadata in its head.
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (bytes, response) = try? await session.bytes(for: request) else { return nil }
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
            response.mimeType?.hasPrefix("text/") == true
                || response.mimeType == "application/xhtml+xml"
        else { return nil }
        var data = Data()
        data.reserveCapacity(min(htmlCap, 16_384))
        do {
            for try await byte in bytes.prefix(htmlCap) {
                data.append(byte)
                if byte == 62,
                    data.suffix(7).map({ $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 })
                        .elementsEqual("</head>".utf8)
                { break }
            }
        } catch {
            return nil
        }
        let base = response.url ?? url
        return autoreleasepool {
            guard let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
            else { return nil }
            return Page(head: LinkPreviewDocument.parseHead(html, baseURL: base))
        }
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
    nonisolated static func still(_ data: Data, maxPixel: Int) -> NSImage? {
        guard maxPixel > 0 else { return nil }
        var pixelLimit = maxPixel
        while true {
            let attempt = autoreleasepool { () -> (image: NSImage?, nextPixel: Int?) in
                guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                    return (nil, nil)
                }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: pixelLimit
                ]
                guard let frame = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                else { return (nil, nil) }
                let bytes = frame.bytesPerRow * frame.height
                guard bytes > bannerBytes else {
                    let size = NSSize(width: frame.width, height: frame.height)
                    return (NSImage(cgImage: frame, size: size), nil)
                }
                guard pixelLimit > 32 else { return (nil, nil) }
                let ratio = sqrt(Double(bannerBytes) / Double(bytes))
                let longestEdge = max(frame.width, frame.height)
                let nextPixel = max(32, Int(Double(longestEdge) * ratio * 0.95))
                return (nil, min(pixelLimit - 1, nextPixel))
            }
            guard let nextPixel = attempt.nextPixel else { return attempt.image }
            pixelLimit = nextPixel
        }
    }

    /// Streamed against `cap`, so a 9 MB banner is abandoned at the cap rather than downloaded.
    private nonisolated static func download(_ url: URL, cap: Int) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        // Image CDNs pick the format from this; Figma's banner is 9 MB as GIF, 1.8 MB as WebP.
        request.setValue(
            "image/avif,image/webp,image/png,image/svg+xml,image/*;q=0.8",
            forHTTPHeaderField: "Accept")
        guard let (bytes, response) = try? await session.bytes(for: request) else { return nil }
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
            response.expectedContentLength <= Int64(cap)
        else { return nil }
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
