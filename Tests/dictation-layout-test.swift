import Foundation

@main
struct DictationLayoutTest {
    static func main() {
        var failures = 0
        func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
            guard !condition else { return }
            print(message())
            failures += 1
        }
        func verdict(_ source: String, _ edited: String, reference: String? = nil) -> DictationEditCheck.Verdict {
            DictationEditCheck.verdict(source: source, edited: edited, reference: reference)
        }

        let spoken = "okay so um for the launch on Friday no sorry Monday we need three things. First update "
            + "the pricing page, second email the beta list and third check the analytics dashboard."
        let accepted: [(String, String, String?)] = [
            (spoken, "For the launch on Monday, we need three things:\n1. Update the pricing page.\n"
                + "2. Email the beta list.\n3. Check the analytics dashboard.", nil),
            ("The total is forty five dollars and ninety nine cents.", "The total is $45.99.", nil),
            ("Ship on June twenty fourth twenty twenty seven.", "Ship on June 24, 2027.",
             "Ship on June 24, 2027."),
            ("Let's meet at nine thirty.", "Let's meet at 9:30.", nil),
            ("We we're gonna send it it tomorrow.", "We're going to send it tomorrow.", nil),
            ("I don't think we should ship it.", "I do not think we should ship it.", nil),
            ("Um, uh.", "", nil),
            ("Send it to Ana, new paragraph, thanks.", "Send it to Ana.\n\nThanks.", nil),
            ("The rate is twelve point five per cent.", "The rate is 12.5%.", nil),
            ("The shift starts at 07:30.", "The shift starts at 7:30.", nil),
            ("Meet at nine thirty, no sorry, ten.", "Meet at 10.", nil),
            ("Save the receipt, email Ana the invoice, scratch that, email Ben the invoice.",
             "Save the receipt, email Ben the invoice.", nil),
            ("Charge ten dollars. Scratch that. Charge twelve dollars.", "Charge $12.",
             "Charge $10. Scratch that. Charge $12.")
        ]
        for (source, edited, reference) in accepted {
            let result = verdict(source, edited, reference: reference)
            expect(result == .accepted, "Expected acceptance, got \(result): \(edited.debugDescription)")
        }

        let rejected: [(String, String, DictationEditCheck.Verdict)] = [
            ("Can we test a shorter version with five users?", "Can we test a shorter version with a few users?",
             .changedNumber),
            ("The total is forty five dollars.", "The total is $54.", .changedNumber),
            ("I don't think we should ship it.", "I think we should ship it.", .changedNegation),
            ("We should not ship it.", "We should ship it.", .changedNegation),
            ("I talked to Ana about the flow.", "I talked to Anna about the flow.", .changedName),
            ("What is the capital of France?",
             "The capital of France is Paris, a city known for its museums and its long history of art.",
             .changedName),
            ("Send the agenda to the team before the meeting starts.",
             "Distribute the itinerary among colleagues prior to commencement.", .changedWords),
            ("Book the room.", "", .changedWords),
            ("The shift starts at 07:30.", "The shift starts at 8:30.", .changedNumber),
            ("Meet at nine thirty, no sorry, ten.", "Meet at 9.", .changedNumber),
            ("Save the receipt, email Ana the invoice, scratch that, email Ben the invoice.",
             "Email Ben the invoice.", .changedWords),
            ("Ask Ana about the scratch on the desk.", "Ask about the scratch on the desk.", .changedName),
            ("Please do not scratch the desk.", "Please scratch the desk.", .changedNegation)
        ]
        for (source, edited, expected) in rejected {
            let result = verdict(source, edited)
            expect(result == expected, "Expected \(expected), got \(result): \(edited.debugDescription)")
        }

        let transcript = "For the launch on Monday we need three things. Update the pricing page. Email the beta "
            + "list. Separately I talked to Ana about the onboarding flow. She thinks the second screen is "
            + "confusing. Can we test a shorter version with five users? Thanks, talk soon."
        let words = transcript.split(whereSeparator: \.isWhitespace)
        func index(of word: String) -> Int { words.firstIndex { $0.hasPrefix(word) }! }
        let recognition = DictationRecognition(text: transcript, pauses: [
            DictationPause(word: index(of: "Update"), milliseconds: 900),
            DictationPause(word: index(of: "Separately"), milliseconds: 1_800),
            DictationPause(word: index(of: "Thanks"), milliseconds: 2_100)
        ])
        let cleaned = "For the launch on Monday, we need three things. Update the pricing page. Email the beta "
            + "list. Separately, I talked to Ana about the onboarding flow. She thinks the second screen is "
            + "confusing. Can we test a shorter version with five users? Thanks, talk soon."
        let arranged = DictationLayout.arrange(
            cleaned, source: recognition, paragraphs: .automatic, keepsBreaks: false)
        let expected = "For the launch on Monday, we need three things. Update the pricing page. Email the beta "
            + "list.\n\nSeparately, I talked to Ana about the onboarding flow. She thinks the second screen is "
            + "confusing. Can we test a shorter version with five users?\n\nThanks, talk soon."
        expect(arranged == expected, "Pauses should place breaks, got \(arranged.debugDescription)")

        let engineBreaks = "For the launch on Monday, we need three things.\n\nUpdate the pricing page. Email "
            + "the beta list. Separately, I talked to Ana about the onboarding flow. She thinks the second "
            + "screen is confusing.\n\nCan we test a shorter version with five users? Thanks, talk soon."
        let reflowed = DictationLayout.arrange(
            engineBreaks, source: recognition, paragraphs: .automatic, keepsBreaks: false)
        expect(reflowed == expected, "Engine breaks without pauses should not survive, got \(reflowed.debugDescription)")

        let unpaused = DictationLayout.arrange(
            engineBreaks, source: nil, paragraphs: .automatic, keepsBreaks: false)
        let suggestedOnly = "For the launch on Monday, we need three things. Update the pricing page. Email "
            + "the beta list. Separately, I talked to Ana about the onboarding flow. She thinks the second "
            + "screen is confusing.\n\nCan we test a shorter version with five users? Thanks, talk soon."
        expect(unpaused == suggestedOnly, "Engine breaks need two sentences, got \(unpaused.debugDescription)")

        let never = DictationLayout.arrange(expected, source: recognition, paragraphs: .never, keepsBreaks: true)
        expect(!never.contains("\n"), "Never should join prose, got \(never.debugDescription)")
        let list = "Next steps:\n1. Call Ana.\n2. Send the invoice.\n\nThat is all. Thanks."
        expect(DictationLayout.arrange(list, source: nil, paragraphs: .never, keepsBreaks: false) == list,
               "Lists keep their lines")

        let commanded = DictationRecognition(
            text: "Send the agenda to the team. New paragraph. Book the room for Friday.")
        let spokenBreak = DictationLayout.arrange(
            "Send the agenda to the team. Book the room for Friday.", source: commanded, paragraphs: .spoken,
            keepsBreaks: false)
        expect(spokenBreak == "Send the agenda to the team.\n\nBook the room for Friday.",
               "Spoken commands break paragraphs, got \(spokenBreak.debugDescription)")
        let noCommand = DictationLayout.arrange(
            expected, source: recognition, paragraphs: .spoken, keepsBreaks: false)
        expect(!noCommand.contains("\n"), "Spoken only ignores pauses, got \(noCommand.debugDescription)")

        func finish(_ text: String, _ kind: DictationAppKind, _ format: DictationFormat) -> String {
            DictationLayout.finishing(text, kind: kind, format: format)
        }
        expect(finish("Running five minutes late.", .personal, .compact) == "Running five minutes late",
               "Personal chat drops a lone final period")
        expect(finish("Late. Sorry.", .personal, .compact) == "Late. Sorry.", "Personal chat keeps two sentences")
        expect(finish("Hi Ana, the invoice is ready.", .email, .full) == "Hi Ana,\n\nthe invoice is ready.",
               "Email splits the greeting")
        expect(finish(expected, .document, .full) == expected, "Documents are unchanged")
        let update = "Quick update.\n\nBefore then:\n• Fix the login bug\n• Update the docs\n\nThanks."
        expect(finish(update, .work, .full) == update, "Work chat keeps bullets and paragraphs")
        let prompt = finish(update, .prompt, .full)
        expect(prompt == "Quick update.\n\nBefore then:\n- Fix the login bug\n- Update the docs\n\nThanks.",
               "AI prompts get Markdown bullets, got \(prompt.debugDescription)")
        let compact = finish(update, .personal, .compact)
        expect(compact == "Quick update.\nBefore then:\nFix the login bug\nUpdate the docs\nThanks.",
               "Compact keeps items on their own lines, got \(compact.debugDescription)")
        expect(finish("1. Show the model\n2. Hide removed ones", .prompt, .full)
               == "1. Show the model\n2. Hide removed ones", "Numbered lists stay numbered")
        expect(finish(update, .code, .plain) == update, "Plain passes text through")

        expect(DictationAppKind(bundleIdentifier: "com.apple.MobileSMS") == .personal, "Messages is personal chat")
        expect(DictationAppKind(bundleIdentifier: "com.tinyspeck.slackmacgap") == .work, "Slack is work chat")
        expect(DictationAppKind(bundleIdentifier: "com.microsoft.teams2") == .work, "Teams is work chat")
        expect(DictationAppKind(bundleIdentifier: "com.apple.mail") == .email, "Mail is email")
        expect(DictationAppKind(bundleIdentifier: "com.anthropic.claudefordesktop") == .prompt, "Claude is a prompt")
        expect(DictationAppKind(bundleIdentifier: "com.jetbrains.intellij") == .code, "JetBrains is code")
        expect(DictationAppKind(bundleIdentifier: "com.apple.Terminal") == .code, "Terminal is code")
        expect(DictationAppKind(bundleIdentifier: "com.apple.Notes") == .document, "Notes is a document")
        expect(DictationAppKind(bundleIdentifier: nil) == .document, "Unknown apps are documents")
        expect(DictationAppKind(webHost: "chatgpt.com") == .prompt, "ChatGPT on the web is a prompt")
        expect(DictationAppKind(webHost: "acme.slack.com") == nil, "Workspace subdomains alone say nothing")
        expect(DictationAppKind(webHost: "app.slack.com") == .work, "Slack on the web is work chat")
        expect(DictationAppKind(webHost: "mail.google.com") == .email, "Gmail is email")
        expect(DictationAppKind(webHost: "notclaude.ai") == nil, "Look-alike hosts don't match")
        expect(DictationAppKind(webHost: "example.com") == nil, "Other sites keep the browser's kind")
        expect(DictationAppKind(terminalTitle: "mallen — claude — 80×24") == .prompt, "Claude Code in Terminal")
        expect(DictationAppKind(terminalTitle: "✳ Codex") == .prompt, "Codex in a terminal")
        expect(DictationAppKind(terminalTitle: "zsh — 80×24") == nil, "A plain shell stays code")
        expect(DictationAppKind(terminalTitle: "claudette-notes.txt") == nil, "Partial words don't match")

        let addresses: [(String, String)] = [
            ("Write to ana dot ruiz at acme dot com today.", "Write to ana.ruiz@acme.com today."),
            ("Meet me at acme dot com.", "Meet me at acme.com."),
            ("The docs are at tinycast dot app slash docs.", "The docs are at tinycast.app/docs."),
            ("Open https colon slash slash www dot example dot co dot uk.", "Open https://www.example.co.uk."),
            ("It was a dot of paint at home.", "It was a dot of paint at home.")
        ]
        for (spoken, written) in addresses {
            let result = DictationTextFormatter.formatSpokenAddresses(spoken)
            expect(result == written, "Address \(spoken.debugDescription) became \(result.debugDescription)")
        }
        let phones: [(String, String)] = [
            ("Call five five five, one two three, four five six seven.", "Call 555-123-4567."),
            ("Call five five five one two three four five six seven.", "Call 555-123-4567."),
            ("Dial plus four four, two oh, seven nine four six, oh nine five eight.", "Dial +44 20 7946 0958."),
            ("Count one, two, three, four, five, six, seven.", "Count one, two, three, four, five, six, seven."),
            ("Pick one two three.", "Pick one two three.")
        ]
        for (spoken, written) in phones {
            let result = DictationTextFormatter.formatSpokenPhoneNumbers(spoken)
            expect(result == written, "Phone \(spoken.debugDescription) became \(result.debugDescription)")
        }
        let literalLine = DictationTextFormatter.basicCleanup(
            "Um, send forty five dollars to ana@acme.com by Friday.", normalize: { $0 }, now: { .now })
        expect(literalLine == "Send $45 to ana@acme.com by Friday.",
               "Cleanup still runs beside an email, got \(literalLine.debugDescription)")
        let advancedLiteral = DictationTextFormatter.advancedCleanup(
            "Um, the files are in docs/guides and on example.com.", now: { .now })
        expect(advancedLiteral == "The files are in docs/guides and on example.com.",
               "Advanced keeps paths and sites, got \(advancedLiteral.debugDescription)")
        expect(verdict("Call me at five five five, one two three, four five six seven.",
                       "Call me at 555-123-4567.") == .accepted, "Smart may write a phone number as digits")
        expect(verdict("Call me at five five five, one two three, four five six seven.",
                       "Call me at 555-123-4568.") == .changedNumber, "Smart may not change a phone digit")
        expect(verdict("Call five five five one two three four.", "Call 555-1234.") == .accepted,
               "Seven spoken digits")
        expect(verdict("Write to ana dot ruiz at acme dot com.", "Write to ana.ruiz@acme.com.") == .accepted,
               "Smart may write an email address")

        var formats = DictationAppFormats()
        expect(formats[.personal] == .compact && formats[.code] == .plain && formats[.work] == .full,
               "Suggested formats")
        formats[.work] = .compact
        formats[.code] = .plain
        expect(formats.storage == ["work": "compact"], "Only changed formats are stored")
        expect(DictationAppFormats(storage: ["work": "compact", "bogus": "full", "email": "nope"]) == formats,
               "Unknown kinds and formats are ignored")

        for sample in corpus {
            let result = DictationLayout.arrange(
                sample.text, source: sample.recognition, paragraphs: .automatic, keepsBreaks: false)
            let breaks = result.components(separatedBy: "\n\n").count - 1
            expect(breaks == sample.breaks, "[\(sample.name)] expected \(sample.breaks) breaks, got \(breaks): "
                + result.debugDescription)
        }

        guard failures == 0 else {
            print("\(failures) layout checks failed")
            exit(1)
        }
        print("Passed edit checks, layout, styles and \(corpus.count) corpus samples.")
    }

    struct Sample {
        let name: String
        let text: String
        let recognition: DictationRecognition?
        let breaks: Int
    }

    static func timed(_ text: String, pausesBefore: [String: Int]) -> DictationRecognition {
        let words = text.split(whereSeparator: \.isWhitespace)
        return DictationRecognition(text: text, pauses: pausesBefore.map { word, milliseconds in
            DictationPause(word: words.firstIndex { $0.hasPrefix(word) }!, milliseconds: milliseconds)
        })
    }

    static let corpus: [Sample] = {
        let status = "The build passed on the second try. I updated the release notes and tagged the version. "
            + "On another note, the office will be closed on Friday. Please plan around it."
        let short = "Can you send me the deck? I want to review it before lunch."
        let rambling = (1...8).map { "Sentence number \($0) adds a little more detail about the plan we discussed." }
            .joined(separator: " ")
        let story = "I tried the new onboarding flow this morning. The first screen is clear and quick. "
            + "The second screen asks for too much at once. I'd split it into two steps. "
            + "What do you think about testing that next week? We could recruit five people."
        return [
            Sample(name: "Explicit topic change", text: status, recognition: nil, breaks: 1),
            Sample(name: "Short message", text: short,
                   recognition: timed(short, pausesBefore: ["I": 1_600]), breaks: 0),
            Sample(name: "Short without pauses", text: short, recognition: nil, breaks: 0),
            Sample(name: "Even sentences without pauses", text: rambling, recognition: nil, breaks: 0),
            Sample(name: "Even sentences with one long pause", text: rambling,
                   recognition: timed(rambling, pausesBefore: ["Sentence": 300]), breaks: 0),
            Sample(name: "Story with pauses", text: story,
                   recognition: timed(story, pausesBefore: ["The": 400, "What": 1_700, "I'd": 600]), breaks: 1),
            Sample(name: "Story without pauses", text: story, recognition: nil, breaks: 0)
        ]
    }()
}
