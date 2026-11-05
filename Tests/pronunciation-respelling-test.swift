import Foundation

@main struct PronunciationRespellingTests {
    static func main() {
        let examples: [(String, String, String)] = [
            ("library, screenshot variant", "/ˈlaɪ.bɹə.ɹi/", "LAI·bruh·ree"),
            ("library, inferred syllables", "ˈlaɪbɹəri", "LAI·bruh·ree"),
            ("library, Cambridge UK", "/ˈlaɪ.brər.i/", "LAI·brer·ee"),
            ("library, Cambridge US", "/ˈlaɪ.brer.i/", "LAI·brair·ee"),
            ("hello", "/həˈloʊ/", "huh·LOH"),
            ("about", "/əˈbaʊt/", "uh·BOWT"),
            ("system", "/ˈsɪs.təm/", "SIS·tuhm"),
            ("piano", "/piˈænoʊ/", "pee·AN·oh"),
            ("retell, secondary stress", "/ˌriːˈtel/", "ree·TEL"),
            ("cat", "/kæt/", "kat"),
            ("dog, UK", "/dɒɡ/", "dog"),
            ("father, UK", "/ˈfɑː.ðə/", "FAH·dhuh"),
            ("father, US", "/ˈfɑðɚ/", "FAH·dher"),
            ("ship", "/ʃɪp/", "ship"),
            ("sheep", "/ʃiːp/", "sheep"),
            ("food", "/fuːd/", "food"),
            ("foot", "/fʊt/", "fuut"),
            ("cup", "/kʌp/", "kuhp"),
            ("day", "/deɪ/", "day"),
            ("eye", "/aɪ/", "ai"),
            ("boy", "/bɔɪ/", "boy"),
            ("goat, UK", "/ɡəʊt/", "goht"),
            ("goat, US", "/goʊt/", "goht"),
            ("mouth", "/maʊθ/", "mowth"),
            ("near, UK", "/nɪə/", "neer"),
            ("hair, UK", "/heə/", "hair"),
            ("pure, UK", "/pjʊə/", "pyuur"),
            ("fire, UK", "/faɪə/", "fai·uh"),
            ("fire, US", "/faɪɹ/", "fire"),
            ("wire, US", "/waɪr/", "wire"),
            ("car", "/kɑɹ/", "kar"),
            ("fair", "/fɛɹ/", "fair"),
            ("marry, unmerged vowel", "/ˈmæri/", "MARR·ee"),
            ("very, explicit vowel boundary", "/ˈvɛ.ri/", "VEH·ree"),
            ("short i, explicit vowel boundary", "/ˈɪ.vən/", "IH·vuhn"),
            ("international", "/ˌɪntəˈnæʃənəl/", "in·tuh·NASH·uh·nuhl"),
            ("hour, UK", "/aʊə/", "ow·uh"),
            ("bird, UK", "/bɜːd/", "burd"),
            ("bird, US", "/bɝd/", "burd"),
            ("mother, US", "/ˈmʌðɚ/", "MUHDH·er"),
            ("church", "/tʃɜːtʃ/", "church"),
            ("choice, tied affricate", "/t͡ʃɔɪs/", "choys"),
            ("judge, tied affricates", "/d͜ʒʌd͡ʒ/", "juhj"),
            ("think", "/θɪŋk/", "think"),
            ("yes", "/jɛs/", "yes"),
            ("vision", "/ˈvɪʒ.ən/", "VIZH·uhn"),
            ("bottle, syllabic l", "/ˈbɒtl̩/", "BOT·uhl"),
            ("button, syllabic n", "/ˈbʌtn̩/", "BUHT·uhn"),
            ("water, US flap", "/ˈwɔɾɚ/", "WAW·der"),
            ("explicit middle dots", "[ˈlaɪ·brə·ri]", "LAI·bruh·ree"),
            ("outer whitespace", " \n/kæt/\n ", "kat"),
            ("maximum input", String(repeating: "ə", count: 1024),
             Array(repeating: "uh", count: 1024).joined(separator: "·"))
        ]
        for (word, ipa, expected) in examples {
            let actual = PronunciationRespelling.english(ipa)
            precondition(actual == expected, "\(word): \(ipa) returned \(actual ?? "nil"), expected \(expected)")
        }

        let unsupported = [
            "", " ", "//", "/ˈ/", "/ːi/", "/iːː/", "/kæt/ /dɒɡ/", "/kæt, dɒɡ/",
            "/kæt", "kæt/", "ˈlīˌbrerē", "/ʁoʊz/", "/kɑ̃/", "/bʌʔə/", "/mʏn/",
            "/ˈlaɪ(b)rəɹi/", "/kæt./", "/.kæt/", "/kæ..t/", "/ˈˌkæt/", "/str/",
            "/kæt🙂/", "/i˥/", String(repeating: "ə", count: 1025)
        ]
        for ipa in unsupported {
            precondition(PronunciationRespelling.english(ipa) == nil, "Unsupported IPA accepted: \(ipa)")
        }
        print("Pronunciation respelling passed \(examples.count) English guides and \(unsupported.count) refusal cases")
    }
}
