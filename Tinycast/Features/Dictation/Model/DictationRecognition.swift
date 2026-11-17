import Foundation

nonisolated struct DictationRecognition: Codable, Hashable, Sendable {
    var text: String
    var pauses: [DictationPause] = []

    func appending(_ tail: Self) -> Self {
        let offset = text.split(whereSeparator: \.isWhitespace).count
        return Self(
            text: text + " " + tail.text,
            pauses: pauses + tail.pauses.map { DictationPause(word: offset + $0.word, milliseconds: $0.milliseconds) })
    }
}

nonisolated struct DictationPause: Codable, Hashable, Sendable {
    /// Index into the text's whitespace-separated words.
    let word: Int
    let milliseconds: Int
}
