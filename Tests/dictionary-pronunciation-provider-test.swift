import Foundation
import Synchronization

@main
struct DictionaryPronunciationProviderTests {
    static func main() async throws {
        parser()
        retryHeaders()
        try metadata()
        try await gates()
        try await requestDecisions()
        if CommandLine.arguments.contains("--live") { try await live() }
        print("Dictionary pronunciation provider checks passed")
    }

    static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
    }

    static func retryHeaders() {
        let now = Date(timeIntervalSince1970: 946_684_800)
        for (header, expected) in [(nil, 5.0), ("", 5), ("0", 0), (" 17 ", 17), ("86400", 86_400),
                                   ("999999999", 999_999_999), ("-1", 5), ("NaN", 5), ("invalid", 5),
                                   ("Sat, 01 Jan 2000 00:00:10 GMT", 10),
                                   ("Fri, 31 Dec 1999 23:59:59 GMT", 0)] as [(String?, TimeInterval)] {
            expect(DictionaryPronunciationProvider.retryDelay(header, now: now) == expected,
                   "Retry-After \(header ?? "missing") preserves its delay or uses a five-second default")
        }
        let url = URL(string: "https://en.wiktionary.org/w/api.php")!
        for status in [200, 404, 429, 503] {
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil, headerFields: ["Retry-After": "12"])!
            let error = DictionaryPronunciationProvider.retryError(for: response, now: now)
            expect(error?.delay == (status == 429 || status == 503 ? 12 : nil),
                   "only throttle and unavailable statuses request a cooldown")
        }
    }

    static func parser() {
        let text = """
            ==English==
            ===Pronunciation===
            * {{IPA|en|/uk/|a=UK}}
            * {{a|en|US}}
            ** {{IPA|en|/american/|/american/|a=GA}}
            *** {{audio|en|en-us-library.ogg|a=US}}
            *** {{audio|en|en-us-library.ogg|a=US}}
            * {{audio|en|en-uk-library.wav|a=UK}}
            ===Noun===
            {{audio|en|outside-pronunciation.mp3|a=US}}
            ==French==
            ===Pronunciation===
            {{audio|en|outside-english.mp3|a=US}}
            """
        let found = DictionaryPronunciationProvider.candidates(in: text)
        expect(found.count == 2, "only distinct English pronunciation-section recordings are selected")
        expect(found[0].title == "US" && found[0].ipa == "/american/",
               "identical IPA alternatives still produce a compatible transcription")
        expect(found[0].ipaVariants == ["/american/"], "identical alternatives are deduplicated")
        expect(found[1].ipa == nil && found[1].ipaVariants.isEmpty,
               "a UK recording never inherits a preceding US transcription or its alternatives")
        let ambiguous = """
            ==English==
            ===Pronunciation===
            * {{IPA|en|/older/|a=US}}
            * {{IPA|en|/riːd/|/ɹɛd/|a=US}}
            * {{audio|en|read.ogg|a=US}}
            """
        let ambiguousFound = DictionaryPronunciationProvider.candidates(in: ambiguous)
        expect(ambiguousFound.first?.ipa == nil,
               "distinct same-accent alternatives cannot claim which pronunciation a recording uses")
        expect(ambiguousFound.first?.ipaVariants == ["/riːd/", "/ɹɛd/"],
               "ambiguous alternatives remain available in their source order")
        let limited = "==English==\n===Pronunciation===\n"
            + "{{IPA|en|invalid|/a/|/a/|/b/|[c]|/d/|/e/}}\n{{audio|en|variants.ogg}}"
        expect(DictionaryPronunciationProvider.candidates(in: limited).first?.ipaVariants == ["/a/", "/b/", "[c]", "/d/"],
               "only four unique syntactically valid IPA alternatives are retained")
        let scoped = """
            ==English==
            ===Pronunciation===
            * {{a|en|UK}}
            ** {{IPA|en|/british/}}
            *** {{audio|en|british.ogg}}
            * {{audio|en|american.ogg|a=US}}
            """
        let scopedFound = DictionaryPronunciationProvider.candidates(in: scoped)
        expect(scopedFound[0].title == "UK" && scopedFound[0].ipa == "/british/", "accent scopes reach child audio")
        expect(scopedFound[1].ipa == nil, "a scoped British IPA never reaches a US sibling")
        let nested = """
            ==English==
            ===Pronunciation===
            ====US====
            * {{IPA|en|/american/}}
            * {{audio|en|american.ogg}}
            ====UK====
            * {{audio|en|british.ogg}}
            ===Noun===
            * {{audio|en|not-pronunciation.ogg}}
            """
        let nestedFound = DictionaryPronunciationProvider.candidates(in: nested)
        expect(nestedFound.count == 2, "nested pronunciation sections retain audio until their parent ends")
        expect(nestedFound[0].ipa == "/american/" && nestedFound[0].title == "US", "subheading accents are preserved")
        expect(nestedFound[1].ipa == nil, "a new pronunciation subheading clears the preceding IPA")
        let shared = "==English==\n===Pronunciation===\n{{IPA|en|/ɹaɪs/}}\n{{audio|en|rice.ogg|a=US}}"
        expect(DictionaryPronunciationProvider.candidates(in: shared).first?.ipa == "/ɹaɪs/", "unqualified IPA applies")
        let many = "==English==\n===Pronunciation===\n" + (0..<12).map {
            "{{audio|en|word-\($0).ogg|a=US}}"
        }.joined(separator: "\n")
        expect(DictionaryPronunciationProvider.candidates(in: many).count == 4, "metadata fan-out is bounded")
    }

    static func metadata() throws {
        let candidates = [DictionaryPronunciationProvider.Candidate(
            file: "en-us-rice.ogg", title: "US", ipa: "/ɹaɪs/", ipaVariants: ["/ɹaɪs/"])]
        let valid = try DictionaryPronunciationProvider.pronunciation(candidates: candidates, metadata: fixture())
        guard let recording = valid.recordings.first else { fatalError("valid metadata must produce a recording") }
        expect(recording.audioURL.pathExtension == "mp3", "advertised playable derivatives are preferred")
        expect(recording.ipaVariants == ["/ɹaɪs/"], "recordings preserve source IPA alternatives")
        expect(recording.author == "Speaker: A & B Recorder: C", "credits are plain text with entity decoding")
        expect(recording.licenseName == "CC BY-SA 3.0", "license names accompany every recording")
        expect(recording.licenseURL?.scheme == "https", "legacy Commons license URLs use HTTPS")
        expect(recording.sourceURL.host == "commons.wikimedia.org", "the source links to its Commons file page")
        expect(recording.audioURL.query == nil, "download URLs omit Commons tracking parameters")
        for invalid in [
            try fixture(audio: "https://evil.example/rice.mp3"),
            try fixture(audio: "https://upload.wikimedia.org.evil.example/rice.mp3"),
            try fixture(audio: "https://user@upload.wikimedia.org/wikipedia/commons/rice.mp3"),
            try fixture(audio: "https://upload.wikimedia.org/elsewhere/rice.mp3"),
            try fixture(source: "https://evil.example/wiki/File:rice.ogg"),
            try fixture(author: ""), try fixture(license: ""),
            try fixture(size: 9_000_000), try fixture(duration: 20)
        ] {
            let result = try DictionaryPronunciationProvider.pronunciation(candidates: candidates, metadata: invalid)
            expect(result.recordings.isEmpty, "unsafe, unattributed or oversized media is refused")
        }
        expect(
            DictionaryPronunciationProvider.plainText("<b>Ren&#233;e</b> &amp; &#x96EA; &amp;lt;") == "Renée & 雪 &lt;",
            "numeric and named entities are decoded exactly once")
    }

    static func fixture(
        audio: String = "https://upload.wikimedia.org/wikipedia/commons/transcoded/f/f9/rice.ogg/rice.ogg.mp3?utm_source=commons",
        source: String = "https://commons.wikimedia.org/wiki/File:En-us-rice.ogg",
        author: String = "<ul><li>Speaker: A &amp; B</li><li>Recorder: C</li></ul>",
        license: String = "CC BY-SA 3.0", size: Int = 15_000, duration: Double = 1
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["query": ["pages": [[
            "title": "File:En-us-rice.ogg", "videoinfo": [[
                "url": "https://upload.wikimedia.org/wikipedia/commons/f/f9/rice.ogg", "mime": "application/ogg",
                "size": size, "duration": duration, "descriptionurl": source,
                "derivatives": [["src": audio, "type": "audio/mpeg"]],
                "extmetadata": [
                    "Artist": ["value": author], "LicenseShortName": ["value": license],
                    "LicenseUrl": ["value": "http://creativecommons.org/licenses/by-sa/3.0/"],
                    "CommonsMetadataExtension": ["value": 1.2]
                ]
            ]]
        ]]]])
    }

    static func gates() async throws {
        let provider = DictionaryPronunciationProvider()
        let unsupported = try await provider.lookup("rice", languageCode: "fr")
        expect(unsupported.recordings.isEmpty, "unsupported lookup languages produce no English recordings")
        for term in ["", "rice|library", "File:rice", "ri\u{0}ce", String(repeating: "x", count: 129)] {
            let result = try await provider.lookup(term)
            expect(result.recordings.isEmpty, "invalid terms have no recordings")
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await provider.lookup("rice")
        }
        do {
            _ = try await task.value
            fatalError("a cancelled lookup must throw")
        } catch is CancellationError {}
        let unsafe = DictionaryPronunciation.Recording(
            id: "unsafe", title: "US", ipa: nil, audioURL: URL(string: "https://evil.example/rice.mp3")!,
            sourceURL: URL(string: "https://commons.wikimedia.org/wiki/File:Rice.ogg")!,
            author: "Example", licenseName: "CC BY 3.0", licenseURL: nil)
        do {
            _ = try await provider.audioData(for: unsafe)
            fatalError("an untrusted audio host must fail before networking")
        } catch let error as URLError {
            expect(error.code == .badURL, "unsafe media fails URL validation")
        }
    }

    static func requestDecisions() async throws {
        let missing = Data(#"{"query":{"pages":[{"title":"Rice","missing":true}]}}"#.utf8)
        let error = Data(#"{"error":{"code":"maxlag","info":"Waiting for replicas"}}"#.utf8)
        let revision = try JSONSerialization.data(withJSONObject: ["query": ["pages": [[
            "title": "rice", "revisions": [["slots": ["main": [
                "content": "==English==\n===Pronunciation===\n{{audio|en|en-us-rice.ogg|a=US}}"
            ]]]]
        ]]]])
        for scenario in ["fallback", "no-audio", "direct", "missing", "wiktionary-error", "commons-error", "rate-error"] {
            let requests = Mutex<[String]>([])
            let provider = DictionaryPronunciationProvider { url, _, _ in
                if url.host == "en.wiktionary.org" {
                    let title = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                        .first(where: { $0.name == "titles" })?.value ?? ""
                    requests.withLock { $0.append(title) }
                    if scenario == "wiktionary-error" { return error }
                    if scenario == "rate-error" {
                        return Data(#"{"error":{"code":"ratelimited"}}"#.utf8)
                    }
                    if scenario == "missing" || scenario == "fallback" && title == "Rice" { return missing }
                    if scenario == "no-audio", title == "Rice" {
                        let text = String(bytes: revision, encoding: .utf8) ?? ""
                        return Data(text.replacingOccurrences(of: "Pronunciation", with: "Noun").utf8)
                    }
                    return revision
                }
                requests.withLock { $0.append("commons") }
                return scenario == "commons-error" ? error : try fixture()
            }
            do {
                let result = try await provider.lookup("Rice")
                expect(!scenario.hasSuffix("error"), "API error objects must reach the retry state")
                expect(result.recordings.isEmpty == (scenario == "missing"), "genuine missing pages stay empty")
                if let recording = result.recordings.first {
                    expect(recording.phoneticsURL?.absoluteString == "https://en.wiktionary.org/wiki/rice#English",
                           "phonetic attribution uses the resolved title rather than the capitalized query")
                }
            } catch let error as DictionaryPronunciationProvider.RetryAfterError {
                expect(scenario.hasSuffix("error") && error.delay == 5, "API throttles request a cooldown")
            }
            let expected: [String] = switch scenario {
            case "fallback", "no-audio": ["Rice", "rice", "commons"]
            case "missing": ["Rice", "rice"]
            case "wiktionary-error", "rate-error": ["Rice"]
            default: ["Rice", "commons"]
            }
            expect(requests.withLock { $0 } == expected, "\(scenario) performs only its bounded requests")
        }
    }

    static func live() async throws {
        let provider = DictionaryPronunciationProvider()
        for term in ["library", "bulwark", "rice"] {
            let result = try await provider.lookup(term)
            expect(!result.recordings.isEmpty, "\(term) has a real Wikimedia recording")
            if term == "library" {
                expect(result.recordings.allSatisfy { $0.ipa == nil && $0.ipaVariants.count == 2 },
                       "library retains both sourced alternatives without claiming a recording match")
            }
            for recording in result.recordings {
                let data = try await provider.audioData(for: recording)
                expect(data.count > 100 && data.count <= 2_097_152, "\(term) downloads bounded audio")
                expect(recording.phoneticsURL?.host == "en.wiktionary.org", "live recordings link to their phonetic source")
                let id3 = data.starts(with: [0x49, 0x44, 0x33])
                let frame = data.count >= 2 && data[0] == 0xFF && data[1] & 0xE0 == 0xE0
                expect(id3 || frame, "\(term) returns MP3 bytes")
                print(
                    "\(term): \(recording.title), \(recording.ipa ?? "no associated IPA"), "
                        + "\(data.count) bytes, \(recording.author), \(recording.licenseName)")
            }
        }
    }
}
