import Foundation

struct SearchDescription: Sendable, Equatable, Codable {
    enum Kind: String, Sendable, Codable { case any, files, folders, documents, images, audio, video, archives, text, links }

    let text: String
    let alternativeTexts: [String]
    let kind: Kind
    let fileExtension: String?
    let folder: String?
    let dates: DateInterval?
    let website: String?
    let fileConstraints: SearchFileConstraints?
    let matchesFilenameOnly: Bool

    init(
        kind: Kind, text: String, alternativeTexts: [String] = [], fileExtension: String? = nil,
        folder: String? = nil, dates: DateInterval? = nil, website: String? = nil,
        matchesFilenameOnly: Bool = false, fileConstraints: SearchFileConstraints? = nil
    ) {
        self.kind = kind
        self.text = text
        self.alternativeTexts = alternativeTexts
        self.fileExtension = fileExtension
        self.folder = folder
        self.dates = dates
        self.website = website
        self.matchesFilenameOnly = matchesFilenameOnly
        self.fileConstraints = fileConstraints
    }

    init(fileConstraints filters: SearchFileConstraints) {
        let kind: Kind
        switch filters.category {
        case .all: kind = .any
        case .files: kind = filters.extensions.first.flatMap { Self.fileFormat($0)?.kind } ?? .files
        case .folders: kind = .folders
        case .documents, .spreadsheets, .presentations: kind = .documents
        case .images: kind = .images
        case .audio: kind = .audio
        case .video: kind = .video
        case .archives: kind = .archives
        case .code, .applications, .fonts: kind = .files
        }
        let dates: DateInterval?
        if let start = filters.modified?.start, let end = filters.modified?.end {
            dates = DateInterval(start: start, end: end)
        } else { dates = nil }
        self.init(kind: kind, text: filters.content.first ?? filters.name,
                  fileExtension: filters.extensions.count == 1 ? filters.extensions[0] : nil,
                  folder: filters.folder, dates: dates,
                  matchesFilenameOnly: !filters.name.isEmpty && filters.content.isEmpty, fileConstraints: filters)
    }

    init?(_ query: String, now: Date, calendar: Calendar) {
        guard query.utf8.count <= 2048 else { return nil }
        var words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        if let first = words.first?.lowercased(), ["find", "show", "search"].contains(first) {
            words.removeFirst()
            if words.first?.lowercased() == "me" || words.first?.lowercased() == "for" {
                words.removeFirst()
            }
        }
        while let word = words.first?.lowercased(), ["all", "my", "the"].contains(word) {
            words.removeFirst()
        }
        guard let first = words.first?.lowercased() else { return nil }
        let kind: Kind
        let ext: String?
        switch first {
        case "file", "files": kind = .files; ext = nil
        case "folder", "folders": kind = .folders; ext = nil
        case "document", "documents": kind = .documents; ext = nil
        case "image", "images", "photo", "photos", "screenshot", "screenshots": kind = .images; ext = nil
        case "audio", "music": kind = .audio; ext = nil
        case "video", "videos": kind = .video; ext = nil
        case "archive", "archives": kind = .archives; ext = nil
        case "text", "clips": kind = .text; ext = nil
        case "link", "links", "url", "urls": kind = .links; ext = nil
        default:
            guard let format = Self.fileFormat(first) else { return nil }
            kind = format.kind
            ext = format.extension
        }
        words.removeFirst()
        var folder: String?
        var dates: DateInterval?
        var website: String?
        var text = ""
        var recognized = false
        if ext != nil, let noun = words.first?.lowercased(), ["file", "files"].contains(noun) {
            words.removeFirst()
            recognized = true
        }
        var matchesFilenameOnly = false
        while !words.isEmpty {
            if dates == nil, let match = Self.dateQualifier(words, now: now, calendar: calendar) {
                dates = match.dates
                words.removeFirst(match.count)
                recognized = true
                continue
            }
            let head = words.removeFirst().lowercased()
            if ["with", "containing", "named", "called"].contains(head) {
                guard !words.isEmpty else { return nil }
                matchesFilenameOnly = head == "named" || head == "called"
                text = words.joined(separator: " ")
                if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
                    text = String(text.dropFirst().dropLast())
                }
                words.removeAll()
                recognized = true
            } else if head == "in", folder == nil, let name = words.first {
                let folders = ["Downloads", "Documents", "Desktop", "Pictures", "Movies", "Music"]
                guard let match = folders.first(where: { $0.lowercased() == name.lowercased() }) else {
                    return nil
                }
                folder = match
                words.removeFirst()
                recognized = true
            } else if head == "from", kind == .links, website == nil,
                let source = words.first?.lowercased(),
                !["today", "yesterday", "this", "last"].contains(source)
            {
                let candidate = source
                guard
                    let components = URLComponents(
                        string: candidate.contains("://") ? candidate : "https://" + candidate),
                    let host = components.host?.lowercased(), !host.isEmpty,
                    components.user == nil, components.password == nil
                else { return nil }
                website = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
                words.removeFirst()
                recognized = true
            } else {
                return nil
            }
        }
        guard recognized else { return nil }
        self.text = text
        self.alternativeTexts = []
        self.kind = kind
        self.fileExtension = ext
        self.folder = folder
        self.dates = dates
        self.website = website
        self.matchesFilenameOnly = matchesFilenameOnly
        self.fileConstraints = nil
    }

    nonisolated static func fileFormat(_ word: String) -> (kind: Kind, extension: String)? {
        var ext = word.lowercased()
        if ext.hasPrefix(".") { ext.removeFirst() }
        switch ext {
        case "pdfs": ext = "pdf"
        case "markdown" where !word.hasPrefix("."): ext = "md"
        default: break
        }
        switch ext {
        case "pdf", "html", "htm", "md", "markdown", "csv", "tsv", "txt", "rtf", "rtfd",
            "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key":
            return (.documents, ext)
        case "png", "jpg", "jpeg", "gif", "heic", "heif", "svg", "webp", "tif", "tiff", "avif":
            return (.images, ext)
        case "mp3", "wav", "m4a", "aac", "flac", "aiff":
            return (.audio, ext)
        case "mp4", "mov", "m4v", "avi", "mkv", "webm":
            return (.video, ext)
        case "zip", "tar", "gz", "bz2", "xz", "7z", "rar":
            return (.archives, ext)
        case "json", "xml", "yaml", "yml", "swift", "js", "ts", "css", "py", "sh":
            return (.files, ext)
        default: return nil
        }
    }

    private static func dateQualifier(
        _ words: [String], now: Date, calendar: Calendar
    ) -> (dates: DateInterval, count: Int)? {
        let keys = words.map { $0.lowercased() }
        var start = 0
        if ["from", "on", "modified", "edited", "changed"].contains(keys[start]) {
            start += 1
            if start < keys.count, keys[start] == "on" { start += 1 }
            if start < keys.count, keys[start] == "the" { start += 1 }
        }
        guard let match = SearchDatePhrase.match(in: keys, at: start, now: now, calendar: calendar) else {
            return nil
        }
        return (match.dates, start + match.count)
    }

    func includes(timestamp: TimeInterval) -> Bool {
        guard let dates else { return true }
        return timestamp >= dates.start.timeIntervalSince1970 && timestamp < dates.end.timeIntervalSince1970
    }
}
