import Foundation

/// Everything a link card can know without touching the network: detection, head parsing, bookmarks.
enum LinkPreviewDocument {
    /// What a fetched page offered: title, description and image/icon hrefs as written.
    struct Head: Equatable, Sendable {
        var title: String?
        var description: String?
        var imagePath: String?
        var iconPath: String?
    }

    /// The whole text names one fetchable page, else nil. Deeplinks and paths never fetch.
    static func pageURL(from text: String) -> URL? {
        guard case .web(let url) = QuicklinkDestination.detect(text) else { return nil }
        return url
    }

    /// Title, description, image and icon from a page head. Open Graph wins throughout.
    static func parseHead(_ html: String, baseURL: URL) -> Head {
        let head = String(headSection(of: html).prefix(headScanLimit))
        let description =
            metaContent(in: head, key: "og:description")
            ?? metaContent(in: head, key: "twitter:description")
            ?? metaContent(in: head, key: "description")
        let image = (metaContent(in: head, key: "og:image")
            ?? metaContent(in: head, key: "twitter:image")).flatMap {
            resolve($0, baseURL: baseURL)
        }
        return Head(
            title: metaContent(in: head, key: "og:title")
                ?? metaContent(in: head, key: "twitter:title") ?? documentTitle(in: head),
            description: description,
            imagePath: image,
            iconPath: iconLink(in: head, baseURL: baseURL))
    }

    /// `/favicon.ico` on the page's own origin, when the markup names no icon.
    static func faviconFallback(for url: URL) -> URL? {
        originURL(of: url, path: "/favicon.ico")
    }

    /// The site's home page, whose card stands in for a private or bare page, else nil.
    static func siteRoot(for url: URL) -> URL? {
        guard let root = originURL(of: url, path: "/") else { return nil }
        let isRoot = (url.path.isEmpty || url.path == "/") && url.query == nil
        return isRoot ? nil : root
    }

    private static func originURL(of url: URL, path: String) -> URL? {
        guard let host = url.host, !host.isEmpty else { return nil }
        var parts = URLComponents()
        parts.scheme = url.scheme
        parts.host = host
        parts.port = url.port
        parts.path = path
        return parts.url
    }

    /// A `.webloc` bookmark resolves to the page it points at, else nil.
    static func bookmarkURL(fromWebloc data: Data) -> URL? {
        guard
            let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil),
            let dict = plist as? [String: Any],
            let raw = dict["URL"] as? String
        else { return nil }
        return fetchableURL(raw)
    }

    /// A `.url` shortcut file resolves the same way, off its `URL=` line.
    static func bookmarkURL(fromURLFile text: String) -> URL? {
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("url=") else { continue }
            let raw = trimmed.dropFirst("url=".count).trimmingCharacters(in: .whitespaces)
            return fetchableURL(String(raw))
        }
        return nil
    }

    /// Only what the card fetches: http(s), never a file path or an app scheme.
    private static func fetchableURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https", url.host != nil
        else { return nil }
        return url
    }

    /// The head alone: titles and icons live there, and bodies can run to megabytes.
    private static func headSection(of html: String) -> Substring {
        guard let end = html.range(of: "</head", options: .caseInsensitive) else { return html[...] }
        return html[..<end.lowerBound]
    }

    private static let headScanLimit = 65_536
    private static let titleLimit = 300

    /// Inner text of the first `<title>`, entities decoded and whitespace collapsed.
    private static func documentTitle(in head: String) -> String? {
        guard let open = head.range(of: "<title", options: .caseInsensitive),
            let start = head[open.upperBound...].firstIndex(of: ">"),
            let close = head[start...].range(of: "</title", options: .caseInsensitive)
        else { return nil }
        let raw = head[head.index(after: start)..<close.lowerBound]
        return cleanedTitle(String(raw))
    }

    /// `content` of the first `<meta>` naming `key` through `property` or `name`.
    private static func metaContent(in head: String, key: String) -> String? {
        var rest = head[...]
        while let open = rest.range(of: "<meta", options: .caseInsensitive) {
            guard let end = rest[open.lowerBound...].firstIndex(of: ">") else { return nil }
            let tag = String(rest[open.lowerBound...end])
            if attribute(in: tag, named: "property")?.lowercased() == key
                || attribute(in: tag, named: "name")?.lowercased() == key,
                let content = attribute(in: tag, named: "content"),
                !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                if key.hasSuffix(":image") {
                    return decodeEntities(in: content.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                return cleanedTitle(content)
            }
            rest = rest[rest.index(after: end)...]
        }
        return nil
    }

    /// `href` of the first `<link>` whose `rel` names an icon, resolved against the page.
    private static func iconLink(in head: String, baseURL: URL) -> String? {
        var rest = head[...]
        while let open = rest.range(of: "<link", options: .caseInsensitive) {
            guard let end = rest[open.lowerBound...].firstIndex(of: ">") else { return nil }
            let tag = String(rest[open.lowerBound...end])
            if let rel = attribute(in: tag, named: "rel"),
                rel.lowercased().split(separator: " ").contains(where: {
                    $0 == "icon" || $0.hasSuffix("-icon")
                }),
                let href = attribute(in: tag, named: "href"),
                !href.isEmpty, let resolved = resolve(href, baseURL: baseURL)
            {
                return resolved
            }
            rest = rest[rest.index(after: end)...]
        }
        return nil
    }

    private static func cleanedTitle(_ raw: String) -> String? {
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(decodeEntities(in: collapsed).prefix(titleLimit))
    }

    /// Case-insensitive `name=value` lookup tolerating single quotes and bare values.
    private static func attribute(in tag: String, named name: String) -> String? {
        var rest = tag[...]
        while let key = rest.range(of: name, options: .caseInsensitive) {
            if key.lowerBound > rest.startIndex {
                let before = rest[rest.index(before: key.lowerBound)]
                if before.isLetter || before.isNumber || before == "-" || before == "_" {
                    rest = rest[key.upperBound...]
                    continue
                }
            }
            var after = key.upperBound
            while after < rest.endIndex, rest[after].isWhitespace { after = rest.index(after: after) }
            guard after < rest.endIndex, rest[after] == "=" else {
                rest = rest[key.upperBound...]
                continue
            }
            var value = rest[rest.index(after: after)...].prefix(while: { $0 != ">" })
            value = value.drop(while: { $0.isWhitespace })
            if let quote = value.first, quote == "\"" || quote == "'" {
                value = value.dropFirst().prefix(while: { $0 != quote })
            } else {
                value = value.prefix(while: { !$0.isWhitespace })
            }
            let absolute = tag.distance(from: tag.startIndex, to: rest.startIndex)
                + rest.distance(from: rest.startIndex, to: value.startIndex)
            let from = tag.index(tag.startIndex, offsetBy: absolute)
            return String(tag[from..<tag.index(from, offsetBy: value.count)])
        }
        return nil
    }

    /// Absolute, root-relative and protocol-relative hrefs against the page that carried them.
    private static func resolve(_ href: String, baseURL: URL) -> String? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("//"), let scheme = baseURL.scheme {
            return fetchableURL(scheme + ":" + trimmed)?.absoluteString
        }
        guard let absolute = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL else { return nil }
        return fetchableURL(absolute.absoluteString)?.absoluteString
    }

    /// The common named entities plus decimal and hex numeric references.
    private static func decodeEntities(in text: String) -> String {
        var result = text
        for (entity, char) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\""] {
            result = result.replacingOccurrences(of: entity, with: char)
        }
        var out = ""
        out.reserveCapacity(result.count)
        var rest = result[...]
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            rest = rest[amp...]
            guard let semi = rest.firstIndex(of: ";"), semi < rest.index(rest.startIndex, offsetBy: 10)
            else {
                out += "&"
                rest = rest.dropFirst()
                continue
            }
            let body = rest[rest.index(after: rest.startIndex)..<semi]
            if body == "apos" || body == "#39" {
                out += "'"
            } else if body.hasPrefix("#x"), let code = UInt32(body.dropFirst(2), radix: 16),
                let scalar = Unicode.Scalar(code)
            {
                out += String(scalar)
            } else if body.hasPrefix("#"), let code = UInt32(body.dropFirst()),
                let scalar = Unicode.Scalar(code)
            {
                out += String(scalar)
            } else {
                out += rest[..<rest.index(after: semi)]
            }
            rest = rest[rest.index(after: semi)...]
        }
        return out + rest
    }
}
