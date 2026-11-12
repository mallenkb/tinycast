import Darwin
import Foundation
import NaturalLanguage

enum DictationLocalCleanup {
    struct PreparedBlock: Sendable {
        fileprivate let source: DictationPreviewSequence.CleanupBlock
        fileprivate let mode: DictationCleanupMode
        fileprivate let line: String?
        fileprivate let values: [Data: String]

        var isUseful: Bool { line != nil || !values.isEmpty }
    }

    @concurrent
    static func prepare(_ block: DictationPreviewSequence.CleanupBlock, mode: DictationCleanupMode) async -> PreparedBlock {
        var values: [Data: String] = [:]
        let normalize: (String) -> String = { text in
            normalizeValues(text) { phrase, output in
                let result = Self.normalize(phrase, matching: output)
                if values.count < 16, !phrase.utf8.elementsEqual(result.utf8) {
                    values[Data(phrase.utf8)] = result
                }
                return result
            }
        }
        var line: String?
        if !Task.isCancelled {
            if block.isLine, mode == .basic {
                line = DictationTextFormatter.cleanBasicLine(block.text[...], normalize: normalize)
            } else if block.isLine, mode == .advanced {
                line = DictationTextFormatter.cleanAdvancedLine(block.text[...], normalize: normalize)
            } else {
                _ = normalize(block.text)
            }
        }
        return PreparedBlock(source: block, mode: mode, line: line, values: values)
    }

    @concurrent
    static func clean(
        _ text: String, mode: DictationCleanupMode, isEnglish: Bool? = nil, prepared: [PreparedBlock] = [],
        now: @Sendable () -> ContinuousClock.Instant = { .now }
    ) async -> String {
        guard mode != .off, !Task.isCancelled,
              isEnglish ?? (NLLanguageRecognizer.dominantLanguage(for: text) == .english)
        else { return text }

        let normalize: (String) -> String = { text in
            normalizeValues(text) { phrase, output in
                Self.normalize(phrase, matching: output, prepared: prepared)
            }
        }
        let preparedLine: (Substring) -> String? = { line in
            prepared.first {
                $0.mode == mode && $0.line != nil && $0.source.text.utf8.elementsEqual(line.utf8)
            }?.line
        }
        switch mode {
        case .off: return text
        case .basic:
            return DictationTextFormatter.basicCleanup(text, normalize: normalize, preparedLine: preparedLine, now: now)
        case .advanced:
            return DictationTextFormatter.advancedCleanup(text, normalize: normalize, preparedLine: preparedLine, now: now)
        case .smart: return DictationTextFormatter.removingFillerWords(text)
        }
    }

    private static func normalizeValues(
        _ text: String, normalize: (Substring, Regex<Substring>) -> String
    ) -> String {
        let contacts = text.replacing(
            #/
            (?ix: \b
                (?:w[\x20\t]+w[\x20\t]+w|www)[\x20\t]+dot[\x20\t]+
                [a-z0-9][a-z0-9-]*[\x20\t]+dot[\x20\t]+(?:com|org|net|edu|gov|io|ai)\b
                (?![\x20\t]+(?:dot|slash)\b)
            )
            /#
        ) {
            normalize($0.output, /(?i:www\.[a-z0-9][a-z0-9-]*\.[a-z]{2,3})/)
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
            String($0.1) + normalize($0.2, /(?i:[a-z0-9._-]+@[a-z0-9-]+\.[a-z]{2,3})/)
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
            String($0.1) + normalize($0.2, /[0-9]{3}-[0-9]{3}-[0-9]{4}/)
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
            return normalize(match.output, /(?:[0-9]+ )?[0-9]+\/[0-9]+/)
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
            return normalize(match.output, /[0-9]+\.[0-9]+/)
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

    private static func normalize(
        _ phrase: Substring, matching output: Regex<Substring>, prepared: [PreparedBlock] = []
    ) -> String {
        let original = String(phrase)
        guard !Task.isCancelled, original.utf8.count <= 192, !original.utf8.contains(0) else { return original }
        if !prepared.isEmpty {
            let key = Data(original.utf8)
            for block in prepared {
                if let result = block.values[key], result.wholeMatch(of: output) != nil { return result }
            }
        }
        guard let runtime else { return original }
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
