import Foundation

nonisolated struct SearchFileConstraints: Sendable, Equatable, Codable {
    enum Category: String, CaseIterable, Sendable, Codable {
        case all, files, folders, documents, spreadsheets, presentations, images, audio, video
        case archives, code, applications, fonts
    }
    enum NameMode: String, Sendable, Codable { case contains, exact, prefix, suffix }
    enum TextMode: String, Sendable, Codable { case phrase, all, any }
    enum Order: String, CaseIterable, Sendable, Codable {
        case relevance, newest, oldest, newestAdded, oldestAdded, name, largest, smallest
    }
    enum Field: String, Sendable, Codable {
        case category, format, folder, modified, created, downloaded, added, name, content, size, excluded, tags, order
    }
    struct Bounds: Sendable, Equatable, Codable {
        var start: Date?
        var end: Date?
        func contains(_ value: Date) -> Bool {
            (start.map { value >= $0 } ?? true) && (end.map { value < $0 } ?? true)
        }
    }
    struct Clause: Sendable, Equatable, Identifiable, Codable {
        let field: Field
        let expression: String
        let detail: String
        var id: String { field.rawValue + ":" + expression }
    }
    var category: Category = .all
    var extensions: [String] = []
    var folder: String?
    var recursive = true
    var modified: Bounds?
    var created: Bounds?
    var downloaded: Bounds?
    var added: Bounds?
    var name = ""
    var nameMode: NameMode = .contains
    var content: [String] = []
    var textMode: TextMode = .phrase
    var minimumSize: Int64?
    var maximumSize: Int64?
    var excludedExtensions: [String] = []
    var excludedFolders: [String] = []
    var excludedNames: [String] = []
    var excludedTags: [String] = []
    var tags: [String] = []
    var allTags = true
    var order: Order = .relevance
    var clauses: [Clause] = []

    var needsMetadata: Bool {
        created != nil || minimumSize != nil || maximumSize != nil || order == .largest || order == .smallest
    }
    var needsTags: Bool { !tags.isEmpty || !excludedTags.isEmpty }
    var needsAddedDate: Bool { added != nil || order == .newestAdded || order == .oldestAdded }

    func matchesName(_ candidate: String) -> Bool {
        if name.isEmpty, excludedNames.isEmpty { return true }
        let candidate = candidate.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let term = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard
            !excludedNames.contains(where: {
                candidate.contains(
                    $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
            })
        else {
            return false
        }
        if name.isEmpty { return true }
        switch nameMode {
        case .contains: return candidate.contains(term)
        case .exact: return candidate == term
        case .prefix: return candidate.hasPrefix(term)
        case .suffix: return candidate.hasSuffix(term)
        }
    }

    func matchesExtension(_ name: String) -> Bool {
        if extensions.isEmpty, excludedExtensions.isEmpty { return true }
        let name = name.lowercased()
        return (extensions.isEmpty || extensions.contains { name.hasSuffix("." + $0) })
            && !excludedExtensions.contains { name.hasSuffix("." + $0) }
    }

    func matchesTags(_ values: [String]) -> Bool {
        let values = Set(values.map { $0.lowercased() })
        guard !excludedTags.contains(where: { values.contains($0.lowercased()) }) else { return false }
        return tags.isEmpty
            || (allTags
                ? tags.allSatisfy { values.contains($0.lowercased()) }
                : tags.contains { values.contains($0.lowercased()) })
    }

    func query(replacing id: String, with expression: String?) -> String {
        clauses.compactMap { $0.id == id ? expression : $0.expression }.joined(separator: " ")
    }
}
