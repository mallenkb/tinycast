import Foundation

@MainActor
@Observable
final class DictationCorrectionStore {
    private enum Failure: LocalizedError {
        case full
        case entryTooLong

        var errorDescription: String? {
            switch self {
            case .full: String(localized: "Remove a dictionary entry before adding another.")
            case .entryTooLong: String(localized: "Dictionary words and misspellings can be up to 60 characters.")
            }
        }
    }

    private static let limit = 100
    private let fileURL: URL
    private(set) var entries: [DictationCorrection]

    init(fileURL: URL = AppPaths.applicationSupport().appending(path: "dictation-corrections.json")) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
            let stored = try? JSONDecoder().decode([DictationCorrection].self, from: data)
        {
            entries = Array(stored.prefix(Self.limit))
        } else {
            entries = []
        }
    }

    func record(_ correction: DictationCorrection) throws {
        if !correction.isManual, entries.contains(where: { $0.isManual && $0.id == correction.id }) {
            return
        }
        var updated = entries.filter { $0.id != correction.id }
        if correction.isManual {
            guard correction.original.count <= 60, correction.spelling.count <= 60 else { throw Failure.entryTooLong }
            guard updated.lazy.filter(\.isManual).count < Self.limit else { throw Failure.full }
        }
        if correction.isManual || correction.id != DictationCorrection.key(for: correction.spelling) {
            updated.insert(correction, at: 0)
        }
        let manual = updated.filter(\.isManual)
        let learned = updated.lazy.filter { !$0.isManual }.prefix(Self.limit - manual.count)
        try save(manual + Array(learned))
    }

    func remove(_ correction: DictationCorrection) throws {
        try save(entries.filter { $0.id != correction.id })
    }

    private func save(_ updated: [DictationCorrection]) throws {
        let data = try JSONEncoder().encode(updated)
        try data.write(to: fileURL, options: .atomic)
        entries = updated
    }
}
