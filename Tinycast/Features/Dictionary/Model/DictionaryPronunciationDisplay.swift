import Foundation

enum DictionaryPronunciationDisplay {
    static func guide(ipa: String?, variants: [String], written: String?) -> String? {
        if let ipa, let guide = PronunciationRespelling.english(ipa) { return guide }
        for variant in variants {
            if let guide = PronunciationRespelling.english(variant) { return guide }
        }
        let fallback = written?.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback?.isEmpty == false ? fallback : nil
    }

    static func accentKey(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let key = canonicalAccent(value) { return key }
        if value.hasPrefix("audio") {
            let suffix = value.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if suffix.first == "(", suffix.last == ")",
               let key = canonicalAccent(String(suffix.dropFirst().dropLast())) {
                return key
            }
        }
        return value
    }

    static func recordings(_ recordings: [DictionaryPronunciation.Recording])
        -> [DictionaryPronunciation.Recording] {
        var seen: Set<String> = []
        return recordings.filter { seen.insert(accentKey($0.title)).inserted }
    }

    private static func canonicalAccent(_ value: String) -> String? {
        switch value.split(whereSeparator: \.isWhitespace).joined(separator: " ") {
        case "ga", "us", "usa", "en-us", "general american", "generalamerican",
             "general-american", "united states": "en-US"
        case "gb", "uk", "en-gb", "rp", "received pronunciation", "ssb",
             "standard southern british", "southern england", "southernengland": "en-GB"
        case "au", "en-au", "australia", "australian": "en-AU"
        default: nil
        }
    }
}
