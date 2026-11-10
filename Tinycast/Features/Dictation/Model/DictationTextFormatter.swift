import Foundation

enum DictationTextFormatter {
    struct Context: Sendable {
        let trailing: Character?
        let lastNonWhitespace: Character?
        let newParagraph: Bool
        let following: Character?

        init(before: Substring, after: Substring) {
            trailing = before.last
            following = after.first
            var last: Character?
            var paragraph = false
            for character in before.reversed() {
                if !character.isWhitespace {
                    last = character
                    break
                }
                if character.isNewline { paragraph = true }
            }
            lastNonWhitespace = last
            newParagraph = paragraph
        }
    }

    static func removingFillerWords(_ transcript: String) -> String {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.wholeMatch(of: /(?:[Uu][mh][,.!?…]*(?:[ \t]+|$))+/) != nil { return "" }
        return text
            .replacing(/(^|\n|[.!?…][ \t]+)(?:[Uu][mh][,.!?…]*[ \t]+)+(\p{L})/) { match in
                String(match.1) + match.2.uppercased()
            }
            .replacing(/([.!?…])[ \t]+(?:[Uu][mh][,.!?…]*(?:[ \t]+|$))+$/) { String($0.1) }
            .replacing(/(?:,[ \t]+[Uu][mh],|[ \t]+[Uu][mh],?)(?=\s|$)/, with: "")
            .replacing(/,?[ \t]+[Uu][mh](?=[.!?…]+(?:\s|$))/, with: "")
    }

    static func format(_ transcription: String, context: Context?, adaptCapitalization: Bool = true) -> String
    {
        var text = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let context else { return text }
        if adaptCapitalization, let first = text.first, first.isLetter {
            let replacement: String
            if context.lastNonWhitespace == nil || context.newParagraph
                || context.lastNonWhitespace.map({ ".!?".contains($0) }) == true
            {
                replacement = String(first).uppercased()
            } else {
                replacement = String(first).lowercased()
            }
            text.replaceSubrange(text.startIndex...text.startIndex, with: replacement)
        }
        if let trailing = context.trailing, !trailing.isWhitespace,
            !"([{/\"'‘’“—-".contains(trailing),
            let leading = text.first, !".,!?;:)]}/\"'”".contains(leading)
        {
            text = " " + text
        }
        if let leading = context.following, !leading.isWhitespace,
            let trailing = text.last, !trailing.isWhitespace,
            !".,!?;:)]}/\"'”".contains(leading)
        {
            text += " "
        }
        return text
    }
}
