import Foundation

struct DictionaryPronunciationProvider: Sendable {
    struct RetryAfterError: Error, Sendable {
        let delay: TimeInterval
    }

    private static let metadataLimit = 1_048_576
    private static let audioLimit = 2_097_152
    private static let recordingLimit = 4
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration, delegate: RedirectPolicy(), delegateQueue: nil)
    }()

    private let fetch: @Sendable (URL, Int, Bool) async throws -> Data

    init(fetch: @escaping @Sendable (URL, Int, Bool) async throws -> Data = Self.body) {
        self.fetch = fetch
    }

    @concurrent
    func lookup(_ term: String, languageCode: String = "en") async throws -> DictionaryPronunciation {
        try Task.checkCancellation()
        let word = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard languageCode.lowercased() == "en", !word.isEmpty, word.utf8.count <= 128,
            word.rangeOfCharacter(from: .controlCharacters) == nil,
            !word.contains("|"), !word.contains("#"), !word.contains(":")
        else { return DictionaryPronunciation() }
        var page = try await pronunciations(for: word)
        let lowercase = word.lowercased()
        if page.candidates.isEmpty, lowercase != word {
            page = try await pronunciations(for: lowercase)
        }
        guard !page.candidates.isEmpty else { return DictionaryPronunciation() }
        let commonsURL = Self.apiURL(host: "commons.wikimedia.org", parameters: [
            "prop": "videoinfo", "viprop": "url|mime|size|derivatives|extmetadata",
            "viextmetadatafilter": "Artist|Credit|LicenseShortName|LicenseUrl|AttributionRequired",
            "titles": page.candidates.map { "File:" + $0.file }.joined(separator: "|")
        ])
        let metadata = try await fetch(commonsURL, Self.metadataLimit, false)
        try Task.checkCancellation()
        var result = try Self.pronunciation(candidates: page.candidates, metadata: metadata)
        for index in result.recordings.indices { result.recordings[index].phoneticsURL = page.sourceURL }
        return result
    }

    @concurrent
    func audioData(for recording: DictionaryPronunciation.Recording) async throws -> Data {
        try Task.checkCancellation()
        guard Self.audioURL(recording.audioURL.absoluteString) != nil else { throw URLError(.badURL) }
        let data = try await fetch(recording.audioURL, Self.audioLimit, true)
        try Task.checkCancellation()
        return data
    }

    private func pronunciations(
        for word: String
    ) async throws -> (candidates: [Candidate], sourceURL: URL?) {
        let url = Self.apiURL(host: "en.wiktionary.org", parameters: [
            "prop": "revisions", "rvprop": "content", "rvslots": "main", "redirects": "1", "titles": word
        ])
        let data = try await fetch(url, Self.metadataLimit, false)
        try Task.checkCancellation()
        let page = try JSONDecoder().decode(RevisionResponse.self, from: data)
        try Self.check(page.error)
        guard let resolved = page.query?.pages.first,
            let text = resolved.revisions?.first?.slots.main.content
        else { return ([], nil) }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "en.wiktionary.org"
        components.path = "/wiki/" + (resolved.title ?? "").replacingOccurrences(of: " ", with: "_")
        components.fragment = "English"
        let source = resolved.title?.isEmpty == false ? components.url : nil
        return (Self.candidates(in: text), source)
    }

    private static func apiURL(host: String, parameters: [String: String]) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/w/api.php"
        let values = parameters.merging([
            "action": "query", "format": "json", "formatversion": "2", "maxlag": "5"
        ]) { first, _ in first }
        components.queryItems = values.sorted { $0.key < $1.key }.map(URLQueryItem.init)
        return components.url!
    }

    private static func body(_ url: URL, limit: Int, audio: Bool) async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue(
            "Tinycast (https://github.com/mallenkb/tinycast; dictionary pronunciation)",
            forHTTPHeaderField: "User-Agent")
        request.setValue(audio ? "audio/mpeg, audio/wav" : "application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, response.url == url else {
            throw URLError(.badServerResponse)
        }
        if let error = retryError(for: http) { throw error }
        guard http.statusCode == 200, response.expectedContentLength <= Int64(limit) else {
            throw URLError(.badServerResponse)
        }
        let mime = response.mimeType?.lowercased() ?? ""
        guard audio ? ["audio/mpeg", "audio/wav", "audio/x-wav"].contains(mime)
            : mime == "application/json"
        else { throw URLError(.cannotDecodeContentData) }
        var data = Data()
        data.reserveCapacity(min(limit, 65_536))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        guard !data.isEmpty else { throw URLError(.zeroByteResource) }
        return data
    }

    static func retryError(for response: HTTPURLResponse, now: Date = Date()) -> RetryAfterError? {
        guard response.statusCode == 429 || response.statusCode == 503 else { return nil }
        return RetryAfterError(delay: retryDelay(response.value(forHTTPHeaderField: "Retry-After"), now: now))
    }

    static func retryDelay(_ header: String?, now: Date = Date()) -> TimeInterval {
        guard let value = header?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return 5
        }
        if value.utf8.allSatisfy({ (48...57).contains($0) }),
            let seconds = TimeInterval(value), seconds.isFinite
        {
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        for format in ["EEE, dd MMM yyyy HH:mm:ss 'GMT'", "EEEE, dd-MMM-yy HH:mm:ss 'GMT'", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                let delay = date.timeIntervalSince(now)
                if delay.isFinite { return max(0, delay) }
            }
        }
        return 5
    }

    private static func check(_ error: APIError?) throws {
        guard let error else { return }
        if ["maxlag", "ratelimited"].contains(error.code.lowercased()) {
            throw RetryAfterError(delay: 5)
        }
        throw URLError(.badServerResponse)
    }

    struct Candidate: Equatable, Sendable {
        let file: String
        let title: String
        let ipa: String?
        var ipaVariants: [String] = []
    }

    static func candidates(in text: String) -> [Candidate] {
        var english = false
        var pronunciationDepth: Int?
        var ipa: (variants: [String], accent: String?)?
        var result: [Candidate] = []
        var accentScopes: [Int: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("=="), value.hasSuffix("==") {
                let depth = value.prefix(while: { $0 == "=" }).count
                let heading = value.trimmingCharacters(in: CharacterSet(charactersIn: "= "))
                if depth == 2 {
                    english = heading == "English"
                    pronunciationDepth = nil
                } else if english, heading == "Pronunciation" {
                    pronunciationDepth = depth
                } else if let currentDepth = pronunciationDepth, depth <= currentDepth {
                    pronunciationDepth = nil
                }
                ipa = nil
                accentScopes = pronunciationDepth.map { depth > $0 ? [0: heading] : [:] } ?? [:]
                continue
            }
            guard english, pronunciationDepth != nil else { continue }
            let depth = value.prefix(while: { $0 == "*" }).count
            if depth > 0 { accentScopes = accentScopes.filter { $0.key < depth } }
            for template in templates(in: value) {
                let fields = template.components(separatedBy: "|").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard fields.count >= 3, fields[1] == "en" else { continue }
                if fields[0].lowercased() == "a" {
                    accentScopes[depth] = fields.dropFirst(2).joined(separator: ",")
                    continue
                }
                let accent = fields.dropFirst(3).first(where: { $0.hasPrefix("a=") }).map {
                    String($0.dropFirst(2))
                } ?? accentScopes.max(by: { $0.key < $1.key })?.value
                switch fields[0].lowercased() {
                case "ipa":
                    var transcriptions: [String] = []
                    for value in fields.dropFirst(2) {
                        guard value.utf8.count <= 512, value.count > 2,
                            value.rangeOfCharacter(from: .controlCharacters) == nil,
                            value.first == "/" && value.last == "/" || value.first == "[" && value.last == "]",
                            !transcriptions.contains(value)
                        else { continue }
                        transcriptions.append(value)
                        if transcriptions.count == 4 { break }
                    }
                    ipa = transcriptions.isEmpty ? nil : (transcriptions, accent)
                case "audio":
                    let file = fields[2].replacingOccurrences(of: "_", with: " ")
                    guard file.utf8.count <= 512, !file.contains("|"), !file.contains("#"),
                        ["ogg", "oga", "wav", "mp3"].contains(URL(fileURLWithPath: file).pathExtension.lowercased()),
                        !result.contains(where: { normalizedFile($0.file) == normalizedFile(file) })
                    else { continue }
                    let label = accent ?? fields.dropFirst(3).first(where: { !$0.contains("=") })
                    let matchingVariants = ipa.flatMap {
                        accentsMatch($0.accent, accent) ? $0.variants : nil
                    } ?? []
                    result.append(Candidate(
                        file: file, title: label.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "English"),
                        ipa: matchingVariants.count == 1 ? matchingVariants.first : nil,
                        ipaVariants: matchingVariants))
                    if result.count == recordingLimit { return result }
                default: break
                }
            }
        }
        return result
    }

    private static func templates(in text: String) -> [String] {
        text.matches(of: #/\{\{([^{}]+)\}\}/#).map { String($0.1) }
    }

    private static func accentsMatch(_ ipa: String?, _ audio: String?) -> Bool {
        guard let ipa else { return true }
        guard let audio else { return false }
        func accents(_ value: String) -> Set<String> {
            Set(value.split(separator: ",").map {
                switch $0.trimmingCharacters(in: .whitespaces).lowercased() {
                case "ga", "general american", "us": "us"
                case "rp", "uk", "received pronunciation": "uk"
                default: $0.trimmingCharacters(in: .whitespaces).lowercased()
                }
            })
        }
        return !accents(ipa).isDisjoint(with: accents(audio))
    }

    static func pronunciation(candidates: [Candidate], metadata: Data) throws -> DictionaryPronunciation {
        let response = try JSONDecoder().decode(MediaResponse.self, from: metadata)
        try Self.check(response.error)
        let pages = response.query?.pages ?? []
        let recordings = candidates.compactMap { candidate -> DictionaryPronunciation.Recording? in
            guard let page = pages.first(where: {
                normalizedFile($0.title) == normalizedFile(candidate.file)
            }), let info = page.videoinfo?.first,
                let duration = info.duration, duration > 0, duration <= 15,
                let size = info.size, size > 0, size <= audioLimit,
                let source = safeURL(info.descriptionurl, hosts: ["commons.wikimedia.org"]),
                source.path.hasPrefix("/wiki/File:")
            else { return nil }
            let mp3 = info.derivatives?.first(where: { $0.type == "audio/mpeg" }).flatMap {
                audioURL($0.src)
            }
            let original = ["audio/mpeg", "audio/wav", "audio/x-wav"].contains(info.mime ?? "")
                ? audioURL(info.url) : nil
            guard let audio = mp3 ?? original else { return nil }
            let author = plainText(info.extmetadata?["Artist"]?.value ?? "")
            let license = plainText(info.extmetadata?["LicenseShortName"]?.value ?? "")
            guard !author.isEmpty, author.count <= 1_024, !license.isEmpty, license.count <= 128 else {
                return nil
            }
            var licenseValue = info.extmetadata?["LicenseUrl"]?.value ?? ""
            if licenseValue.hasPrefix("http://creativecommons.org/") {
                licenseValue = "https://" + licenseValue.dropFirst(7)
            }
            let licenseURL = safeURL(licenseValue, hosts: [
                "creativecommons.org", "www.gnu.org", "gnu.org", "commons.wikimedia.org"
            ])
            return DictionaryPronunciation.Recording(
                id: page.title, title: candidate.title, ipa: candidate.ipa, audioURL: audio,
                sourceURL: source, author: author, licenseName: license, licenseURL: licenseURL,
                ipaVariants: candidate.ipaVariants)
        }
        return DictionaryPronunciation(recordings: recordings)
    }

    private static func normalizedFile(_ value: String) -> String {
        let name = value.hasPrefix("File:") ? String(value.dropFirst(5)) : value
        guard let first = name.first else { return "" }
        return first.uppercased() + name.dropFirst().replacingOccurrences(of: "_", with: " ")
    }

    private static func audioURL(_ value: String?) -> URL? {
        guard let url = safeURL(value, hosts: ["upload.wikimedia.org"]),
            url.path.hasPrefix("/wikipedia/commons/"),
            ["mp3", "wav"].contains(url.pathExtension.lowercased())
        else { return nil }
        return url
    }

    private static func safeURL(_ value: String?, hosts: Set<String>) -> URL? {
        guard let value, var components = URLComponents(string: value), components.scheme == "https",
            let host = components.host, hosts.contains(host.lowercased()),
            components.user == nil, components.password == nil,
            components.port == nil || components.port == 443
        else { return nil }
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static func plainText(_ html: String) -> String {
        let separated = html.replacingOccurrences(
            of: #"</?(?:li|ul|p|br)\b[^>]*>"#, with: " ", options: .regularExpression)
        let stripped = separated.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        var text = stripped
        let entities = stripped.matches(of: #/&(#x[0-9a-fA-F]+|#[0-9]+|amp|lt|gt|quot|apos|nbsp);/#)
        for entity in entities.reversed() {
            let token = String(entity.1)
            let decoded: String?
            switch token {
            case "amp": decoded = "&"
            case "lt": decoded = "<"
            case "gt": decoded = ">"
            case "quot": decoded = "\""
            case "apos": decoded = "'"
            case "nbsp": decoded = " "
            default:
                let hexadecimal = token.hasPrefix("#x")
                let digits = token.dropFirst(hexadecimal ? 2 : 1)
                decoded = UInt32(digits, radix: hexadecimal ? 16 : 10)
                    .flatMap(Unicode.Scalar.init).map(String.init)
            }
            if let decoded { text.replaceSubrange(entity.range, with: decoded) }
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private struct APIError: Decodable { var code: String }

    private struct RevisionResponse: Decodable {
        var error: APIError?
        var query: Query?
        struct Query: Decodable { var pages: [Page] }
        struct Page: Decodable {
            var title: String?
            var revisions: [Revision]?
        }
        struct Revision: Decodable { var slots: Slots }
        struct Slots: Decodable { var main: Content }
        struct Content: Decodable { var content: String }
    }

    private struct MediaResponse: Decodable {
        var error: APIError?
        var query: Query?
        struct Query: Decodable { var pages: [Page] }
        struct Page: Decodable {
            var title: String
            var videoinfo: [Info]?
        }
        struct Info: Decodable {
            var url: String?
            var descriptionurl: String?
            var mime: String?
            var size: Int?
            var duration: Double?
            var derivatives: [Derivative]?
            var extmetadata: [String: Metadata]?
        }
        struct Derivative: Decodable { var src: String; var type: String }
        struct Metadata: Decodable {
            let value: String
            enum CodingKeys: String, CodingKey { case value }
            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                value = (try? container.decode(String.self, forKey: .value)) ?? ""
            }
        }
    }

    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
