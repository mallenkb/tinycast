import Foundation

struct DictationAppOverride: Hashable, Sendable {
    enum Transform: Hashable, Sendable {
        case off, transform(UUID)
    }

    var cleanup: DictationCleanupMode?
    var transform: Transform?

    init(cleanup: DictationCleanupMode? = nil, transform: Transform? = nil) {
        self.cleanup = cleanup
        self.transform = transform
    }

    init?(stored: [String: String]) {
        guard Self.isValid(stored) else { return nil }
        cleanup = stored[Self.cleanupKey].flatMap(DictationCleanupMode.init(rawValue:))
        switch stored[Self.transformKey] {
        case nil: transform = nil
        case Self.off: transform = .off
        case let value?: transform = UUID(uuidString: value).map(Transform.transform)
        }
    }

    var stored: [String: String] {
        var stored: [String: String] = [:]
        if let cleanup { stored[Self.cleanupKey] = cleanup.rawValue }
        switch transform {
        case .off: stored[Self.transformKey] = Self.off
        case .transform(let id): stored[Self.transformKey] = id.uuidString
        case nil: break
        }
        return stored
    }

    static func isValid(_ stored: [String: String]) -> Bool {
        stored.keys.allSatisfy { $0 == cleanupKey || $0 == transformKey }
            && stored[cleanupKey].map { DictationCleanupMode(rawValue: $0) != nil } ?? true
            && stored[transformKey].map { $0 == off || UUID(uuidString: $0) != nil } ?? true
    }

    static func resolve(bundleID: String?, in overrides: [String: [String: String]]) -> Self? {
        bundleID.flatMap { overrides[$0] }.flatMap(Self.init(stored:))
    }

    private static let cleanupKey = "cleanup"
    private static let transformKey = "transform"
    private static let off = "off"
}
