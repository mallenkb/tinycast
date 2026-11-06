import Foundation

@main struct DictionaryPronunciationDisplayTests {
    static func main() {
        let apples = ["/ˈæpəl/", "/ˈæp.əl/", "/ˈæpl̩/"]
        for ipa in apples {
            precondition(PronunciationRespelling.english(ipa) == "AP·uhl")
        }
        expectGuide(ipa: apples[0], variants: apples, written: "Other", expected: "AP·uhl")
        expectGuide(ipa: nil, variants: apples, written: nil, expected: "AP·uhl")
        expectGuide(ipa: "/ʁoʊz/", variants: apples, written: "Other", expected: "AP·uhl")
        expectGuide(ipa: "/kæt/", variants: apples, written: "Other", expected: "kat")
        expectGuide(ipa: nil, variants: ["/ʁ/", "/dɒɡ/", "/kæt/"], written: nil, expected: "dog")
        expectGuide(ipa: nil, variants: [], written: "  lai·bruh·ree\n", expected: "lai·bruh·ree")
        expectGuide(ipa: "/ʁ/", variants: ["/kɑ̃/"], written: " fallback ", expected: "fallback")
        expectGuide(ipa: nil, variants: [], written: " \n\t", expected: nil)
        expectGuide(ipa: nil, variants: [], written: nil, expected: nil)
        expectGuide(ipa: "", variants: ["", "//"], written: nil, expected: nil)

        let accents: [(String, String)] = [
            ("GA", "en-US"), ("US", "en-US"), ("General American", "en-US"),
            ("generalamerican", "en-US"), (" en-US \n", "en-US"),
            ("Audio (US)", "en-US"), ("Audio(General American)", "en-US"),
            ("UK", "en-GB"), ("RP", "en-GB"), ("Received Pronunciation", "en-GB"),
            ("SSB", "en-GB"), ("Standard Southern British", "en-GB"),
            ("Southern England", "en-GB"), ("southernengland", "en-GB"),
            (" Audio ( SSB ) ", "en-GB"), ("AU", "en-AU"), ("Australian", "en-AU"),
            ("en-au", "en-AU"), (" Scottish ", "scottish"), ("EN-NZ", "en-nz"),
            ("US, UK", "us, uk"), ("Audio (Scottish)", "audio (scottish)"),
            ("An American narrator", "an american narrator"), ("", "")
        ]
        for (label, expected) in accents {
            precondition(DictionaryPronunciationDisplay.accentKey(label) == expected, label)
        }

        let ga = recording("first-us", "GA")
        let us = recording("second-us", "Audio (US)")
        let generalAmerican = recording("third-us", "General American")
        let ssb = recording("first-gb", "SSB")
        let rp = recording("second-gb", "RP")
        let southEngland = recording("third-gb", "Southern England")
        let australia = recording("au", "AU")
        let scotland = recording("scotland", "Scottish")
        let scotlandDuplicate = recording("scotland-again", " SCOTTISH ")
        let nz = recording("nz", "en-NZ")
        let all = [ga, us, generalAmerican, ssb, rp, southEngland, australia,
                   scotland, scotlandDuplicate, nz]
        precondition(DictionaryPronunciationDisplay.recordings(all) == [ga, ssb, australia, scotland, nz])
        precondition(DictionaryPronunciationDisplay.recordings([us, ga]) == [us])
        precondition(DictionaryPronunciationDisplay.recordings([rp, ssb]) == [rp])
        precondition(DictionaryPronunciationDisplay.recordings([ga, ga]) == [ga])
        precondition(DictionaryPronunciationDisplay.recordings([]).isEmpty)
        print("Dictionary pronunciation display passed single-guide, fallback and accent grouping checks")
    }

    private static func expectGuide(ipa: String?, variants: [String], written: String?, expected: String?) {
        let result = DictionaryPronunciationDisplay.guide(ipa: ipa, variants: variants, written: written)
        precondition(result == expected, "Guide \(result ?? "nil"); expected \(expected ?? "nil")")
    }

    private static func recording(_ id: String, _ title: String) -> DictionaryPronunciation.Recording {
        DictionaryPronunciation.Recording(
            id: id, title: title, ipa: nil,
            audioURL: URL(string: "https://upload.wikimedia.org/\(id).ogg")!,
            sourceURL: URL(string: "https://commons.wikimedia.org/wiki/File:\(id).ogg")!,
            author: "Reader", licenseName: "CC0", licenseURL: nil)
    }
}
