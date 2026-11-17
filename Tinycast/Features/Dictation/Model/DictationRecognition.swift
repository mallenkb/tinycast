import Foundation

nonisolated struct DictationRecognition: Codable, Hashable, Sendable {
    var text: String
    var pauses: [DictationPause] = []
}

nonisolated struct DictationPause: Codable, Hashable, Sendable {
    /// Index into the text's whitespace-separated words.
    let word: Int
    let milliseconds: Int
}
