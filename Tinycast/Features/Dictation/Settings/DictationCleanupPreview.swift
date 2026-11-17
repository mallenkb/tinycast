import SwiftUI

/// The apps the Text cleanup preview can paste into, one per app kind.
enum DictationPreviewApp: String, CaseIterable, Identifiable {
    case slack, messages, mail, claude, xcode, notes

    var id: Self { self }

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

struct DictationCleanupStage: View {
    @State private var app = DictationPreviewApp.slack
    @Environment(AppSettings.self) private var settings
    @Environment(DictationWritingCoordinator.self) private var writing
    @State private var example = Example.update
    @State private var custom = ""
    @State private var showsEdits = true
    @State private var preview: (input: Input, result: Result<String, Error>)?

    enum Example: CaseIterable {
        case update, requirements, contact, booking, currency, date, time, paragraphs, custom

        var title: LocalizedStringKey {
            switch self {
            case .update: "Team update"
            case .requirements: "Requirements"
            case .contact: "Contact details"
            case .booking: "Correction"
            case .currency: "Currency"
            case .date: "Date"
            case .time: "Time"
            case .paragraphs: "Paragraphs"
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
            case .currency:
                "The total is forty-five dollars and ninety-nine cents."
            case .date:
                "Set the deadline for the twenty-fourth of June, twenty twenty-seven."
            case .time:
                "Let's meet at nine thirty in the morning."
            case .paragraphs:
                "The room is booked. New paragraph. Please send the agenda before we meet."
            case .custom: ""
            }
        }
    }

    private struct Input: Equatable {
        let transcript: String
        let mode: DictationCleanupMode
        let engine: String?
        let removingFillers: Bool
        let ready: Bool
    }

    private var transcript: String { example == .custom ? custom : example.transcript }

    var body: some View {
        let smart = settings.dictationCleanupMode == .smart
        let model = smart ? writing.selectedLocalModel : nil
        let input = Input(
            transcript: transcript, mode: settings.dictationCleanupMode,
            engine: smart ? settings.dictationCleanupEngine : nil,
            removingFillers: settings.dictationRemovesFillerWords,
            ready: model.map { writing.cleanup.downloading != $0 } ?? true)
        let result = preview?.input == input ? preview?.result : nil
        let output = try? result?.get()
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
                    Picker("Examples", selection: $example) {
                        ForEach(Example.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                pastedWindow(result: result, edits: edits)
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
        result: Result<String, Error>?, edits: DictationEditHighlights?
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
                    let text = edits.map { showsEdits ? $0.pasted : AttributedString(value) }
                        ?? AttributedString(value)
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
        switch app {
        case .messages:
            Text(text)
                .foregroundStyle(.white)
                .padding(.horizontal, Theme.Spacing.md).padding(.vertical, Theme.Spacing.sm)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .textSelection(.enabled)
        case .xcode, .claude:
            Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
        case .slack, .mail, .notes:
            Text(text).textSelection(.enabled)
        }
    }

    private func update(_ input: Input) async {
        guard input.ready else { return }
        guard !input.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            preview = (input, .success(""))
            return
        }
        do {
            if input.engine != nil { try await Task.sleep(for: .milliseconds(350)) }
            try Task.checkCancellation()
            let output = try await writing.preview(input.transcript, transform: nil)
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
