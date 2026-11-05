import Foundation

/// A broad English IPA guide; unfamiliar notation stays available only as the original IPA.
enum PronunciationRespelling {
    private enum Stress { case none, primary, secondary }

    private struct Sound {
        let symbol: String
        let spelling: String
        let isVowel: Bool
    }

    private static let vowels = [
        "eɪ": "ay", "aɪ": "ai", "ɑɪ": "ai", "ɔɪ": "oy", "aʊ": "ow", "ɑʊ": "ow",
        "oʊ": "oh", "əʊ": "oh", "ɪə": "eer", "eə": "air", "ɛə": "air", "ʊə": "uur",
        "i": "ee", "ɪ": "i", "e": "e", "ɛ": "e", "æ": "a", "ɑ": "ah", "ɒ": "o",
        "ɔ": "aw", "ʊ": "uu", "u": "oo", "ə": "uh", "ʌ": "uh", "ɜ": "ur",
        "ɝ": "ur", "ɚ": "er", "n̩": "uhn", "l̩": "uhl", "m̩": "uhm"
    ]
    private static let consonants = [
        "t͡ʃ": "ch", "d͡ʒ": "j", "t͜ʃ": "ch", "d͜ʒ": "j", "tʃ": "ch", "dʒ": "j",
        "p": "p", "b": "b", "t": "t", "d": "d", "k": "k", "ɡ": "g", "g": "g",
        "f": "f", "v": "v", "θ": "th", "ð": "dh", "s": "s", "z": "z", "ʃ": "sh",
        "ʒ": "zh", "h": "h", "m": "m", "n": "n", "ŋ": "ng", "l": "l", "ɫ": "l",
        "ɹ": "r", "r": "r", "j": "y", "w": "w", "ɾ": "d", "ʍ": "wh"
    ]
    private static let symbols = (Array(vowels.keys) + Array(consonants.keys))
        .sorted { $0.count > $1.count }
    private static let shortVowels: Set<String> = ["ɪ", "e", "ɛ", "æ", "ɒ", "ʊ", "ʌ"]
    private static let openVowels = ["ɪ": "ih", "e": "eh", "ɛ": "eh"]
    private static let onsets: Set<String> = [
        "p", "b", "t", "d", "k", "g", "f", "v", "th", "dh", "s", "z", "sh", "zh",
        "ch", "j", "h", "m", "n", "l", "r", "y", "w", "wh", "pl", "pr", "bl", "br",
        "tr", "dr", "kl", "kr", "gl", "gr", "fl", "fr", "thr", "shr", "sl", "sm",
        "sn", "sp", "st", "sk", "sw", "tw", "dw", "kw", "gw", "spl", "spr", "str",
        "skr", "skw", "skl", "py", "by", "ty", "dy", "ky", "gy", "fy", "vy", "my",
        "ny", "ly", "hy", "spy", "sty", "sky"
    ]
    private static let rhoticVowels = [
        "ə": "er", "ɜ": "ur", "ɑ": "ar", "ɒ": "or", "ɔ": "or", "e": "air",
        "ɛ": "air", "ɪ": "eer", "ʊ": "uur", "æ": "arr", "ʌ": "uhr", "u": "oor",
        "aɪ": "ire", "ɑɪ": "ire", "aʊ": "owr", "ɑʊ": "owr", "oʊ": "ohr", "əʊ": "ohr",
        "ɪə": "eer", "eə": "air", "ɛə": "air", "ʊə": "uur"
    ]

    static func english(_ ipa: String) -> String? {
        guard ipa.utf8.count <= 2048 else { return nil }
        var input = ipa.trimmingCharacters(in: .whitespacesAndNewlines)[...]
        if let first = input.first, let last = input.last,
           (first == "/" && last == "/") || (first == "[" && last == "]")
            || (first == "|" && last == "|") {
            input = input.dropFirst().dropLast()
        }
        var sounds: [Sound] = []
        var stress = Stress.none
        var lengthAllowed = false
        var result: [String] = []

        func finishSegment() -> Bool {
            guard let syllables = syllables(sounds, stress: stress) else { return false }
            result.append(contentsOf: syllables)
            sounds.removeAll(keepingCapacity: true)
            stress = .none
            lengthAllowed = false
            return true
        }

        while let first = input.first {
            if first == "." || first == "·" {
                guard finishSegment() else { return nil }
                input = input.dropFirst()
                continue
            }
            if first == "ˈ" || first == "ˌ" {
                if !sounds.isEmpty, !finishSegment() { return nil }
                guard stress == .none else { return nil }
                stress = first == "ˈ" ? .primary : .secondary
                input = input.dropFirst()
                continue
            }
            if first == "ː" || first == "ˑ" {
                guard lengthAllowed else { return nil }
                lengthAllowed = false
                input = input.dropFirst()
                continue
            }
            guard let symbol = symbols.first(where: { input.hasPrefix($0) }),
                  let spelling = vowels[symbol] ?? consonants[symbol] else { return nil }
            let isVowel = vowels[symbol] != nil
            sounds.append(Sound(symbol: symbol, spelling: spelling, isVowel: isVowel))
            lengthAllowed = isVowel
            input = input.dropFirst(symbol.count)
        }
        guard finishSegment() else { return nil }
        return result.joined(separator: "·")
    }

    private static func syllables(_ sounds: [Sound], stress: Stress) -> [String]? {
        let nuclei = sounds.indices.filter { sounds[$0].isVowel }
        guard !nuclei.isEmpty else { return nil }
        var starts = [0]
        for position in nuclei.indices.dropFirst() {
            let previous = nuclei[position - 1]
            let next = nuclei[position]
            var onset = next
            for candidate in (previous + 1)..<next {
                let cluster = sounds[candidate..<next].map(\.spelling).joined()
                if onsets.contains(cluster) {
                    onset = candidate
                    break
                }
            }
            // A stressed short vowel needs a coda when the source omits syllable boundaries.
            if position == 1, stress != .none, shortVowels.contains(sounds[previous].symbol),
               previous + 1 < next {
                onset = max(onset, previous + 2)
            }
            starts.append(onset)
        }
        starts.append(sounds.count)
        return starts.indices.dropLast().map { position in
            let spelling = spell(sounds[starts[position]..<starts[position + 1]])
            return position == 0 && stress == .primary ? spelling.uppercased() : spelling
        }
    }

    private static func spell(_ sounds: ArraySlice<Sound>) -> String {
        var result = ""
        var index = sounds.startIndex
        while index < sounds.endIndex {
            let sound = sounds[index]
            let next = index + 1
            if next < sounds.endIndex, sounds[next].spelling == "r",
               let rhotic = rhoticVowels[sound.symbol] {
                result += rhotic
                index += 2
            } else {
                result += next == sounds.endIndex ? openVowels[sound.symbol] ?? sound.spelling
                    : sound.spelling
                index += 1
            }
        }
        return result.replacingOccurrences(of: "ngk", with: "nk")
    }
}
