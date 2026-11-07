import Foundation

@MainActor
@Observable
final class DictionarySavedWordsStore {
    private static let key = "dictionarySavedWords"
    private let defaults: UserDefaults
    private(set) var words: [String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        words = defaults.stringArray(forKey: Self.key) ?? []
    }

    func contains(_ word: String) -> Bool {
        index(of: word) != nil
    }

    func toggle(_ word: String) {
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        if let index = index(of: word) {
            words.remove(at: index)
        } else {
            words.insert(word, at: 0)
        }
        defaults.set(words, forKey: Self.key)
    }

    private func index(of word: String) -> Int? {
        words.firstIndex { $0.caseInsensitiveCompare(word) == .orderedSame }
    }
}
