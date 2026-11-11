import Darwin
import Foundation
import NaturalLanguage

enum DictationLocalCleanup {
    @concurrent
    static func clean(_ text: String, mode: DictationCleanupMode, isEnglish: Bool? = nil) async -> String {
        guard mode != .off, !Task.isCancelled,
              isEnglish ?? (NLLanguageRecognizer.dominantLanguage(for: text) == .english)
        else { return text }

        switch mode {
        case .off: return text
        case .basic: return DictationTextFormatter.basicCleanup(text, normalize: normalizeValues, now: { .now })
        case .advanced: return DictationTextFormatter.advancedCleanup(text, normalize: normalizeValues, now: { .now })
        case .smart: return DictationTextFormatter.removingFillerWords(text)
        }
    }

    private static func normalizeValues(_ text: String) -> String {
        let contacts = text.replacing(
            #/
            (?ix: \b
                (?:w[\x20\t]+w[\x20\t]+w|www)[\x20\t]+dot[\x20\t]+
                [a-z0-9][a-z0-9-]*[\x20\t]+dot[\x20\t]+(?:com|org|net|edu|gov|io|ai)\b
                (?![\x20\t]+(?:dot|slash)\b)
            )
            /#
        ) {
            normalize($0.output, matching: /(?i:www\.[a-z0-9][a-z0-9-]*\.[a-z]{2,3})/)
        }.replacing(
            #/
            (?ix: (^|[^\p{L}\p{N}_.+-])
                ([a-z0-9][a-z0-9_-]* (?:[\x20\t]+dot[\x20\t]+[a-z0-9][a-z0-9_-]*)*
                [\x20\t]+at[\x20\t]+
                [a-z0-9][a-z0-9-]*[\x20\t]+dot[\x20\t]+(?:com|org|net|edu|gov|io|ai)\b
                (?![\x20\t]+(?:dot|slash)\b))
            )
            /#
        ) {
            String($0.1) + normalize($0.2, matching: /(?i:[a-z0-9._-]+@[a-z0-9-]+\.[a-z]{2,3})/)
        }.replacing(
            #/
            (?ix: \b
                ((?:phone[\x20\t]+number[\x20\t]+is|call[\x20\t]+me[\x20\t]+at)[\x20\t]+)
                ((?:zero|oh|one|two|three|four|five|six|seven|eight|nine)
                 (?:[\x20\t]+(?:zero|oh|one|two|three|four|five|six|seven|eight|nine)){9})\b
                (?![\x20\t]+(?:zero|oh|one|two|three|four|five|six|seven|eight|nine|[0-9]+)\b)
            )
            /#
        ) {
            String($0.1) + normalize($0.2, matching: /[0-9]{3}-[0-9]{3}-[0-9]{4}/)
        }
        let fractions = contacts.replacing(
            #/
            (?ix: \b
                (?:(?:one|two|three|four|five|six|seven|eight|nine|ten)[\x20\t]+and[\x20\t]+)?
                (?:one[\x20\t]+(?:half|third|quarter|fourth|fifth|sixth|seventh|eighth|ninth|tenth)|
                   (?:two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|
                      fifteen|sixteen|seventeen|eighteen|nineteen|
                      (?:twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)
                      (?:[-\x20\t]+(?:one|two|three|four|five|six|seven|eight|nine))?)[\x20\t]+
                    (?:halves|thirds|quarters|fourths|fifths|sixths|sevenths|eighths|ninths|tenths))\b
            )
            /#
        ) { match in
            let prefix = contacts[..<match.range.lowerBound]
            guard !continuesNumber(prefix) else { return String(match.output) }
            return normalize(match.output, matching: /(?:[0-9]+ )?[0-9]+\/[0-9]+/)
        }
        return fractions.replacing(
            #/
            (?ix: \b
                (?:zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|
                   fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|
                   (?:twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)
                   (?:[-\x20\t]+(?:one|two|three|four|five|six|seven|eight|nine))?)
                [\x20\t]+point[\x20\t]+
                (?:zero|oh|one|two|three|four|five|six|seven|eight|nine)
                (?:[\x20\t]+(?:zero|oh|one|two|three|four|five|six|seven|eight|nine)){0,7}\b
                (?![\x20\t]+(?:zero|oh|one|two|three|four|five|six|seven|eight|nine|[0-9]+)\b)
            )
            /#
        ) { match in
            let prefix = fractions[..<match.range.lowerBound]
            guard !continuesNumber(prefix) else { return String(match.output) }
            return normalize(match.output, matching: /[0-9]+\.[0-9]+/)
        }
    }

    private static func continuesNumber(_ prefix: Substring) -> Bool {
        prefix.suffix(40).firstMatch(of: #/
            (?ix:
                (?:[0-9]|\b(?:zero|oh|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|
                   thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|
                   fifty|sixty|seventy|eighty|ninety|hundred|thousand|million|billion|trillion)
                   (?:[\x20\t]+and)?)
                [-\x20\t]*$
            )
            /#) != nil
    }

    private static func normalize(_ phrase: Substring, matching output: Regex<Substring>) -> String {
        let original = String(phrase)
        guard !Task.isCancelled, original.utf8.count <= 192, !original.utf8.contains(0),
              let runtime else { return original }
        let input = original.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard let pointer = input.withCString(runtime.normalize) else { return original }
        defer { runtime.free(pointer) }
        guard let result = String(validatingCString: pointer), result.wholeMatch(of: output) != nil else {
            return original
        }
        return result
    }

    private struct Runtime: Sendable {
        typealias Normalize = @convention(c) (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
        typealias Free = @convention(c) (UnsafeMutablePointer<CChar>) -> Void

        let normalize: Normalize
        let free: Free
    }

    private static let runtime: Runtime? = {
        guard let url = Bundle.main.privateFrameworksURL?.appending(path: "TinycastTextFormatting.dylib"),
              let handle = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else { return nil }
        guard let normalize = dlsym(handle, "nemo_normalize"),
              let free = dlsym(handle, "nemo_free_string") else {
            dlclose(handle)
            return nil
        }
        return Runtime(
            normalize: unsafeBitCast(normalize, to: Runtime.Normalize.self),
            free: unsafeBitCast(free, to: Runtime.Free.self))
    }()
}
