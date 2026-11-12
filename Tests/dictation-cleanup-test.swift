import Foundation

@main
struct DictationCleanupTest {
    private enum Failure: Error {
        case request
    }

    static func main() async throws {
        let sentence = String(repeating: "word ", count: 210) + "ends here."
        let nextSentence = String(repeating: "another word ", count: 160) + "ends here."
        let text = " \t" + sentence + "\n\n  " + nextSentence + "\r\n\t"
        let sentenceEnd = text.index(text.startIndex, offsetBy: 2 + sentence.count)
        let chunks = DictationCleanupChunks(text, sentenceRanges: [text.startIndex..<sentenceEnd])
        precondition(chunks.ranges.count >= 3)
        precondition(text[chunks.ranges[0]] == sentence)
        precondition(chunks.ranges.allSatisfy { text[$0].utf8.count <= DictationCleanupChunks.byteLimit })
        let reconstructed = try await chunks.cleaned { $0 }
        precondition(reconstructed.utf8.elementsEqual(text.utf8))
        let edited = try await chunks.cleaned { "[" + $0 + "]" }
        precondition(edited.hasPrefix(" \t[" + sentence + "]\n\n  ["))
        precondition(edited.hasSuffix("ends here.]\r\n\t"))

        let sentences = sentence + " " + nextSentence
        let firstEnd = sentences.index(sentences.startIndex, offsetBy: sentence.count)
        let atSentence = DictationCleanupChunks(sentences, sentenceRanges: [sentences.startIndex..<firstEnd])
        precondition(sentences[atSentence.ranges[0]] == sentence)

        let prefix = String(repeating: "word ", count: 359)
        for expression in ["Dr. Rivera", "e.g. that one", "3.14159265359"] {
            let input = prefix + expression + " checked the rest of the text."
            let plan = DictationCleanupChunks(input, sentenceRanges: [])
            precondition(plan.ranges.count == 2)
            precondition(input[plan.ranges[1]].hasPrefix(expression))
        }

        let unicode = String(repeating: "é 👩🏽‍🔧 🇬🇭 ", count: 200)
        let unicodeChunks = DictationCleanupChunks(unicode, sentenceRanges: [])
        precondition(unicodeChunks.ranges.count > 1)
        precondition(unicodeChunks.ranges.allSatisfy { unicode[$0].utf8.count <= DictationCleanupChunks.byteLimit })
        let reconstructedUnicode = try await unicodeChunks.cleaned { $0 }
        precondition(reconstructedUnicode.utf8.elementsEqual(unicode.utf8))

        let url = "https://example.com/" + String(repeating: "x", count: 4_000)
        let urlChunks = DictationCleanupChunks("Check " + url + " in the report.", sentenceRanges: [])
        let editedURL = try await urlChunks.cleaned { "[" + $0 + "]" }
        precondition(editedURL == "[Check] " + url + " [in the report.]")

        let oversizedSentence = String(repeating: "長", count: 700) + "。"
        let compact = "短い文。" + oversizedSentence + "次の文。"
        let shortEnd = compact.index(compact.startIndex, offsetBy: "短い文。".count)
        let oversizedEnd = compact.index(shortEnd, offsetBy: oversizedSentence.count)
        let compactChunks = DictationCleanupChunks(
            compact, sentenceRanges: [compact.startIndex..<shortEnd, shortEnd..<oversizedEnd])
        let editedCompact = try await compactChunks.cleaned { "[" + $0 + "]" }
        precondition(editedCompact == "[短い文。]" + oversizedSentence + "[次の文。]")

        let whitespace = "  \t\n"
        let blank = try await DictationCleanupChunks(whitespace, sentenceRanges: []).cleaned { _ in
            preconditionFailure("Whitespace should not reach the engine")
        }
        precondition(blank == whitespace)

        precondition(DictationCleanupChunks.hasProtectedValue("The payment is due on May first."))
        precondition(DictationCleanupChunks.hasProtectedValue("It costs a cedi."))
        precondition(DictationCleanupChunks.hasProtectedValue("Call at 9:30 AM."))
        precondition(DictationCleanupChunks.acceptsSmartEdit(
            "Hello, everyone. Please send the signed contract.", source: "hello everyone please send the signed contract"))
        precondition(!DictationCleanupChunks.acceptsSmartEdit(
            "Wire the payment to this address.", source: "Do not wire the payment to this address."))
        precondition(!DictationCleanupChunks.acceptsSmartEdit(
            "Please send the signed contract.", source: "Please send the signed contract and attach the invoice."))

        var requests = 0
        do {
            _ = try await chunks.cleaned { chunk in
                requests += 1
                if requests == 2 { throw Failure.request }
                return chunk.uppercased()
            }
            preconditionFailure("A failed request should discard the partial result")
        } catch Failure.request {
            precondition(requests == 2)
        }

        let cancelled = Task {
            var requests = 0
            do {
                _ = try await chunks.cleaned { chunk in
                    requests += 1
                    withUnsafeCurrentTask { $0?.cancel() }
                    return chunk
                }
                preconditionFailure("Cancellation should discard the partial result")
            } catch is CancellationError {
                precondition(requests == 1)
            }
        }
        try await cancelled.value
        print("Dictation cleanup chunk checks passed")
    }
}
