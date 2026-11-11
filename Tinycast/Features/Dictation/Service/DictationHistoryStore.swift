import AppKit

struct DictationHistoryEntry: Identifiable, Codable, Sendable {
    let id: UUID
    var text: String
    var originalText: String?
    let createdAt: Date
    let pastedAppBundleID: String?
    let pastedAppName: String?
}

@MainActor
@Observable
final class DictationHistoryStore {
    private let fileURL = AppPaths.applicationSupport().appending(path: "dictation-history.json")
    private var retention: ClipboardRetention

    private(set) var entries: [DictationHistoryEntry] = []

    init(retention: ClipboardRetention) {
        self.retention = retention
        if let data = try? Data(contentsOf: fileURL),
            let saved = try? JSONDecoder().decode([DictationHistoryEntry].self, from: data)
        {
            entries = saved
            pruneExpired()
        }
    }

    func record(_ text: String, originalText: String? = nil, pastedInto app: NSRunningApplication?) {
        let now = Date()
        entries.insert(
            DictationHistoryEntry(
                id: UUID(), text: text, originalText: originalText, createdAt: now,
                pastedAppBundleID: app?.bundleIdentifier, pastedAppName: app?.localizedName),
            at: 0)
        _ = removeExpired(now: now)
        persist()
    }

    func replace(id: UUID, text: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        if entries[index].originalText == nil { entries[index].originalText = entries[index].text }
        entries[index].text = text
        persist()
    }

    func restore(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }), let original = entries[index].originalText else { return }
        entries[index].text = original
        entries[index].originalText = nil
        persist()
    }

    func setRetention(_ retention: ClipboardRetention) {
        self.retention = retention
        pruneExpired()
    }

    func pruneExpired() {
        if removeExpired(now: Date()) { persist() }
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    func search(_ query: String) -> [DictationHistoryEntry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? entries : entries.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    private func removeExpired(now: Date) -> Bool {
        guard retention != .forever else { return false }
        let cutoff = now.addingTimeInterval(-retention.maxAge)
        guard entries.contains(where: { $0.createdAt < cutoff }) else { return false }
        entries.removeAll { $0.createdAt < cutoff }
        return true
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
