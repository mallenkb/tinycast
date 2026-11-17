import SwiftUI

/// The apps the Text cleanup preview can paste into, one per app kind.
enum DictationPreviewApp: String, CaseIterable, Identifiable {
    case slack, messages, mail, claude, xcode, notes

    var id: Self { self }

    var kind: DictationAppKind {
        switch self {
        case .slack: .work
        case .messages: .personal
        case .mail: .email
        case .claude: .prompt
        case .xcode: .code
        case .notes: .document
        }
    }

    var name: String {
        switch self {
        case .slack: "Slack"
        case .messages: "Messages"
        case .mail: "Mail"
        case .claude: "Claude"
        case .xcode: "Xcode"
        case .notes: "Notes"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .slack: "com.tinyspeck.slackmacgap"
        case .messages: "com.apple.MobileSMS"
        case .mail: "com.apple.mail"
        case .claude: "com.anthropic.claudefordesktop"
        case .xcode: "com.apple.dt.Xcode"
        case .notes: "com.apple.Notes"
        }
    }

    var fallbackSymbol: String {
        switch self {
        case .slack: "number"
        case .messages: "message.fill"
        case .mail: "envelope.fill"
        case .claude: "sparkles"
        case .xcode: "hammer.fill"
        case .notes: "note.text"
        }
    }
}

struct DictationPreviewAppIcon: View {
    let app: DictationPreviewApp
    @State private var image: NSImage?

    private var path: String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier)?.path
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable()
            } else {
                Image(systemName: app.fallbackSymbol)
                    .resizable().scaledToFit().padding(Theme.Spacing.xxs)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: Theme.Size.settingsRowIcon, height: Theme.Size.settingsRowIcon)
        .accessibilityHidden(true)
        .task(id: IconRequest(path ?? app.bundleIdentifier)) {
            guard let path else { return }
            image = await IconCache.loadAsync(forFile: path)
        }
    }
}

struct DictationCleanupLevelPicker: View {
    @Binding var mode: DictationCleanupMode

    private static let levels: [DictationCleanupMode] = [.off, .basic, .advanced, .smart]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.xxs) {
                ForEach(Self.levels, id: \.self) { level in
                    option(level)
                }
            }
            .padding(Theme.Spacing.xxs)
            .frame(maxWidth: .infinity)
            .background(Theme.Colors.cardFill, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.Colors.cardStroke))
            Text(Self.summary(mode)).foregroundStyle(.secondary)
        }
    }

    private func option(_ level: DictationCleanupMode) -> some View {
        let selected = mode == level
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.menu)
        return Button {
            mode = level
        } label: {
            VStack(spacing: Theme.Spacing.xxs) {
                Text(Self.title(level)).fontWeight(.semibold)
                Text(Self.subtitle(level)).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, Theme.Spacing.sm)
            .frame(maxWidth: .infinity)
            .background(selected ? Theme.Colors.controlSurface : Color.clear, in: shape)
            .overlay(shape.strokeBorder(selected ? Theme.Colors.cardStroke : Color.clear))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    static func title(_ level: DictationCleanupMode) -> LocalizedStringKey {
        switch level {
        case .off: "Off"
        case .basic: "Basic"
        case .advanced: "Advanced"
        case .smart: "Smart"
        }
    }

    private static func subtitle(_ level: DictationCleanupMode) -> LocalizedStringKey {
        switch level {
        case .off: "As spoken"
        case .basic: "Tidy"
        case .advanced: "Clean"
        case .smart: "Polished"
        }
    }

    private static func summary(_ level: DictationCleanupMode) -> LocalizedStringKey {
        switch level {
        case .off: "Exactly what you said."
        case .basic: "Removes fillers and formats numbers."
        case .advanced: "Also applies corrections, lists and paragraphs."
        case .smart: "Rewrites for clarity. Never changes names or numbers."
        }
    }
}

/// What you said beside what gets pasted into the chosen app, using the live cleanup settings.
struct DictationCleanupStage: View {
    @Binding var app: DictationPreviewApp
    @Environment(AppSettings.self) private var settings
    @Environment(DictationWritingCoordinator.self) private var writing
    @State private var example = Example.update
    @State private var custom = ""
    @State private var showsEdits = true
    @State private var preview: (input: Input, result: Result<DictationWritingCoordinator.Preview, Error>)?

    enum Example: CaseIterable {
        case update, requirements, contact, booking, custom

        var title: LocalizedStringKey {
            switch self {
            case .update: "Team update"
            case .requirements: "Requirements"
            case .contact: "Contact details"
            case .booking: "Correction"
            case .custom: "Your own…"
            }
        }

        var transcript: String {
            switch self {
            case .update:
                "Um, hey team, quick update. The launch moved to Friday, no, Monday the fourteenth. So a few "
                    + "things before then, we need to fix the login bug, update the docs, and get sign off from "
                    + "legal. Moving on to the budget, we spent about forty five hundred dollars. Let me know if "
                    + "that works."
            case .requirements:
                "Okay so build a settings page for dictation. The requirements are: show the current model at "
                    + "the top, let me pick by language, accuracy or size, and keep removed models out of the list."
            case .contact:
                "Um, you can reach Ana at ana dot ruiz at acme dot com, or call five five five, one two three, "
                    + "four five six seven. The docs are at tinycast dot app slash docs."
            case .booking:
                String(localized: "For Friday, no sorry, Monday, book the room, invite the team, and send the agenda.")
            case .custom: ""
            }
        }
    }

    private struct Input: Equatable {
        let transcript: String
        let mode: DictationCleanupMode
        let engine: String?
        let kind: DictationAppKind
        let format: DictationFormat
        let paragraphs: DictationParagraphs
        let ready: Bool
    }

    private var transcript: String { example == .custom ? custom : example.transcript }

    var body: some View {
        let format = settings.dictationFormatsByApp ? settings.dictationAppFormats[app.kind] : .full
        let smart = settings.dictationCleanupMode == .smart
        let input = Input(
            transcript: transcript, mode: settings.dictationCleanupMode,
            engine: smart ? settings.dictationCleanupEngine : nil, kind: app.kind, format: format,
            paragraphs: settings.dictationParagraphs,
            ready: !smart || writing.selectedLocalModel.map { writing.cleanup.isInstalled($0) } ?? true)
        let result = preview?.input == input ? preview?.result : nil
        let output = (try? result?.get())?.text
        let edits = output.map { DictationEditHighlights($0, said: transcript) }
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                ForEach(DictationPreviewApp.allCases) { candidate in
                    appTab(candidate)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.trailing, Theme.Spacing.xl)

            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                HStack(spacing: Theme.Spacing.md) {
                    label("Pasted into \(app.name)")
                    Spacer(minLength: 0)
                    Picker("Example", selection: $example) {
                        ForEach(Example.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                pastedWindow(result: result, edits: edits)
                if case .success(let value) = result, value.checked {
                    let kept = DictationEditHighlights.kept(in: value.text)
                    if !kept.isEmpty {
                        Text("Smart's check passed. It kept \(kept.formatted(.list(type: .and))).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    label("You said")
                    if example == .custom {
                        TextField("Type or paste what you'd say", text: $custom, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...4)
                    }
                    if example != .custom || showsEdits && edits != nil {
                        Text(edits.map { showsEdits ? $0.said : AttributedString(transcript) } ?? AttributedString(transcript))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Toggle("Show edits", isOn: $showsEdits)
                        .toggleStyle(.checkbox)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, Theme.Spacing.xl)
            .overlay(alignment: .leading) {
                Rectangle().fill(Theme.Colors.cardStroke).frame(width: 1)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, Theme.Spacing.sm)
        .task(id: input) { await update(input) }
    }

    private func label(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.tertiary).textCase(.uppercase)
    }

    private func appTab(_ candidate: DictationPreviewApp) -> some View {
        let selected = candidate == app
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.menu)
        return Button {
            app = candidate
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                DictationPreviewAppIcon(app: candidate)
                Text(verbatim: candidate.name)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.Colors.controlSurface : Color.clear, in: shape)
            .foregroundStyle(selected ? .primary : .secondary)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private func pastedWindow(
        result: Result<DictationWritingCoordinator.Preview, Error>?, edits: DictationEditHighlights?
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Spacing.xs) {
                DictationPreviewAppIcon(app: app)
                Text(verbatim: app.name)
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Spacing.md).padding(.vertical, Theme.Spacing.sm)
            Divider()
            Group {
                switch result {
                case .success(let value):
                    let text = edits.map { showsEdits ? $0.pasted : AttributedString(value.text) }
                        ?? AttributedString(value.text)
                    pastedText(text)
                case .failure(let error):
                    Text(error.localizedDescription).foregroundStyle(.red)
                case nil:
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(Theme.Spacing.md)
        }
        .background(Theme.Colors.cardFill, in: shape)
        .overlay(shape.strokeBorder(Theme.Colors.cardStroke))
    }

    @ViewBuilder private func pastedText(_ text: AttributedString) -> some View {
        switch app.kind {
        case .personal:
            Text(text)
                .foregroundStyle(.white)
                .padding(.horizontal, Theme.Spacing.md).padding(.vertical, Theme.Spacing.sm)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .textSelection(.enabled)
        case .code, .prompt:
            Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
        case .work, .email, .document:
            Text(text).textSelection(.enabled)
        }
    }

    private func update(_ input: Input) async {
        guard !input.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            preview = (input, .success(.init(text: "")))
            return
        }
        do {
            if input.engine != nil { try await Task.sleep(for: .milliseconds(350)) }
            try Task.checkCancellation()
            let output = try await writing.preview(
                input.transcript, transform: nil, kind: input.kind, format: input.format)
            try Task.checkCancellation()
            preview = (input, .success(output))
        } catch {
            guard !Task.isCancelled else { return }
            preview = (input, .failure(error))
        }
    }
}

/// Marks the words cleanup dropped from what you said and the words it added to what gets pasted.
struct DictationEditHighlights {
    let said: AttributedString
    let pasted: AttributedString

    init(_ pasted: String, said: String) {
        let saidWords = said.matches(of: /\S+/).map(\.range)
        let pastedWords = pasted.matches(of: /\S+/).map(\.range)
        let saidKeys = saidWords.map { Self.key(said[$0]) }
        let pastedKeys = pastedWords.map { Self.key(pasted[$0]) }
        let (keptSaid, keptPasted) = Self.common(saidKeys, pastedKeys)
        self.said = Self.marked(said, words: saidWords, kept: keptSaid) { run in
            run.strikethroughStyle = .single
            run.foregroundColor = Theme.Colors.dictationEditRemoved
        }
        self.pasted = Self.marked(pasted, words: pastedWords, kept: keptPasted) { run in
            run.backgroundColor = Theme.Colors.dictationEditAdded
        }
    }

    /// Names and values worth confirming: anything with a digit or @, or a capitalized word mid-sentence.
    static func kept(in text: String) -> [String] {
        var found: [String] = []
        var sentenceStart = true
        for match in text.matches(of: /\S+/) {
            let word = String(match.output).trimmingCharacters(in: .punctuationCharacters.subtracting(["$", "@"]))
            let notable = word.contains(where: \.isNumber) || word.contains("@")
                || (!sentenceStart && word.first?.isUppercase == true && word != "I")
            if notable, !word.isEmpty, !found.contains(word) { found.append(word) }
            sentenceStart = match.output.last.map { ".!?:\n".contains($0) } ?? false
            if found.count == 4 { break }
        }
        return found
    }

    private static func key(_ word: Substring) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber || "$@/".contains($0) }
    }

    private static func common(_ lhs: [String], _ rhs: [String]) -> (Set<Int>, Set<Int>) {
        guard !lhs.isEmpty, !rhs.isEmpty, lhs.count * rhs.count <= 250_000 else { return ([], []) }
        let columns = rhs.count + 1
        var lengths = [Int32](repeating: 0, count: (lhs.count + 1) * columns)
        for i in stride(from: lhs.count - 1, through: 0, by: -1) {
            for j in stride(from: rhs.count - 1, through: 0, by: -1) {
                lengths[i * columns + j] = lhs[i] == rhs[j] && !lhs[i].isEmpty
                    ? lengths[(i + 1) * columns + j + 1] + 1
                    : max(lengths[(i + 1) * columns + j], lengths[i * columns + j + 1])
            }
        }
        var left: Set<Int> = []
        var right: Set<Int> = []
        var i = 0
        var j = 0
        while i < lhs.count, j < rhs.count {
            if lhs[i] == rhs[j] && !lhs[i].isEmpty {
                left.insert(i)
                right.insert(j)
                i += 1
                j += 1
            } else if lengths[(i + 1) * columns + j] >= lengths[i * columns + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return (left, right)
    }

    private static func marked(
        _ text: String, words: [Range<String.Index>], kept: Set<Int>, style: (inout AttributeContainer) -> Void
    ) -> AttributedString {
        var result = AttributedString(text)
        var container = AttributeContainer()
        style(&container)
        for (index, range) in words.enumerated() where !kept.contains(index) {
            guard let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result)
            else { continue }
            result[lower..<upper].mergeAttributes(container)
        }
        return result
    }
}

extension DictationAppKind {
    var settingsTitle: String {
        switch self {
        case .personal: String(localized: "Personal chat")
        case .work: String(localized: "Work chat")
        case .email: String(localized: "Email")
        case .prompt: String(localized: "AI prompt")
        case .code: String(localized: "Code editor")
        case .document: String(localized: "Everything else")
        }
    }

    var settingsFormatHeader: String {
        switch self {
        case .personal: String(localized: "Format for texts")
        case .work: String(localized: "Format for work chats")
        case .email: String(localized: "Format for email")
        case .prompt: String(localized: "Format for AI tools")
        case .code: String(localized: "Format for code editors")
        case .document: String(localized: "Format for other apps")
        }
    }

    var settingsApps: String {
        switch self {
        case .personal: String(localized: "Messages, WhatsApp, Signal and Telegram")
        case .work: String(localized: "Slack, Teams and Discord")
        case .email: String(localized: "Mail, Outlook, Spark and Superhuman")
        case .prompt: String(localized: "Claude, ChatGPT, Codex, Cursor and Windsurf")
        case .code: String(localized: "Xcode, VS Code, Zed and terminals")
        case .document: String(localized: "Notes, Pages, browsers and other apps")
        }
    }

    func settingsEffect(of format: DictationFormat) -> String {
        switch (format, self) {
        case (.full, .email): String(localized: "Greeting on its own line, then paragraphs and lists.")
        case (.full, .prompt): String(localized: "Markdown lists, numbered when order matters.")
        case (.full, _): String(localized: "Paragraphs and lists.")
        case (.compact, _): String(localized: "One block, with list items on their own lines.")
        case (.plain, _): String(localized: "Basic cleanup only.")
        }
    }
}

extension DictationFormat {
    var settingsTitle: String {
        switch self {
        case .full: String(localized: "Full")
        case .compact: String(localized: "Compact")
        case .plain: String(localized: "Plain")
        }
    }
}
