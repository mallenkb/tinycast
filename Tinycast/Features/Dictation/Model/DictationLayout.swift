import Foundation

enum DictationParagraphs: String, CaseIterable, Sendable {
    case automatic, spoken, never
}

/// The kind of app dictation lands in, which picks the format the text arrives in.
enum DictationAppKind: String, CaseIterable, Sendable {
    case personal, work, email, prompt, code, document

    init(bundleIdentifier: String?) {
        guard let bundleIdentifier else { self = .document; return }
        if Self.personalApps.contains(bundleIdentifier) {
            self = .personal
        } else if Self.workApps.contains(bundleIdentifier) {
            self = .work
        } else if Self.emailApps.contains(bundleIdentifier) {
            self = .email
        } else if Self.promptApps.contains(bundleIdentifier) {
            self = .prompt
        } else if Self.codeApps.contains(bundleIdentifier) || Self.terminals.contains(bundleIdentifier)
            || bundleIdentifier.hasPrefix("com.jetbrains.") {
            self = .code
        } else {
            self = .document
        }
    }

    /// A web app open in a browser tab, or `nil` when the address says nothing about it.
    init?(webHost host: String) {
        let host = host.lowercased()
        func matches(_ domains: Set<String>) -> Bool {
            domains.contains { host == $0 || host.hasSuffix("." + $0) }
        }
        if matches(Self.promptSites) {
            self = .prompt
        } else if matches(Self.workSites) {
            self = .work
        } else if matches(Self.emailSites) {
            self = .email
        } else if matches(Self.personalSites) {
            self = .personal
        } else {
            return nil
        }
    }

    /// A coding agent named in a terminal window's title, such as "claude" or "codex".
    init?(terminalTitle title: String) {
        let words = title.lowercased().split { !$0.isLetter }
        guard words.contains(where: { Self.terminalAgents.contains(String($0)) }) else { return nil }
        self = .prompt
    }

    static let personalApps: Set<String> = [
        "com.apple.MobileSMS", "net.whatsapp.WhatsApp", "desktop.WhatsApp", "ru.keepcoder.Telegram",
        "org.telegram.desktop", "com.tdesktop.Telegram", "org.whispersystems.signal-desktop",
        "com.facebook.archon.developerID"
    ]

    static let workApps: Set<String> = [
        "com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.microsoft.teams", "com.hnc.Discord",
        "Mattermost.Desktop", "com.webex.meetingmanager", "us.zoom.xos"
    ]

    static let emailApps: Set<String> = [
        "com.apple.mail", "com.microsoft.Outlook", "com.readdle.smartemail-Mac", "com.readdle.SparkDesktop",
        "com.superhuman.electron", "com.mimestream.Mimestream", "it.bloop.airmail2", "com.freron.MailMate"
    ]

    static let promptApps: Set<String> = [
        "com.anthropic.claudefordesktop", "com.openai.chat", "com.openai.codex", "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf", "ai.perplexity.mac"
    ]

    static let codeApps: Set<String> = [
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "dev.zed.Zed", "com.sublimetext.4", "com.panic.Nova",
        "com.google.android.studio"
    ]

    static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm"
    ]

    static let browsers: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "company.thebrowser.dia",
        "com.brave.Browser", "com.microsoft.edgemac", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
        "org.mozilla.firefox", "app.zen-browser.zen"
    ]

    static let promptSites: Set<String> = [
        "chatgpt.com", "chat.openai.com", "claude.ai", "gemini.google.com", "perplexity.ai", "copilot.microsoft.com",
        "chat.deepseek.com", "grok.com", "chat.mistral.ai", "v0.dev", "lovable.dev", "bolt.new"
    ]

    static let workSites: Set<String> = [
        "app.slack.com", "teams.microsoft.com", "teams.live.com", "chat.google.com", "discord.com"
    ]

    static let emailSites: Set<String> = [
        "mail.google.com", "outlook.live.com", "outlook.office.com", "outlook.office365.com", "mail.proton.me",
        "app.fastmail.com", "mail.yahoo.com", "www.icloud.com"
    ]

    static let personalSites: Set<String> = ["web.whatsapp.com", "web.telegram.org", "messenger.com"]

    static let terminalAgents: Set<String> = ["claude", "codex", "gemini", "aider", "opencode"]
}

/// How much shape the text gets in one kind of app.
enum DictationFormat: String, CaseIterable, Sendable {
    /// Paragraphs and lists.
    case full
    /// One block, with list items on their own lines.
    case compact
    /// Basic cleanup only.
    case plain
}

/// The format each app kind uses; only choices that differ from the suggestion are stored.
struct DictationAppFormats: Equatable, Sendable {
    private(set) var overrides: [DictationAppKind: DictationFormat] = [:]

    init(overrides: [DictationAppKind: DictationFormat] = [:]) {
        for (kind, format) in overrides { self[kind] = format }
    }

    init(storage: [String: String]) {
        self.init(overrides: Dictionary(uniqueKeysWithValues: storage.compactMap { key, value in
            DictationAppKind(rawValue: key).flatMap { kind in DictationFormat(rawValue: value).map { (kind, $0) } }
        }))
    }

    static func suggested(for kind: DictationAppKind) -> DictationFormat {
        switch kind {
        case .personal: .compact
        case .work, .email, .prompt, .document: .full
        case .code: .plain
        }
    }

    subscript(kind: DictationAppKind) -> DictationFormat {
        get { overrides[kind] ?? Self.suggested(for: kind) }
        set { overrides[kind] = newValue == Self.suggested(for: kind) ? nil : newValue }
    }

    var storage: [String: String] {
        Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value.rawValue) })
    }
}

/// The one place that decides where paragraphs break, whichever cleanup produced the words.
enum DictationLayout {
    static let paragraphPause = 1_500

    /// `keepsBreaks` trusts breaks already in `text`; otherwise prose breaks only count as suggestions.
    static func arrange(
        _ text: String, source: DictationRecognition?, paragraphs: DictationParagraphs, keepsBreaks: Bool
    ) -> String {
        let pauses = PauseMap(source)
        if keepsBreaks {
            guard paragraphs != .spoken else { return text }
            if paragraphs == .never { return joiningProse(text) }
            return text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
                isStructured(line) ? String(line) : arrangeRun(line, suggested: [], pauses: pauses, spokenOnly: false)
            }.joined(separator: "\n")
        }

        var output: [String] = []
        var run = ""
        var suggested: Set<Int> = []
        func flush() {
            guard !run.isEmpty else { return }
            output.append(paragraphs == .never ? run : arrangeRun(
                Substring(run), suggested: suggested, pauses: pauses, spokenOnly: paragraphs == .spoken))
            run = ""
            suggested = []
        }
        for block in blocks(text) {
            if isStructured(block) {
                flush()
                output.append(String(block))
            } else if run.isEmpty {
                run = String(block)
            } else {
                run += " "
                suggested.insert(run.utf8.count)
                run += block
            }
        }
        flush()
        return output.joined(separator: "\n\n")
    }

    /// Writes lists and app conventions after `arrange`; `.plain` text passes through untouched.
    static func finishing(_ text: String, kind: DictationAppKind, format: DictationFormat) -> String {
        guard format != .plain else { return text }
        var text = text
        if format == .compact {
            text = text.replacing(/\n[\x20\t]*\n\s*/, with: "\n").replacing(/(?m:^•[\x20\t]+)/, with: "")
        } else if kind == .prompt {
            text = text.replacing(/(?m:^•[\x20\t]+)/, with: "- ")
        }
        switch kind {
        case .personal:
            guard !text.contains("\n"), text.hasSuffix("."), !text.hasSuffix(".."),
                  DictationTextFormatter.sentenceBoundaries(in: Substring(text)).isEmpty
            else { return text }
            return String(text.dropLast())
        case .email:
            return DictationTextFormatter.formatCorrespondence(text).replacing(
                #/
                ^((?i:hi|hello|hey|dear|good[\x20\t]+(?:morning|afternoon|evening))
                  [\x20\t]+\p{Lu}[\p{L}'’-]*(?:[\x20\t]+\p{Lu}[\p{L}'’-]*)?,)[\x20\t]+(?=\p{L})
                /#
            ) { String($0.1) + "\n\n" }
        case .work, .prompt, .code, .document:
            return text
        }
    }

    private static func blocks(_ text: String) -> [Substring] {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: /\n[\x20\t]*\n\s*/)
    }

    /// Lists, line-broken blocks and short lead-in lines such as "Hi Ana," keep their own layout.
    private static func isStructured(_ block: Substring) -> Bool {
        let trimmed = block.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.contains("\n") { return true }
        if trimmed.firstMatch(of: /^(?:\d+[.)]|[•\-*–])[\x20\t]/) != nil { return true }
        return trimmed.split(whereSeparator: \.isWhitespace).count <= 6 && (trimmed.last == "," || trimmed.last == ":")
    }

    private static func joiningProse(_ text: String) -> String {
        var output: [String] = []
        for block in blocks(text) {
            if !isStructured(block), let last = output.last, !isStructured(Substring(last)) {
                output[output.count - 1] = last + " " + block
            } else {
                output.append(String(block))
            }
        }
        return output.joined(separator: "\n\n")
    }

    private static func arrangeRun(
        _ run: Substring, suggested: Set<Int>, pauses: PauseMap, spokenOnly: Bool
    ) -> String {
        let boundaries = DictationTextFormatter.sentenceBoundaries(in: run)
        guard !boundaries.isEmpty else { return String(run) }
        let starts = [run.startIndex] + boundaries.map(\.upperBound)
        let ends = boundaries.map { run.index(after: $0.lowerBound) } + [run.endIndex]
        let words = zip(starts, ends).map { run[$0..<$1].split(whereSeparator: \.isWhitespace).count }
        let timing = pauses.sentenceStarts(in: run, starts: starts)
        var remaining = words.reduce(0, +) - words[0]
        var paragraphWords = words[0]
        var paragraphSentences = 1
        var breaks: [Int] = []
        for index in 1..<starts.count {
            let remainder = run[starts[index]...]
            let pause = timing[index].milliseconds
            let split: Bool
            if timing[index].spokenBreak || spokenOnly {
                split = timing[index].spokenBreak
            } else if DictationTextFormatter.startsTopic(remainder) {
                split = paragraphWords >= 4 && remaining >= 4
            } else if pause >= paragraphPause {
                split = paragraphSentences >= 2 || paragraphWords >= 15
            } else if suggested.contains(run.utf8.distance(from: run.startIndex, to: starts[index])) {
                split = paragraphSentences >= 2 && (!pauses.known || pause >= 400)
            } else if DictationTextFormatter.startsParagraphTransition(remainder) {
                split = paragraphSentences >= 2 && paragraphWords >= 30 && remaining >= 15
                    && (!pauses.known || pause >= 600)
            } else {
                split = paragraphWords >= 90 && remaining >= 35
                    && remainder.first?.isUppercase == true
                    && (!pauses.known || pause >= 500 || paragraphWords >= 130)
            }
            if split {
                breaks.append(index)
                paragraphWords = 0
                paragraphSentences = 0
            }
            paragraphWords += words[index]
            paragraphSentences += 1
            remaining -= words[index]
        }
        var output = ""
        var start = run.startIndex
        for index in breaks {
            var preceding = run[start..<starts[index]]
            while preceding.last?.isWhitespace == true { preceding.removeLast() }
            output += preceding + "\n\n"
            start = starts[index]
        }
        return output + run[start...]
    }

    /// Maps sentence starts in edited text back to the recognizer's words through a word alignment.
    private struct PauseMap {
        let source: [DictationWords.Token]
        let pauses: [Int: Int]
        let commands: [Int]
        var known: Bool { !pauses.isEmpty }

        init(_ recognition: DictationRecognition?) {
            let tokens = recognition.map { DictationWords.tokens($0.text) } ?? []
            source = tokens
            pauses = Dictionary(
                (recognition?.pauses ?? []).map { ($0.word, $0.milliseconds) }, uniquingKeysWith: max)
            commands = tokens.indices.dropLast().filter {
                ["new", "next"].contains(tokens[$0].key) && tokens[$0 + 1].key == "paragraph"
            }
        }

        func sentenceStarts(
            in run: Substring, starts: [String.Index]
        ) -> [(milliseconds: Int, spokenBreak: Bool)] {
            var result = Array(repeating: (milliseconds: 0, spokenBreak: false), count: starts.count)
            guard !source.isEmpty else { return result }
            let text = String(run)
            let edited = DictationWords.tokens(text)
            let ranges = DictationWords.wordRanges(text)
            var matched: [Int: Int] = [:]
            for pair in DictationWords.alignment(source, edited) { matched[pair.edited] = pair.source }
            let offsets = starts.map { run.utf8.distance(from: run.startIndex, to: $0) }
            for (index, offset) in offsets.enumerated() where index > 0 {
                let limit = index + 1 < offsets.count ? offsets[index + 1] : Int.max
                let tokenOffset = { (token: Int) in
                    text.utf8.distance(from: text.startIndex, to: ranges[edited[token].word].lowerBound)
                }
                guard let first = edited.indices.first(where: { tokenOffset($0) >= offset }),
                      let current = edited.indices[first...].first(where: {
                          matched[$0] != nil && tokenOffset($0) < limit
                      }).flatMap({ matched[$0] })
                else { continue }
                let previous = edited.indices[..<first].last(where: { matched[$0] != nil }).flatMap { matched[$0] }
                let lower = previous.map { source[$0].word } ?? -1
                let upper = source[current].word
                result[index].milliseconds = (lower + 1...max(lower + 1, upper)).compactMap { pauses[$0] }.max() ?? 0
                result[index].spokenBreak = commands.contains { $0 > (previous ?? -1) && $0 + 2 <= current }
            }
            return result
        }
    }
}
