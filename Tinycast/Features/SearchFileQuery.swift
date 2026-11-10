import Foundation

nonisolated enum SearchFileQuery {
    enum Issue: Sendable, Equatable {
        case invalidDate
        case ambiguousDate(String, [String])
        case invalidFilter
        case unclosedQuote
    }
    enum Result: Sendable {
        case literal
        case filters(SearchFileConstraints)
        case issue(Issue)
    }
    private struct Word {
        let text: String
        let raw: String
        let quoted: Bool
        var key: String {
            quoted ? text : text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ","))
        }
    }
    private static let categories: [String: SearchFileConstraints.Category] = [
        "file": .files, "files": .files, "folder": .folders, "folders": .folders,
        "document": .documents, "documents": .documents, "spreadsheet": .spreadsheets,
        "spreadsheets": .spreadsheets,
        "presentation": .presentations, "presentations": .presentations, "image": .images, "images": .images,
        "photo": .images, "photos": .images, "screenshots": .images, "audio": .audio, "music": .audio,
        "video": .video, "videos": .video, "archives": .archives, "archive": .archives,
        "code": .code, "applications": .applications, "apps": .applications, "fonts": .fonts
    ]
    private static let markers: Set<String> = [
        "in", "from", "on", "modify", "modified", "edit", "edited", "changed", "create", "created",
        "download", "downloaded", "added", "before", "after", "between",
        "named", "called", "containing", "contains", "with", "excluding", "except", "tagged", "extension",
        "extensions", "format", "formats", "larger", "smaller", "empty", "size", "sort", "sorted", "largest",
        "smallest", "newest", "oldest", "name", "relevance", "without", "only", "recursively"
    ]
    private static let eventVerbs: Set<String> = ["download", "create", "edit", "modify"]

    static func parse(_ query: String, now: Date, calendar: Calendar) -> Result {
        guard query.utf8.count <= 2048 else { return .literal }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let words = tokenize(trimmed) else { return .issue(.unclosedQuote) }
        guard !words.isEmpty else { return .literal }
        let sentence = trimmed.last.map { ".?!".contains($0) } == true
            ? tokenize(String(trimmed.dropLast())) : nil
        if let canonical = latestFolderQuery(sentence ?? words), let normalized = tokenize(canonical) {
            return read(normalized, now: now, calendar: calendar)
        }
        let result = read(words, now: now, calendar: calendar)
        if case .filters = result { return result }
        if let sentence, !sentence.isEmpty {
            let corrected = read(sentence, now: now, calendar: calendar)
            if case .literal = corrected { return result }
            return corrected
        }
        return result
    }

    private static func read(_ words: [Word], now: Date, calendar: Calendar) -> Result {
        var reader = Reader(words: words, now: now, calendar: calendar)
        do { return try reader.parse() } catch SearchCalendarDate.Failure.invalid {
            return .issue(.invalidDate)
        } catch SearchCalendarDate.Failure.ambiguous(let text, let choices) {
            return .issue(.ambiguousDate(text, choices))
        } catch { return .issue(.invalidFilter) }
    }

    private static func latestFolderQuery(_ words: [Word]) -> String? {
        let request = words.drop(while: {
            !$0.quoted && ["what", "which", "was", "is", "find", "show", "me", "the"].contains($0.key)
        })
        guard request.count >= 4, request.prefix(2).allSatisfy({ !$0.quoted }),
            let first = request.first, ["latest", "newest"].contains(first.key),
            categories[request[request.index(after: request.startIndex)].key] == .folders
        else { return nil }
        var tail = request.dropFirst(2)
        if tail.first?.key == "i", tail.first?.quoted == false { tail = tail.dropFirst() }
        let added = tail.first?.key == "added" && tail.first?.quoted == false
        if added { tail = tail.dropFirst() }
        guard let relation = tail.first, !relation.quoted, relation.key == "in" || (added && relation.key == "to")
        else { return nil }
        let location = tail.dropFirst()
        guard !location.isEmpty,
            location.count == 1 || location.allSatisfy({ !$0.quoted && !markers.contains($0.key) })
        else { return nil }
        var path = location.map(\.text).joined(separator: " ")
        if location.first?.quoted == false, path.lowercased().hasPrefix("/my "), !path.dropFirst().contains("/") {
            path = "~" + path
        }
        let escaped = path.replacingOccurrences(of: "\"", with: "\\\"")
        let order = added ? "newest added first" : "newest first"
        return "folders in \"\(escaped)\" without subfolders \(order)"
    }

    static func resolvingDate(in query: String, token: String, choice: String) -> String {
        guard let words = tokenize(query),
            let index = words.indices.first(where: { index in
                let word = words[index]
                guard !word.quoted else { return false }
                return word.key == token || (index == words.count - 1
                    && [".", "?", "!"].contains { word.key == token + $0 })
            })
        else { return query }
        return words.enumerated().map { $0.offset == index ? choice : $0.element.raw }.joined(separator: " ")
    }

    private static func tokenize(_ query: String) -> [Word]? {
        let chars = Array(query)
        var index = 0
        var words: [Word] = []
        while index < chars.count {
            if chars[index].isWhitespace || chars[index] == "," { index += 1; continue }
            let start = index
            if chars[index] == "\"" || chars[index] == "“" {
                let closing: Character = chars[index] == "“" ? "”" : "\""
                index += 1
                var text = ""
                while index < chars.count, chars[index] != closing {
                    if chars[index] == "\\", index + 1 < chars.count, chars[index + 1] == closing {
                        index += 1
                    }
                    text.append(chars[index]); index += 1
                }
                guard index < chars.count else { return nil }
                index += 1
                words.append(Word(text: text, raw: String(chars[start..<index]), quoted: true))
            } else {
                while index < chars.count, !chars[index].isWhitespace, chars[index] != "," { index += 1 }
                let text = String(chars[start..<index])
                words.append(Word(text: text, raw: text, quoted: false))
            }
        }
        return words
    }

    private struct Reader {
        let words: [Word]
        let now: Date
        let calendar: Calendar
        var index = 0
        var value = SearchFileConstraints()
        var fields = Set<SearchFileConstraints.Field>()
        var key: String { index < words.count && !words[index].quoted ? words[index].key : "" }
        enum Failure: Error { case invalid }

        mutating func parse() throws -> Result {
            while ["find", "show", "search", "for", "me", "all", "my", "the", "what", "which"].contains(key) { index += 1 }
            let start = index
            if let category = categories[key] {
                value.category = category
                index += 1
                if key == "files" { index += 1 }
                add(.category, from: start, detail: category.rawValue)
            } else if let ext = format(at: index, allowAny: false) {
                value.category = .files
                value.extensions = [ext]
                index += 1
                while key == "or" {
                    index += 1
                    guard let next = format(at: index, allowAny: true) else { throw Failure.invalid }
                    value.extensions.append(next); index += 1
                }
                if ["file", "files"].contains(key) { index += 1 }
                add(.format, from: start, detail: value.extensions.map { "." + $0 }.joined(separator: ", "))
            }
            while index < words.count {
                let start = index
                switch key {
                case "extension", "extensions", "format", "formats":
                    try unique(.format)
                    index += 1
                    value.extensions = try formats()
                    add(
                        .format, from: start,
                        detail: value.extensions.map { "." + $0 }.joined(separator: ", "))
                case "in":
                    index += 1
                    if index < words.count, !words[index].quoted, dateStarts(words[index].key) {
                        try date(.modified, from: start)
                    } else {
                        try unique(.folder)
                        value.folder = try folderArgument()
                        if key == "folder" { index += 1 }
                        add(.folder, from: start, detail: value.folder!)
                    }
                case "only", "without":
                    guard index + 1 < words.count, ["subfolders", "here"].contains(words[index + 1].key)
                    else {
                        throw Failure.invalid
                    }
                    value.recursive = false; index += 2
                    add(.folder, from: start, detail: words[start..<index].map(\.text).joined(separator: " "))
                case "recursively":
                    value.recursive = true; index += 1
                    add(.folder, from: start, detail: "recursive")
                case "did" where !value.clauses.isEmpty && index + 2 < words.count
                    && !words[index + 1].quoted && words[index + 1].key == "i"
                    && !words[index + 2].quoted && eventVerbs.contains(words[index + 2].key):
                    index += 2
                case "and" where !value.clauses.isEmpty && index + 1 < words.count
                    && !words[index + 1].quoted && (eventVerbs.contains(words[index + 1].key)
                        || ["modified", "edited", "created", "downloaded", "added"].contains(words[index + 1].key)):
                    index += 1
                case "from", "on", "modify", "modified", "edit", "edited", "changed",
                    "create", "created", "download", "downloaded", "added", "before", "after":
                    let field: SearchFileConstraints.Field = switch key {
                    case "create", "created": .created
                    case "download", "downloaded": .downloaded
                    case "added": .added
                    default: .modified
                    }
                    if field != .modified, value.clauses.isEmpty, index + 1 < words.count,
                        categories[words[index + 1].key] != nil || format(at: index + 1, allowAny: false) != nil
                    {
                        return .literal
                    }
                    if !["before", "after"].contains(key) { index += 1 }
                    if ["on", "in", "from"].contains(key) { index += 1 }
                    try date(field, from: start)
                case "between":
                    if words.dropFirst(index).prefix(8).contains(where: { sizeMultiplier($0.key) != nil }) {
                        try size(from: start)
                    } else {
                        try date(.modified, from: start)
                    }
                case "named", "called":
                    try unique(.name); index += 1
                    if key == "exactly" {
                        value.nameMode = .exact; index += 1
                    } else if key == "starting" || key == "starts" {
                        value.nameMode = .prefix; index += 1; if key == "with" { index += 1 }
                    } else if key == "ending" || key == "ends" {
                        value.nameMode = .suffix; index += 1; if key == "with" { index += 1 }
                    }
                    value.name = try phrase()
                    add(.name, from: start, detail: value.name)
                case "containing", "contains", "with":
                    try unique(.content); index += 1
                    if ["all", "any"].contains(key) {
                        value.textMode = key == "all" ? .all : .any; index += 1
                        if ["words", "word"].contains(key) { index += 1 }
                        value.content = try arguments()
                    } else {
                        if key == "exactly" { index += 1 }
                        value.content = [try phrase()]
                    }
                    add(.content, from: start, detail: value.content.joined(separator: ", "))
                case "tagged":
                    try unique(.tags); index += 1
                    let explicitlyAll = key == "all"
                    if ["all", "any"].contains(key) { value.allTags = key == "all"; index += 1 }
                    if words.dropFirst(index).prefix(while: { $0.quoted || !markers.contains($0.key) })
                        .contains(where: { !$0.quoted && $0.key == "or" })
                    {
                        guard !explicitlyAll else { throw Failure.invalid }
                        value.allTags = false
                    }
                    value.tags = try arguments()
                    add(.tags, from: start, detail: value.tags.joined(separator: ", "))
                case "excluding", "except":
                    index += 1
                    let target = key
                    if ["folder", "folders", "name", "names", "tag", "tags", "format", "formats"].contains(
                        key)
                    {
                        index += 1
                    }
                    switch target {
                    case "folder", "folders": value.excludedFolders += try arguments()
                    case "name", "names": value.excludedNames += try arguments()
                    case "tag", "tags": value.excludedTags += try arguments()
                    default: value.excludedExtensions += try formats()
                    }
                    add(
                        .excluded, from: start,
                        detail: words[start..<index].map(\.text).joined(separator: " "))
                case "larger", "smaller", "empty", "size": try size(from: start)
                case "sort", "sorted", "largest", "smallest", "newest", "oldest", "name", "relevance":
                    try unique(.order)
                    if ["sort", "sorted"].contains(key) { index += 1; if key == "by" { index += 1 } }
                    guard let order = SearchFileConstraints.Order(rawValue: key) else {
                        throw Failure.invalid
                    }
                    value.order = order; index += 1
                    if key == "added", order == .newest || order == .oldest {
                        value.order = order == .newest ? .newestAdded : .oldestAdded
                        index += 1
                    } else if key == "modified" { index += 1 }
                    if key == "first" { index += 1 }
                    add(.order, from: start, detail: order.rawValue)
                default:
                    if !value.clauses.isEmpty, dateStarts(key) {
                        try date(.modified, from: start)
                    } else if value.clauses.count <= 1 {
                        return .literal
                    } else {
                        throw Failure.invalid
                    }
                }
                guard index > start, value.clauses.count <= 24 else { throw Failure.invalid }
            }
            guard !value.clauses.isEmpty else { return .literal }
            if value.clauses.count == 1, words.count == 1, fields == [.format], !words[0].key.hasPrefix(".") {
                return .literal
            }
            return .filters(value)
        }

        mutating func date(_ field: SearchFileConstraints.Field, from start: Int) throws {
            try unique(field)
            if key == "the" { index += 1 }
            let match = try SearchCalendarDate.match(
                words.dropFirst(index).map(\.key), now: now, calendar: calendar)
            switch field {
            case .created: value.created = match.bounds
            case .downloaded: value.downloaded = match.bounds
            case .added: value.added = match.bounds
            default: value.modified = match.bounds
            }
            index += match.count
            add(field, from: start, detail: match.detail)
        }

        mutating func size(from start: Int) throws {
            try unique(.size)
            if key == "size" { index += 1 }
            let mode = key; index += 1
            if mode == "empty" {
                value.minimumSize = 0; value.maximumSize = 0
                if key == "files" { index += 1 }
            } else if mode == "between" {
                let lower = try bytes()
                guard key == "and" else { throw Failure.invalid }; index += 1
                let upper = try bytes()
                guard lower <= upper else { throw Failure.invalid }
                value.minimumSize = lower; value.maximumSize = upper
            } else {
                guard ["larger", "smaller"].contains(mode) else { throw Failure.invalid }
                if key == "than" { index += 1 }
                let amount = try bytes()
                if mode == "larger" {
                    guard amount < Int64.max else { throw Failure.invalid }
                    value.minimumSize = amount + 1
                } else {
                    guard amount > 0 else { throw Failure.invalid }
                    value.maximumSize = amount - 1
                }
            }
            add(.size, from: start, detail: words[start..<index].map(\.text).joined(separator: " "))
        }

        mutating func bytes() throws -> Int64 {
            guard let amount = Double(key), amount.isFinite, amount >= 0 else { throw Failure.invalid }
            index += 1
            guard let multiplier = sizeMultiplier(key) else { throw Failure.invalid }
            let total = amount * multiplier
            guard total < Double(Int64.max) else { throw Failure.invalid }
            index += 1
            return Int64(total.rounded(.down))
        }
        func sizeMultiplier(_ key: String) -> Double? {
            switch key {
            case "b", "byte", "bytes": 1
            case "kb": 1_000
            case "mb": 1_000_000
            case "gb": 1_000_000_000
            case "tb": 1_000_000_000_000
            case "kib": 1_024
            case "mib": 1_048_576
            case "gib": 1_073_741_824
            default: nil
            }
        }
        mutating func formats() throws -> [String] {
            var result: [String] = []
            repeat {
                guard let ext = format(at: index, allowAny: true) else { throw Failure.invalid }
                result.append(ext); index += 1
                if ["file", "files"].contains(key) { index += 1 }
                guard ["or", "and"].contains(key) else { break }
                index += 1
                guard index < words.count else { throw Failure.invalid }
            } while index < words.count
            return result
        }
        func format(at index: Int, allowAny: Bool) -> String? {
            guard index < words.count, !words[index].quoted else { return nil }
            let key = words[index].key
            if let known = SearchDescription.fileFormat(key) { return known.extension }
            guard
                allowAny || key.hasPrefix(".") || (index + 1 < words.count && words[index + 1].key == "files")
            else { return nil }
            let ext = key.hasPrefix(".") ? String(key.dropFirst()) : key
            guard !ext.isEmpty, ext.count <= 48, !ext.hasSuffix("."), !ext.contains(".."),
                ext.allSatisfy({
                    $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_")
                }),
                !markers.contains(ext), !["or", "and"].contains(ext)
            else { return nil }
            return ext
        }
        mutating func argument() throws -> String {
            guard index < words.count, !words[index].text.isEmpty else { throw Failure.invalid }
            let result = words[index].text; index += 1
            return result
        }
        mutating func folderArgument() throws -> String {
            let quoted = index < words.count && words[index].quoted
            let first = try argument()
            guard !quoted else { return first }
            var components = [first]
            while index < words.count, !words[index].quoted, !markers.contains(key),
                !["folder", "did", "and"].contains(key), !dateStarts(key)
            {
                components.append(try argument())
            }
            return components.joined(separator: " ")
        }
        mutating func arguments() throws -> [String] {
            var result: [String] = []
            while index < words.count {
                if markers.contains(key) { break }
                if ["and", "or"].contains(key) {
                    guard !result.isEmpty else { throw Failure.invalid }
                    index += 1
                    guard index < words.count, !markers.contains(key), !["and", "or"].contains(key) else {
                        throw Failure.invalid
                    }
                }
                result.append(try argument())
            }
            guard !result.isEmpty else { throw Failure.invalid }
            return result
        }
        mutating func phrase() throws -> String {
            if index < words.count, words[index].quoted { return try argument() }
            var result: [String] = []
            while index < words.count { result.append(try argument()) }
            guard !result.isEmpty else { throw Failure.invalid }
            return result.joined(separator: " ")
        }
        mutating func unique(_ field: SearchFileConstraints.Field) throws {
            guard !fields.contains(field) else { throw Failure.invalid }
        }
        mutating func add(_ field: SearchFileConstraints.Field, from start: Int, detail: String) {
            fields.insert(field)
            value.clauses.append(
                .init(
                    field: field, expression: words[start..<index].map(\.raw).joined(separator: " "),
                    detail: detail))
        }
        func dateStarts(_ word: String) -> Bool {
            [
                "today", "yesterday", "this", "last", "past", "before", "after", "between", "monday",
                "tuesday",
                "wednesday", "thursday", "friday", "saturday", "sunday", "january", "february", "march",
                "april",
                "may", "june", "july", "august", "september", "october", "november", "december",
                "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "oct", "nov", "dec"
            ].contains(word)
                || word.first?.isNumber == true
        }
    }
}
