import AppKit

/// A word the system spell checker accepts is real vocabulary, so changing it is a choice, not a fix.
enum DictationSpellingLexicon {
    nonisolated static func contains(_ word: String) -> Bool {
        MainActor.assumeIsolated {
            NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0).location == NSNotFound
        }
    }
}
