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
    @State private var sample = String(
        localized: "For Friday, no sorry, Monday, book the room, invite the team, and send the agenda.")
    @State private var result = ""
    @State private var error = ""
    @State private var previewing = false
    @State private var operation: Task<Void, Never>?
    @State private var download: Task<Void, Never>?
    @State private var operationID = UUID()
    @State private var previewApp = DictationPreviewApp.slack
    @State private var showsMoreOptions = false

    private var localCleanupModels: [DictationCleanupModel.Variant] {
        let models: [DictationCleanupModel.Variant] = [.emberon2, .s1Mini, .s1ASRCleanup]
        let installed = models.filter { writing.cleanup.isInstalled($0) }
        return installed + models.filter { !installed.contains($0) }
    }

    var body: some View {
        @Bindable var settings = settings
        Group {
            if page == .cleanup {
                Section {
                    VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                        SettingsRowTitle(.dictationCleanup, "Text cleanup")
                        DictationCleanupLevelPicker(mode: $settings.dictationCleanupMode)
                        if settings.dictationCleanupMode == .smart || settings.dictationAutoTransform {
                            modelCard
                        }
                    }
                    .padding(.vertical, Theme.Spacing.sm)
                }
                .settingsAnchor(.dictationCleanup)
                Section {
                    DictationCleanupStage(app: $previewApp)
                }
                formatSection
                moreOptionsSection
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
                    if let model = transformDownload {
                        modelRow(model)
                    } else if let reason = writing.transformUnavailableReason {
                        Text(reason).foregroundStyle(.secondary)
                    }
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

    private var engineIsAppleIntelligence: Bool { settings.dictationCleanupEngine == "appleIntelligence" }

    @ViewBuilder private var modelCard: some View {
        let model = writing.selectedLocalModel
        let downloading = model.map { writing.cleanup.downloading == $0 } ?? false
        let installed = model.map { writing.cleanup.isInstalled($0) } ?? true
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card)
        HStack(spacing: Theme.Spacing.lg) {
            Image(systemName: engineIsAppleIntelligence ? "apple.intelligence" : "sparkles")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: Theme.Size.dialogIcon, height: Theme.Size.dialogIcon)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: Theme.Radius.menu))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(verbatim: model?.name ?? String(localized: "Apple Intelligence")).fontWeight(.medium)
                Group {
                    if let model {
                        let size = model.downloadBytes.formatted(.byteCount(style: .file))
                        Text(installed
                            ? String(localized: "Downloaded · \(size) · on this Mac")
                            : String(localized: "\(size) · runs on this Mac"))
                    } else if let reason = writing.unavailableReason {
                        Text(reason)
                    } else {
                        Text("Built into macOS")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: Theme.Spacing.lg)
            if downloading, let model {
                HStack(spacing: Theme.Spacing.sm) {
                    ProgressView(value: Double(writing.cleanup.downloadedBytes), total: Double(model.downloadBytes))
                        .progressViewStyle(.linear)
                        .frame(width: Theme.Size.dictationCleanupProgress)
                        .accessibilityLabel("Model download progress")
                    Text(Double(writing.cleanup.downloadedBytes) / Double(model.downloadBytes),
                         format: .percent.precision(.fractionLength(0)))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Button("Cancel") { download?.cancel() }.buttonStyle(.link)
                }
            } else {
                if let model, !installed {
                    Button("Download") { startDownload(model) }
                        .buttonStyle(.borderedProminent)
                        .disabled(writing.cleanup.downloading != nil)
                }
                modelMenu(model: model, installed: installed)
            }
        }
        .padding(Theme.Spacing.lg)
        .background(Theme.Colors.cardFill, in: shape)
        .overlay(shape.strokeBorder(Theme.Colors.cardStroke))
    }

    private func modelMenu(model: DictationCleanupModel.Variant?, installed: Bool) -> some View {
        @Bindable var settings = settings
        return Menu("Change") {
            Picker("Smart model", selection: $settings.dictationCleanupEngine) {
                ForEach(localCleanupModels, id: \.self) { candidate in
                    let size = candidate.downloadBytes.formatted(.byteCount(style: .file))
                    Text(verbatim: writing.cleanup.isInstalled(candidate)
                        ? String(localized: "\(candidate.name) · Downloaded")
                        : "\(candidate.name) · \(size)")
                        .tag(candidate.rawValue)
                }
                Text("Apple Intelligence · Built in").tag("appleIntelligence")
            }
            .pickerStyle(.inline)
            if let model, installed {
                Divider()
                Button("Remove \(model.name)", role: .destructive) {
                    do { try writing.cleanup.remove(model) } catch { self.error = error.localizedDescription }
                }
                .disabled(writing.cleanup.busy)
            }
        }
        .fixedSize()
        .disabled(writing.cleanup.downloading != nil)
    }

    private func startDownload(_ model: DictationCleanupModel.Variant) {
        error = ""
        download = Task {
            do { try await writing.cleanup.download(model) } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    @ViewBuilder private var formatSection: some View {
        @Bindable var settings = settings
        let kind = previewApp.kind
        let format = settings.dictationFormatsByApp ? settings.dictationAppFormats[kind] : .full
        let arranges = settings.dictationCleanupMode == .advanced || settings.dictationCleanupMode == .smart
        Section {
            if settings.dictationFormatsByApp {
                SettingsRow(title: kind.settingsApps, subtitle: kind.settingsEffect(of: format)) {
                    DictationPreviewAppIcon(app: previewApp)
                } trailing: {
                    Picker(kind.settingsFormatHeader, selection: $settings.dictationAppFormats[kind]) {
                        ForEach(DictationFormat.allCases, id: \.self) { Text($0.settingsTitle).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            } else {
                SettingsRow(
                    title: String(localized: "Same format in every app"),
                    subtitle: String(localized: "Paragraphs and lists everywhere.")
                ) {
                    EmptyView()
                }
            }
            if format == .full {
                HStack(spacing: Theme.Spacing.lg) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        SettingsRowTitle(.dictationCleanup, "Paragraphs")
                        if !arranges {
                            Text("Needs Advanced or Smart cleanup").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: Theme.Spacing.lg)
                    Picker("Paragraphs", selection: $settings.dictationParagraphs) {
                        Text("At pauses and topic changes").tag(DictationParagraphs.automatic)
                        Text("When I say \u{201C}new paragraph\u{201D}").tag(DictationParagraphs.spoken)
                        Text("Never").tag(DictationParagraphs.never)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .settingsEnabled(arranges)
            }
        } header: {
            HStack {
                Text(verbatim: settings.dictationFormatsByApp
                    ? kind.settingsFormatHeader : String(localized: "Format"))
                Spacer()
                if settings.dictationFormatsByApp && format != DictationAppFormats.suggested(for: kind) {
                    Button("Use suggested") { settings.dictationAppFormats[kind] = DictationAppFormats.suggested(for: kind) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
    }

    @ViewBuilder private var moreOptionsSection: some View {
        @Bindable var settings = settings
        Section {
            DisclosureGroup("More options", isExpanded: $showsMoreOptions) {
                Toggle(isOn: $settings.dictationFormatsByApp) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        SettingsRowTitle(.dictationCleanup, "Format for each app")
                        Text("Off gives every app paragraphs and lists.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                Toggle(isOn: $settings.dictationDetectsWebApps) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text("Recognize web apps in browsers")
                        Text("Gmail, Slack and ChatGPT in a tab get their own format. Reads the tab's address.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .disabled(!settings.dictationFormatsByApp)
                Toggle(isOn: $settings.dictationDetectsTerminalAgents) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text("Recognize coding agents in terminals")
                        Text("claude and codex in a terminal count as AI tools. Reads the window title.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .disabled(!settings.dictationFormatsByApp)
                HStack {
                    Spacer()
                    Button("Reset formats to suggested") { settings.dictationAppFormats = DictationAppFormats() }
                        .disabled(settings.dictationAppFormats == DictationAppFormats())
                }
            }
        }
    }

    private var transformDownload: DictationCleanupModel.Variant? {
        guard let engine = writing.selectedLocalModel?.transformEngine else { return nil }
        return writing.cleanup.isInstalled(engine) && writing.cleanup.downloading != engine ? nil : engine
    }

    @ViewBuilder
    private func modelRow(_ model: DictationCleanupModel.Variant) -> some View {
        let size = model.downloadBytes.formatted(.byteCount(style: .file))
        let title = switch model {
        case .s1Mini: "S1-mini by Superwhisper"
        case .s1ASRCleanup: "S1-ASR-Cleanup (S1-mini by Superwhisper)"
        case .emberon2: model.name
        }
        SettingsRow(
            title: title,
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
                .disabled(writing.cleanup.downloading != nil)
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
