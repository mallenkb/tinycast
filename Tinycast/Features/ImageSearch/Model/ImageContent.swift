import Foundation

nonisolated struct ImageContent: Codable, Sendable {
    let text: String
    let caption: String?

    var version: Int { caption == nil ? 1 : 2 }
    var searchText: String { [text, caption ?? ""].filter { !$0.isEmpty }.joined(separator: "\n") }

    static func terms(in query: String) -> [String] {
        let filler: Set<String> = [
            "a", "an", "the", "of", "on", "in", "at", "with", "that", "is", "are", "showing", "shows",
            "image", "images", "picture", "pictures", "photo", "photos", "screenshot", "screenshots",
            "video", "videos", "movie", "movies", "clip", "clips",
        ]
        return query.split(whereSeparator: \.isWhitespace).map(String.init)
            .filter { !filler.contains($0.lowercased()) }
    }
}
