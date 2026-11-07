import Foundation

nonisolated enum SearchIntentPolicy {
    private typealias Kind = SearchDescription.Kind
    private typealias DateRange = SearchIntent.DateRange

    private static let kinds: [String: Kind] = [
        "file": .files, "files": .files, "folder": .folders, "folders": .folders,
        "directory": .folders, "directories": .folders, "document": .documents, "documents": .documents,
        "image": .images, "images": .images, "photo": .images, "photos": .images,
        "screenshot": .images, "screenshots": .images, "picture": .images, "pictures": .images,
        "audio": .audio, "music": .audio, "video": .video, "videos": .video,
        "archive": .archives, "archives": .archives, "text": .text, "clip": .text, "clips": .text,
        "link": .links, "links": .links, "url": .links, "urls": .links,
    ]
    private static let formats: [String: Kind] = [
        "pdf": .documents, "csv": .documents, "docx": .documents, "xlsx": .documents,
        "pptx": .documents, "txt": .documents, "png": .images, "jpg": .images, "jpeg": .images,
        "gif": .images, "heic": .images, "svg": .images, "webp": .images, "mp3": .audio,
        "wav": .audio, "mp4": .video, "mov": .video, "zip": .archives,
    ]
    private static let homeFolders = ["Downloads", "Documents", "Desktop", "Pictures", "Movies", "Music"]
    private static let topicMarkers: Set<String> = ["about", "called", "containing", "named", "showing", "with"]
    private static let filler: Set<String> = [
        "a", "an", "and", "all", "the", "me", "my", "i", "in", "on", "from", "for", "to", "of", "that",
        "find", "search", "show", "get", "saved", "copied", "modified", "edited", "changed", "took", "please",
    ]
    private static let unsupportedOperators: Set<String> = [
        "not", "except", "excluding", "exclude", "without", "neither", "nor", "never", "or",
        "don't", "don’t", "dont", "isn't", "isn’t", "aren't", "aren’t",
    ]
    private static let unsupportedFileEvents: Set<String> = [
        "download", "downloaded", "downloading", "created", "opened", "accessed", "received", "added",
    ]
    private static let datePhrases: [(String, DateRange)] = [
        ("today", .today), ("yesterday", .yesterday), ("this week", .thisWeek), ("last week", .lastWeek),
        ("last seven days", .lastSevenDays), ("last 7 days", .lastSevenDays),
        ("past seven days", .lastSevenDays), ("past 7 days", .lastSevenDays), ("last month", .lastMonth),
    ]

    static func intent(
        destination: SearchIntent.Destination, query: String, kind: String, website: String?,
        time: String?, websites: [String], now: Date, calendar: Calendar
    ) -> SearchIntent? {
        guard destination == .files || destination == .clipboard, query.count <= 512,
            allowsInterpretation(query)
        else { return nil }
        let words = tokens(query)
        let keys = words.map { $0.lowercased() }
        let contentStart = keys.firstIndex(where: topicMarkers.contains) ?? keys.endIndex
        let constraints = Array(keys[..<contentStart])
        guard destination != .files || !constraints.contains(where: unsupportedFileEvents.contains) else {
            return nil
        }
        var consumed = IndexSet()
        guard let date = dateRange(in: constraints, proposed: time, consumed: &consumed) else { return nil }
        for phrase in ["i'm looking for", "i’m looking for", "i am looking for", "looking for",
            "can you", "could you", "i need", "from somewhere"]
        {
            for match in occurrences(of: tokens(phrase), in: constraints) { consumed.insert(integersIn: match) }
        }
        let dates = SearchIntent.dates(date, start: "", end: "", now: now, calendar: calendar)
        guard date == .any || dates != nil else { return nil }

        let folder = folder(in: keys, before: contentStart, consumed: &consumed)
        let formatWords = keys.indices.filter {
            $0 < contentStart && !consumed.contains($0) && formats[fileExtension(keys[$0])] != nil
        }
        let extensions = Set(formatWords.map { fileExtension(keys[$0]) })
        guard extensions.count <= 1 else { return nil }
        let ext = extensions.first
        consumed.formUnion(IndexSet(formatWords))

        let kindWords = keys.indices.filter {
            $0 < contentStart && !consumed.contains($0) && kinds[keys[$0]] != nil
        }
        let explicitKinds = kindWords.compactMap { kinds[keys[$0]] }
        let proposedKind = Kind(rawValue: kind.lowercased())
        let selectedKind = ext.flatMap { formats[$0] }
            ?? proposedKind.flatMap { explicitKinds.contains($0) ? $0 : nil }
            ?? explicitKinds.first(where: { $0 != .files }) ?? explicitKinds.first ?? .any
        consumed.formUnion(IndexSet(kindWords.filter {
            kinds[keys[$0]] == selectedKind || kinds[keys[$0]] == .files
        }))

        let host: String?
        if destination == .clipboard {
            guard folder == nil, ext == nil,
                [.any, .files, .images, .video, .links, .text].contains(selectedKind)
            else { return nil }
            if selectedKind == .links,
                let source = websiteWord(in: keys, proposed: website, excluding: consumed, before: contentStart)
            {
                guard let normalized = normalizedHost(keys[source], known: websites) else { return nil }
                host = normalized
                consumed.insert(source)
            } else {
                host = nil
            }
        } else {
            guard selectedKind != .links else { return nil }
            host = nil
        }
        let text = topicText(words, keys: keys, contentStart: contentStart, excluding: consumed)
        guard selectedKind != .any || !text.isEmpty || dates != nil || folder != nil else { return nil }
        let description = SearchDescription(
            kind: selectedKind, text: text,
            alternativeTexts: alternatives(for: text, destination: destination),
            fileExtension: ext, folder: folder, dates: dates, website: host)
        return SearchIntent(destination: destination, description: description, commandID: nil)
    }

    static func allowsInterpretation(_ query: String) -> Bool {
        let words = tokens(query.lowercased())
        let end = words.firstIndex(where: topicMarkers.contains) ?? words.endIndex
        guard !words[..<end].contains(where: unsupportedOperators.contains) else { return false }
        let prefix = query.split(whereSeparator: \.isWhitespace).prefix(end)
        return !prefix.contains { $0.contains("\"") || $0.contains("“") || $0.contains("”") }
    }

    static func unambiguousCommands(_ commands: [SearchIntent.Command]) -> [SearchIntent.Command] {
        let titles = Dictionary(grouping: commands, by: { $0.title.lowercased() })
        let ids = Dictionary(grouping: commands, by: \.id)
        return commands.filter { titles[$0.title.lowercased()]?.count == 1 && ids[$0.id]?.count == 1 }
    }

    private static func tokens(_ text: String) -> [String] {
        let edges = CharacterSet(charactersIn: ",!?;()[]{}\"“”'‘’")
        return text.split(whereSeparator: \.isWhitespace)
            .map {
                let word = $0.trimmingCharacters(in: edges)
                return word.hasSuffix(".") ? String(word.dropLast()) : word
            }
            .filter { !$0.isEmpty }
    }

    private static func occurrences(of phrase: [String], in words: [String]) -> [Range<Int>] {
        guard !phrase.isEmpty, phrase.count <= words.count else { return [] }
        return (0...(words.count - phrase.count)).compactMap { start in
            let range = start..<(start + phrase.count)
            return words[range].elementsEqual(phrase) ? range : nil
        }
    }

    private static func dateRange(
        in words: [String], proposed: String?, consumed: inout IndexSet
    ) -> DateRange? {
        var date = DateRange.any
        for (phrase, range) in datePhrases {
            for match in occurrences(of: tokens(phrase), in: words) {
                let start = match.lowerBound
                let previous = start > 0 ? words[start - 1] : ""
                guard !topicMarkers.contains(previous) else { continue }
                guard date == .any, !["after", "before", "since", "until", "through", "not"].contains(previous),
                    !(start > 1 && ["not", "except"].contains(words[start - 2]))
                else { return nil }
                date = range
                consumed.insert(integersIn: match)
                if previous == "the" { consumed.insert(start - 1) }
            }
        }
        guard words.indices.allSatisfy({ index in
            guard !consumed.contains(index), isTemporalWord(words[index]) else { return true }
            return words[index].allSatisfy(\.isNumber)
                && (index == 0 || !["from", "in", "on", "after", "before", "since"].contains(words[index - 1]))
        }) else { return nil }
        let proposedWords = tokens(proposed?.lowercased() ?? "")
        if proposedWords.contains(where: isTemporalWord) {
            for match in occurrences(of: proposedWords, in: words) {
                let start = match.lowerBound
                guard start == 0 || !topicMarkers.contains(words[start - 1]) else { continue }
                guard match.allSatisfy({ consumed.contains($0) || filler.contains(words[$0]) }) else {
                    return nil
                }
            }
        }
        return date
    }

    private static func isTemporalWord(_ word: String) -> Bool {
        switch word {
        case "today", "yesterday", "tomorrow", "tonight", "recently", "ago", "noon", "midnight",
            "morning", "afternoon", "evening", "day", "days", "week", "weeks", "month", "months",
            "year", "years", "hour", "hours", "minute", "minutes", "second", "seconds",
            "spring", "summer", "autumn", "fall", "winter", "monday", "tuesday", "wednesday",
            "thursday", "friday", "saturday", "sunday", "january", "february", "march", "april",
            "may", "june", "july", "august", "september", "october", "november", "december":
            return true
        default:
            return word.count >= 4 && word.first?.isNumber == true
                && word.allSatisfy { $0.isNumber || $0 == "-" || $0 == "/" || $0 == ":" }
        }
    }

    private static func folder(in words: [String], before end: Int, consumed: inout IndexSet) -> String? {
        for index in 0..<end where words[index] == "in" {
            let start = index + 1
            let name = start < end && words[start] == "my" ? start + 1 : start
            guard name < end,
                let folder = homeFolders.first(where: {
                    words[name] == $0.lowercased() || words[name] == "~/" + $0.lowercased()
                })
            else { continue }
            consumed.insert(integersIn: index..<(name + 1))
            if name + 1 < end, words[name + 1] == "folder" { consumed.insert(name + 1) }
            return folder
        }
        return nil
    }

    private static func fileExtension(_ word: String) -> String {
        if word == "pdfs" { return "pdf" }
        return word.hasPrefix(".") ? String(word.dropFirst()) : word
    }

    private static func websiteWord(
        in words: [String], proposed: String?, excluding consumed: IndexSet, before end: Int
    ) -> Int? {
        for index in 0..<end where words[index] == "from" {
            let start = index + 1
            let source = start < end && words[start] == "the" ? start + 1 : start
            if source < end, !consumed.contains(source), !filler.contains(words[source]) { return source }
        }
        guard let proposed, let word = tokens(proposed.lowercased()).only,
            let index = words[..<end].firstIndex(of: word), !consumed.contains(index)
        else { return nil }
        return index
    }

    private static func normalizedHost(_ source: String, known hosts: [String]) -> String? {
        let address = source.contains("://") ? source : "https://" + source
        guard let url = URLComponents(string: address), let host = url.host?.lowercased(), !host.isEmpty,
            ["http", "https"].contains(url.scheme), url.user == nil, url.password == nil
        else { return nil }
        if host.contains(".") { return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }

        var exact = Set<String>()
        var close = Set<String>()
        for known in hosts {
            let labels = known.lowercased().split(separator: ".")
            for index in labels.indices.dropLast() where labels[index] != "www" {
                let label = String(labels[index])
                let domain = labels[index...].joined(separator: ".")
                if label == host {
                    exact.insert(domain)
                } else if label.count >= 4, host.count >= 4, differsByOneEdit(label, host) {
                    close.insert(domain)
                }
            }
        }
        return exact.only ?? (exact.isEmpty ? close.only : nil) ?? host
    }

    private static func differsByOneEdit(_ first: String, _ second: String) -> Bool {
        let shorter = first.count <= second.count ? Array(first) : Array(second)
        let longer = first.count <= second.count ? Array(second) : Array(first)
        guard longer.count - shorter.count <= 1 else { return false }
        if shorter.count == longer.count { return zip(shorter, longer).filter(!=).count == 1 }
        let difference = shorter.indices.first { shorter[$0] != longer[$0] } ?? shorter.count
        return shorter[difference...].elementsEqual(longer[(difference + 1)...])
    }

    private static func alternatives(for text: String, destination: SearchIntent.Destination) -> [String] {
        let words = tokens(text)
        guard destination == .files, let word = words.only, word.count > 4, word.allSatisfy(\.isLetter) else {
            return []
        }
        let key = word.lowercased()
        if key.hasSuffix("ies") { return [String(word.dropLast(3)) + "y"] }
        if key.hasSuffix("s"), !["ss", "us", "is"].contains(where: key.hasSuffix) {
            return [String(word.dropLast())]
        }
        return []
    }

    private static func topicText(
        _ words: [String], keys: [String], contentStart: Int, excluding consumed: IndexSet
    ) -> String {
        let available = keys.indices.filter {
            $0 > contentStart || ($0 < contentStart && !consumed.contains($0) && !filler.contains(keys[$0]))
        }
        return available.map { words[$0] }.joined(separator: " ")
    }
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}
