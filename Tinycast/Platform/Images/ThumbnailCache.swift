import AppKit
import Synchronization

final class ThumbnailCache: @unchecked Sendable {
    private final class Cache: NSCache<NSString, NSImage> {}

    /// Longest-edge size at or below which a bitmap is a row tile; larger is a preview.
    private static let rowThreshold: CGFloat = 128

    struct Generation: Sendable {
        fileprivate var rows = 0
        fileprivate var previews = 0
    }

    private let epoch = Mutex(Generation())
    var generation: Generation { epoch.withLock { $0 } }

    private let rows = Cache()
    private let previews = Cache()

    init(rowBytes: Int, previewBytes: Int) {
        rows.totalCostLimit = rowBytes
        previews.totalCostLimit = previewBytes
        previews.countLimit = 1
    }

    private func tier(_ maxPixel: CGFloat) -> Cache {
        maxPixel <= Self.rowThreshold ? rows : previews
    }

    private func key(_ url: URL, _ maxPixel: CGFloat) -> NSString {
        "\(url.path)#\(Int(maxPixel))" as NSString
    }

    func cached(_ url: URL, maxPixel: CGFloat) -> NSImage? {
        tier(maxPixel).object(forKey: key(url, maxPixel))
    }

    /// Cost is the decoded bitmap's real footprint, so a limit bounds actual RAM.
    func store(_ image: NSImage, for url: URL, maxPixel: CGFloat, cost: Int, generation: Generation) {
        epoch.withLock { current in
            if maxPixel <= Self.rowThreshold {
                guard generation.rows == current.rows else { return }
            } else {
                guard generation.previews == current.previews else { return }
                previews.removeAllObjects()
            }
            tier(maxPixel).setObject(image, forKey: key(url, maxPixel), cost: cost)
        }
    }

    /// Frees the large bitmaps on dismiss; row tiles stay warm for a re-open.
    func purgePreviews() {
        epoch.withLock { generation in
            generation.previews &+= 1
            previews.removeAllObjects()
        }
    }

    func purgeDecoded() {
        epoch.withLock { generation in
            generation.rows &+= 1
            generation.previews &+= 1
            rows.removeAllObjects()
            previews.removeAllObjects()
        }
    }
}
