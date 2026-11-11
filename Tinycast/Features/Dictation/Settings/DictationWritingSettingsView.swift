import SwiftUI

struct DictationWritingSettingsView: View {
    let page: DictationSettingsPage
    @Environment(DictationWritingCoordinator.self) private var writing
    @Environment(AppSettings.self) private var settings
    @Environment(SettingsNavigationState.self) private var navigation
    private var editing: UUID? {
        if case .dictationTransform(let id) = navigation.detail { return id }
        return nil
    }
    private var editorVisible: Bool { navigation.detail != nil }
    @State private var name = ""
    @State private var instructions = ""
    @State private var sample = DictationCleanupCard.defaultSample
    @State private var result = ""
    @State private var error = ""
    @State private var previewing = false
    @State private var operation: Task<Void, Never>?
    @State private var download: Task<Void, Never>?
    @State private var operationID = UUID()

    var body: some View {
        @Bindable var settings = settings
        Group {
            if page == .cleanup {
                Section {
                    DictationCleanupCard(sample: $sample, mode: $settings.dictationCleanupMode)
                    Picker(selection: $settings.dictationCleanupEngine) {
                        Text("S1-mini (Default)").tag("s1Mini")
                        Text(verbatim: "S1-ASR-Cleanup").tag(DictationCleanupModel.Variant.s1ASRCleanup.rawValue)
                        Text("Apple Intelligence").tag("appleIntelligence")
                    } label: {
                        SettingsRowTitle(.dictationCleanup, "Cleanup engine")
                    }
                    .settingsEnabled(writing.cleanup.downloading == nil)
                    if let model = writing.cleanup.downloading ?? writing.selectedLocalModel {
                        let size = model.downloadBytes.formatted(.byteCount(style: .file))
                        SettingsRow(
                            title: model == .s1Mini
                                ? "S1-mini by Superwhisper" : "S1-ASR-Cleanup (S1-mini by Superwhisper)",
                            subtitle: String(localized: "English only. \(size) download.")
                        ) {
                            if writing.cleanup.downloading == model {
                                Button("Cancel") { download?.cancel() }
                            } else if writing.cleanup.isInstalled(model) {
                                Button(role: .destructive) {
                                    do { try writing.cleanup.remove(model) } catch {
                                        self.error = error.localizedDescription
                                    }
                                } label: {
                                    Text("Remove")
                                }
                                .buttonStyle(.dangerAction)
                                .disabled(writing.cleanup.busy)
                            } else {
                                Button("Download") {
                                    error = ""
                                    download = Task {
                                        do { try await writing.cleanup.download(model) } catch {
                                            if !Task.isCancelled { self.error = error.localizedDescription }
                                        }
                                    }
                                }
                            }
                        }
                        if writing.cleanup.downloading == model {
                            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                                ProgressView(
                                    value: Double(writing.cleanup.downloadedBytes),
                                    total: Double(model.downloadBytes)
                                )
                                .progressViewStyle(.linear)
                                .accessibilityLabel("Model download progress")
                                HStack {
                                    if writing.cleanup.downloadedBytes >= model.downloadBytes {
                                        Text("Finishing download…")
                                    } else {
                                        let received = writing.cleanup.downloadedBytes.formatted(.byteCount(style: .file))
                                        Text("\(received) of \(size)")
                                    }
                                    Spacer()
                                    Text(Double(writing.cleanup.downloadedBytes) / Double(model.downloadBytes),
                                         format: .percent.precision(.fractionLength(0)))
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            }
                        }
                    } else if let reason = writing.unavailableReason {
                        Text(reason).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Smart cleanup and After dictation share this engine.")
                }
                .settingsAnchor(.dictationCleanup)
            }
            if page == .transforms && !editorVisible {
                Section {
                    let hasDefaultTransform = writing.store.savedTransforms.contains {
                        $0.id.uuidString == settings.dictationTransformID
                    }
                    Toggle(isOn: $settings.dictationAutoTransform) {
                        SettingsRowTitle(.dictationTransforms, "After dictation")
                    }
                    .toggleStyle(.switch)
                    .disabled(!hasDefaultTransform && !settings.dictationAutoTransform)
                    Picker("Default transform", selection: $settings.dictationTransformID) {
                        if !hasDefaultTransform {
                            Text("No transform").tag(settings.dictationTransformID)
                        }
                        ForEach(writing.store.savedTransforms) { transform in
                            Text(verbatim: transform.name).tag(transform.id.uuidString)
                        }
                    }
                    .disabled(writing.store.savedTransforms.isEmpty)
                    ForEach(writing.store.savedTransforms) { transform in
                        HStack(spacing: Theme.Spacing.lg) {
                            Button {
                                navigation.openDetail(.dictationTransform(transform.id))
                            } label: {
                                Text(verbatim: transform.name).frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                            Button("Edit") { navigation.openDetail(.dictationTransform(transform.id)) }
                        }
                    }
                    SettingsRow(title: writing.store.paragraphs.name) {
                        ShortcutRecorder(action: .dictationTransform(id: DictationTransform.paragraphsID))
                    }
                    Button {
                        navigation.openDetail(.dictationTransform(nil))
                    } label: {
                        SettingsRowTitle(.dictationTransforms, "Create transform")
                    }
                    if let reason = writing.unavailableReason { Text(reason).foregroundStyle(.secondary) }
                } header: {
                    SettingsSectionHeader(.dictationTransforms)
                } footer: {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text("Transforms use the engine selected in Text cleanup.")
                        Text("Shortcuts transform the latest History entry for review without pasting.")
                    }
                }
            }
            if page == .transforms && editorVisible {
                Section("Edit transform") {
                    TextField("Name", text: $name)
                    if let editing {
                        SettingsRow(title: "Shortcut") {
                            ShortcutRecorder(action: .dictationTransform(id: editing))
                        }
                        Button("Delete", role: .destructive) {
                            if let transform = writing.store.transforms.first(where: { $0.id == editing }) {
                                writing.remove(transform)
                                navigation.dismissDetail()
                            }
                        }
                    }
                    TextField("Instructions", text: $instructions, axis: .vertical).lineLimit(3...8)
                    HStack {
                        Spacer()
                        Button("Cancel") { navigation.dismissDetail() }
                        Button("Save") {
                            let transform = DictationTransform(
                                id: editing ?? UUID(),
                                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines))
                            if writing.save(transform) {
                                navigation.dismissDetail()
                            }
                        }.disabled(
                            name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || name.count > 60 || instructions.count > 2_000)
                    }
                }
            }
            if page == .transforms && editorVisible {
                Section("Preview") {
                    TextField("Sample transcript", text: $sample, axis: .vertical).lineLimit(2...5)
                    HStack {
                        if previewing { ProgressView().controlSize(.small) }
                        Spacer()
                        Button("Preview") { preview() }.disabled(
                            previewing || writing.cleanup.downloading != nil || sample.isEmpty)
                    }
                    if !result.isEmpty { Text(verbatim: result).textSelection(.enabled) }
                    if !error.isEmpty { Text(error).foregroundStyle(.red) }
                }
            }
            if page == .cleanup && !error.isEmpty { Text(error).foregroundStyle(.red) }
        }
        .onDisappear {
            operation?.cancel(); download?.cancel()
        }
        .onChange(of: settings.dictationCleanupEngine) { clearPreview() }
        .onChange(of: settings.dictationSmartCleanup) { clearPreview() }
        .onChange(of: settings.dictationAdvancedCleanup) { clearPreview() }
        .onChange(of: settings.dictationRemovesFillerWords) { clearPreview() }
        .onChange(of: navigation.detail, initial: true) { loadEditor() }
        .onChange(of: sample) { clearPreview() }
        .onChange(of: instructions) { clearPreview() }
        .onChange(of: settings.dictationAutoTransform) { clearPreview() }
        .onChange(of: settings.dictationTransformID) { clearPreview() }
    }

    private func clearPreview() {
        operationID = UUID()
        operation?.cancel()
        previewing = false
        result = ""
        error = ""
    }

    private func loadEditor() {
        guard page == .transforms else { return }
        clearPreview()
        let transform = editing.flatMap { id in writing.store.savedTransforms.first { $0.id == id } }
        guard editing == nil || transform != nil else {
            navigation.dismissDetail()
            return
        }
        name = transform?.name ?? ""
        instructions = transform?.instructions ?? ""
    }

    private func preview() {
        clearPreview()
        let current = operationID
        previewing = true
        error = ""
        result = ""
        let text = sample
        let transform =
            editorVisible
            ? DictationTransform(
                id: editing ?? UUID(), name: name, instructions: instructions) : nil
        operation = Task {
            defer { if operationID == current { previewing = false } }
            do {
                let output = try await writing.preview(text, transform: transform)
                guard !Task.isCancelled, operationID == current else { return }
                result = output
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

private struct DictationCleanupCard: View {
    static var defaultSample: String {
        String(localized: "For Friday, no sorry, Monday, book the room, invite the team, and send the agenda.")
    }

    private struct Input: Equatable {
        let sample: String
        let mode: DictationCleanupMode
        let removesFillers: Bool
        let engine: String?
        let downloading: Bool
        let installed: Bool
    }

    @Binding var sample: String
    @Binding var mode: DictationCleanupMode
    @Environment(AppSettings.self) private var settings
    @Environment(DictationWritingCoordinator.self) private var writing
    @State private var preview: (input: Input, result: Result<String, Error>)?

    var body: some View {
        let engine = settings.dictationSmartCleanup ? settings.dictationCleanupEngine : nil
        let model = settings.dictationSmartCleanup ? writing.selectedLocalModel : nil
        let input = Input(
            sample: sample, mode: mode, removesFillers: settings.dictationRemovesFillerWords,
            engine: engine, downloading: model != nil && writing.cleanup.downloading == model,
            installed: model.map { writing.cleanup.isInstalled($0) } ?? false)
        let result = preview?.input == input ? preview?.result : nil
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            SettingsRowTitle(.dictationCleanup, "Text cleanup")
            HStack(spacing: Theme.Spacing.sm) {
                option(
                    .off, title: "Off", description: "Skip text cleanup.",
                    example: "Um, Monday, no, Tuesday, call Ana and book a room.")
                option(
                    .basic, title: "Basic", description: "Remove fillers and format spoken values.",
                    example: "Monday, no, Tuesday, call Ana and book a room.")
                option(
                    .advanced, title: "Advanced",
                    description: "Also apply spoken corrections and formatting commands.",
                    example: "Tuesday, call Ana and book a room.")
                option(
                    .smart, title: "Smart", description: "Remove fillers, format lists, and apply spoken corrections.",
                    example: "Tuesday:\n• Call Ana\n• Book a room")
            }
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            Grid(alignment: .topLeading, horizontalSpacing: Theme.Spacing.xxl, verticalSpacing: Theme.Spacing.md) {
                GridRow(alignment: .center) {
                    HStack {
                        Text("Sample transcript")
                        Spacer()
                        examplesMenu
                    }
                    HStack(spacing: Theme.Spacing.sm) {
                        Text("Preview")
                        Spacer()
                        if engine != nil { Text(verbatim: writing.cleanupEngineName) }
                        if !sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && result == nil {
                            ProgressView().controlSize(.mini)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                GridRow(alignment: .top) {
                    TextField("Sample transcript", text: $sample, axis: .vertical)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...5)
                        .frame(maxWidth: .infinity)
                    Group {
                        switch result {
                        case .success(let text):
                            Text(verbatim: text).textSelection(.enabled)
                        case .failure(let error):
                            Text(error.localizedDescription).foregroundStyle(.red)
                        case nil:
                            Color.clear.frame(height: 0).accessibilityHidden(true)
                        }
                    }
                    .lineSpacing(Theme.Spacing.xxs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.vertical, Theme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: input) { await update(input) }
    }

    private var examplesMenu: some View {
        Menu("Examples") {
            Button("Default") { sample = Self.defaultSample }
            Button("Currency") { sample = "The total is forty-five dollars and ninety-nine cents." }
            Button("Date") { sample = "Set the deadline for the twenty-fourth of June, twenty twenty-seven." }
            Button("Time") { sample = "Let's meet at nine thirty in the morning." }
            Button("Paragraphs") {
                sample = "The room is booked. New paragraph. Please send the agenda before we meet."
            }
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
    }

    private func option(
        _ option: DictationCleanupMode, title: LocalizedStringKey, description: LocalizedStringKey,
        example: LocalizedStringKey
    ) -> some View {
        let selected = mode == option
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card)
        return Button {
            mode = option
        } label: {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(title).fontWeight(selected ? .semibold : .regular)
                Text(description).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: Theme.Spacing.xxs)
                Text(example)
                    .font(.caption)
                    .italic()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Theme.Spacing.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.Colors.cardFill, in: RoundedRectangle(cornerRadius: Theme.Radius.menu))
            }
            .padding(Theme.Spacing.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(selected ? Theme.Colors.controlSurface : Theme.Colors.cardFill, in: shape)
            .overlay(shape.strokeBorder(selected ? Theme.Colors.textSecondary : Theme.Colors.cardStroke))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func update(_ input: Input) async {
        guard !input.downloading, !input.sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            if input.engine != nil { try await Task.sleep(for: .milliseconds(350)) }
            try Task.checkCancellation()
            let output = try await writing.preview(input.sample, transform: nil)
            try Task.checkCancellation()
            preview = (input, .success(output))
        } catch {
            guard !Task.isCancelled else { return }
            preview = (input, .failure(error))
        }
    }
}
