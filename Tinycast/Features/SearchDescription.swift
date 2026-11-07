import Foundation

struct SearchDescription: Sendable, Equatable {
    enum Kind: String, Sendable { case any, files, folders, documents, images, audio, video, archives, text, links }

    let text: String
    let alternativeTexts: [String]
    let kind: Kind
    let fileExtension: String?
    let folder: String?
    let dates: DateInterval?
    let website: String?

    init(
        kind: Kind, text: String, alternativeTexts: [String] = [], fileExtension: String? = nil,
        folder: String? = nil, dates: DateInterval? = nil, website: String? = nil
    ) {
        self.kind = kind
        self.text = text
        self.alternativeTexts = alternativeTexts
        self.fileExtension = fileExtension
        self.folder = folder
        self.dates = dates
        self.website = website
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
        case "pdf", "pdfs": kind = .documents; ext = "pdf"
        case "image", "images", "photo", "photos", "screenshot", "screenshots": kind = .images; ext = nil
        case "audio", "music": kind = .audio; ext = nil
        case "video", "videos": kind = .video; ext = nil
        case "archive", "archives": kind = .archives; ext = nil
        case "text", "clips": kind = .text; ext = nil
        case "link", "links", "url", "urls": kind = .links; ext = nil
        default: return nil
        }
        words.removeFirst()
        var folder: String?
        var dates: DateInterval?
        var website: String?
        var text = ""
        var recognized = false
        while !words.isEmpty {
            let head = words.removeFirst().lowercased()
            if ["with", "containing", "named", "called"].contains(head) {
                guard !words.isEmpty else { return nil }
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
            } else if head == "from", dates == nil {
                guard let dateWord = words.first?.lowercased() else { return nil }
                words.removeFirst()
                let start: Date
                let end: Date
                if dateWord == "today" || dateWord == "yesterday" {
                    let today = calendar.startOfDay(for: now)
                    guard
                        let boundary = calendar.date(
                            byAdding: .day, value: dateWord == "today" ? 1 : -1, to: today)
                    else { return nil }
                    start = dateWord == "today" ? today : boundary
                    end = dateWord == "today" ? boundary : today
                } else if dateWord == "this" || dateWord == "last", words.first?.lowercased() == "week" {
                    words.removeFirst()
                    guard let week = calendar.dateInterval(of: .weekOfYear, for: now),
                        let previous = calendar.date(byAdding: .weekOfYear, value: -1, to: week.start)
                    else { return nil }
                    start = dateWord == "this" ? week.start : previous
                    end = dateWord == "this" ? week.end : week.start
                } else {
                    return nil
                }
                dates = DateInterval(start: start, end: end)
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
    }

    func includes(timestamp: TimeInterval) -> Bool {
        guard let dates else { return true }
        return timestamp >= dates.start.timeIntervalSince1970 && timestamp < dates.end.timeIntervalSince1970
    }
}
