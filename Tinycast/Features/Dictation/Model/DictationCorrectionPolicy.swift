import Foundation

enum DictationCorrectionPolicy {
    enum Confidence: Equatable {
        case clear
        case candidate
    }

    struct Span {
        let words: [Substring]
        let looksLikeName: Bool
    }

    private static let sensitiveWords = Set("""
        no not never neither nor none nothing nobody without cannot cant wont dont only
        zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen
        sixteen seventeen eighteen nineteen twenty thirty forty fifty sixty seventy eighty ninety
        hundred thousand million billion trillion half quarter first second third fourth fifth sixth
        seventh eighth ninth tenth monday tuesday wednesday thursday friday saturday sunday
        january february march april may june july august september october november december
        today tomorrow yesterday noon midnight am pm dollars dollar euros euro pounds pound cents cent
        """.split(whereSeparator: \.isWhitespace).map(String.init))

    static func confidence(
        from wrong: Span, to right: Span, isKnownWord: (String) -> Bool
    ) -> Confidence? {
        let old = wrong.words.map(fold)
        let new = right.words.map(fold)
        guard !old.contains(where: sensitiveWords.contains), !new.contains(where: sensitiveWords.contains)
        else { return nil }
        let wrongKnown = wrong.words.allSatisfy { isKnownWord(String($0)) }
        let rightKnown = right.words.allSatisfy { isKnownWord(String($0)) }
        let oldLetters = old.joined()
        let newLetters = new.joined()

        if old == new {
            guard gainsCapitals(from: wrong.words, to: right.words), right.looksLikeName,
                !right.words.allSatisfy({ isKnownWord($0.lowercased()) })
            else { return nil }
            return .candidate
        }
        if oldLetters == newLetters {
            guard !(wrongKnown && rightKnown) else { return nil }
            return right.looksLikeName ? .clear : .candidate
        }

        let similarity = Similarity(oldLetters, newLetters)
        if wrongKnown && rightKnown {
            let bothNames = wrong.looksLikeName && right.looksLikeName
            return bothNames && similarity.isLoose ? .candidate : nil
        }
        if rightKnown {
            if similarity.isStrong, similarity.soundsAlike, right.looksLikeName { return .clear }
            return similarity.isLoose ? .candidate : nil
        }
        if right.looksLikeName {
            if similarity.isStrong { return .clear }
            if similarity.isLoose { return .candidate }
            let ratio = Double(newLetters.count) / Double(max(oldLetters.count, 1))
            let merged = old.count > new.count && (0.5...1.5).contains(ratio)
            return merged && similarity.sameOnset ? .candidate : nil
        }
        return similarity.isStrong && min(oldLetters.count, newLetters.count) >= 5 ? .candidate : nil
    }

    /// A coarse sound key: voiced and unvoiced pairs share a code and inner vowels drop out.
    static func phoneticKey(_ text: some StringProtocol) -> String {
        let letters = Array(fold(text).folding(options: .diacriticInsensitive, locale: nil)
            .filter { $0.isASCII && $0.isLetter })
        var codes: [Character] = []
        var index = 0
        if letters.count > 1, ["kn", "gn", "pn", "wr"].contains(String(letters[0...1])) { index = 1 }
        while index < letters.count {
            let letter = letters[index]
            let next = index + 1 < letters.count ? letters[index + 1] : nil
            let softens = next.map { "eiy".contains($0) } ?? false
            var code: String?
            switch letter {
            case "a", "e", "i", "o", "u", "y": code = codes.isEmpty ? "A" : nil
            case "b": code = "P"
            case "p": code = next == "h" ? "F" : "P"
            case "c": code = next == "h" ? "X" : softens ? "S" : "K"
            case "d": code = "T"
            case "t": code = next == "h" ? "0" : "T"
            case "f", "v": code = "F"
            case "g": code = next == "h" ? nil : softens ? "J" : "K"
            case "h", "w": code = codes.isEmpty ? String(letter).uppercased() : nil
            case "j": code = "J"
            case "k", "q": code = "K"
            case "s": code = next == "h" ? "X" : "S"
            case "x": code = "KS"
            case "z": code = "S"
            default: code = String(letter).uppercased()
            }
            if "pcts".contains(letter), next == "h" { index += 1 }
            if letter == "g", next == "h" { index += 1 }
            if let code, codes.last.map(String.init) != code { codes.append(contentsOf: code) }
            index += 1
        }
        return String(codes)
    }

    private struct Similarity {
        let isStrong: Bool
        let isLoose: Bool
        let sameOnset: Bool
        let soundsAlike: Bool

        init(_ old: String, _ new: String) {
            let shorter = min(old.count, new.count)
            let edits = new.difference(from: old)
            let changed = max(edits.insertions.count, edits.removals.count)
            let samePrefix = zip(old, new).prefix { $0 == $1 }.count
            let sameSuffix = zip(old.reversed(), new.reversed()).prefix { $0 == $1 }.count
            let oneSided = edits.insertions.isEmpty || edits.removals.isEmpty
            let oldKey = DictationCorrectionPolicy.phoneticKey(old)
            let newKey = DictationCorrectionPolicy.phoneticKey(new)
            sameOnset = oldKey.first == newKey.first
            soundsAlike = oldKey.count >= 2 && oldKey == newKey
            isStrong = changed == 1 || (soundsAlike && oldKey.count >= 3) || changed <= shorter / 4
                || (changed == 2 && shorter >= 5 && (oneSided || samePrefix + sameSuffix >= 3))
            isLoose = isStrong || (sameOnset && shorter >= 4 && changed <= 3 && max(samePrefix, sameSuffix) >= 3)
        }
    }

    private static func gainsCapitals(from old: [Substring], to new: [Substring]) -> Bool {
        let before = old.joined().count(where: \.isUppercase)
        let after = new.joined().count(where: \.isUppercase)
        return after > before && zip(old, new).allSatisfy { lower, upper in
            zip(lower, upper).allSatisfy { $0 == $1 || ($0.isLowercase && $1.isUppercase) }
        }
    }

    private static func fold(_ word: some StringProtocol) -> String {
        word.folding(options: .caseInsensitive, locale: nil)
    }
}
