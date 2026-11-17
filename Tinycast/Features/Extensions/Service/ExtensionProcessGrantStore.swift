import Foundation

/// Extensions the user let start processes; its own file, so no backup or settings.json carries it.
@MainActor
@Observable
final class ExtensionProcessGrantStore {
    private let fileURL: URL
    private(set) var granted: Set<String>

    init(fileURL: URL) {
        self.fileURL = fileURL
        granted =
            (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) } ?? []
    }

    func contains(_ name: String) -> Bool { granted.contains(name) }

    func grant(_ name: String) { update { $0.insert(name) } }

    /// Also called on every reinstall and update: a grant covers the code the user saw ask.
    func revoke(_ name: String) { update { $0.remove(name) } }

    private func update(_ body: (inout Set<String>) -> Void) {
        var next = granted
        body(&next)
        guard next != granted else { return }
        granted = next
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(granted.sorted()) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
