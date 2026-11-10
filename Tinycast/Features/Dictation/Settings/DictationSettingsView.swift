import AppKit
import AVFoundation
import SwiftUI

struct DictationSettingsView: View {
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var settings
    @State private var microphones: [AVCaptureDevice] = []
    @State private var modelSize: Int64?
    @State private var microphoneAccess = Permissions.microphoneAccess()
    @State private var dictionaryWord = ""
    @State private var dictionaryMisspelling = ""
    var body: some View {
        @Bindable var settings = settings
        return Form {
            Section {
                HStack(spacing: Theme.Spacing.lg) {
                    SettingsFeatureToggleLabel(
                        anchor: .dictationDictation, title: "Enable Dictation",
                        subtitle: "Transcribe speech on your Mac with a local model.")
                    Spacer(minLength: Theme.Spacing.lg)
                    Toggle("Enable Dictation", isOn: enabledBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                if microphoneAccess != .authorized {
                    HStack(alignment: .center, spacing: Theme.Spacing.lg) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .frame(width: SettingsListMetrics.iconSize)
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            Text("Microphone access required")
                                .foregroundStyle(.orange)
                            Text("Needed to record your dictation.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: Theme.Spacing.lg)
                        Button(
                            microphoneAccess == .notDetermined
                                ? "Grant Access…" : "Open System Settings"
                        ) {
                            if microphoneAccess == .notDetermined {
                                Task {
                                    _ = await Permissions.requestMicrophoneAccess()
                                    microphoneAccess = Permissions.microphoneAccess()
                                }
                            } else {
                                Permissions.openMicrophoneSettings()
                            }
                        }
                    }
                }
            }
            .settingsAnchor(.dictationDictation)

            if settings.dictationEnabled {
                Section {
                    let issue = coordinator.holdShortcutIssue
                    let holdHint = issue ?? String(
                        localized: "Hold a key combination or a single modifier, then release it to transcribe.")
                    HStack {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            SettingsRowTitle(.dictationCommands, "Hold to talk")
                            Text(holdHint)
                                .font(.caption)
                                .foregroundStyle(issue == nil ? Color.secondary : Color.orange)
                        }
                        Spacer()
                        ShortcutRecorder(action: .dictationHold)
                    }
                    HStack {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            SettingsRowTitle(.dictationCommands, "Hands-free")
                            Text("Press to start or stop")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        ShortcutRecorder(action: .dictationToggle)
                    }
                    settingToggle(
                        anchor: .dictationCommands, title: "Play sounds",
                        subtitle: "Play a sound when recording starts and stops.", isOn: $settings.dictationPlaysSounds)
                    ForEach(CommandCatalog.entries(ownedBy: .dictation)) { entry in
                        FeatureCommandRow(entry: entry)
                    }
                } header: {
                    SettingsSectionHeader(.dictationCommands)
                }

                Section {
                    modelPicker(anchor: .dictationModel, title: "Engine", subtitle: engineSummary, selection: engineBinding) {
                        Text("Apple Dictation").tag(nil as DictationModel.Family?)
                        ForEach(DictationModel.Family.allCases) { family in
                            Text(family.rawValue).tag(Optional(family))
                        }
                    }
                    if !settings.dictationUsesApple {
                        modelPicker(
                            anchor: .dictationModel, title: "Model",
                            subtitle: settings.dictationModel.summary, selection: $settings.dictationModel
                        ) {
                            ForEach(
                                DictationModel.allCases.filter { $0.family == settings.dictationModel.family }
                            ) { model in
                                let title = model == .v3 ? String(localized: "V3 (Recommended)") : model.variantTitle
                                Text(title).tag(model)
                            }
                        }

                        let installed = coordinator.models.isInstalled(settings.dictationModel)
                        let downloading = coordinator.models.downloading == settings.dictationModel
                        if downloading {
                            DownloadProgressView(models: coordinator.models)
                        } else {
                            let title: LocalizedStringResource = installed
                                ? .init("dictation-model-installed", defaultValue: "Installed")
                                : "Not installed"
                            SettingsRow(title: title.resolved(), subtitle: modelDescription, subtitleLineLimit: 2) {
                                if installed {
                                    Button("Remove") { removeModel(settings.dictationModel) }
                                        .disabled(
                                            coordinator.models.transcribing || coordinator.models.removing != nil)
                                } else {
                                    Button("Download") { downloadModel(settings.dictationModel) }
                                        .disabled(
                                            coordinator.models.downloading != nil
                                                || coordinator.models.removing == settings.dictationModel)
                                }
                            }
                        }
                        if settings.dictationModel.isQwen, installed {
                            Picker(selection: languageBinding) {
                                Text(LocalizedStringResource("dictation-language-auto", defaultValue: "Auto"))
                                    .tag("")
                                Divider()
                                ForEach(DictationLanguage.allCases) { language in
                                    Text(language.displayName(locale: .current)).tag(language.rawValue)
                                }
                            } label: {
                                SettingsRowTitle(.dictationModel, "Language")
                            }
                        }
                    }
                    settingToggle(
                        anchor: .dictationModel, title: "Remove filler words",
                        subtitle: "Remove English hesitations like “um” and “uh” from the transcript.",
                        isOn: $settings.dictationRemovesFillerWords)
                } header: {
                    SettingsSectionHeader(.dictationModel)
                }

                if !settings.dictationUsesApple {
                    Section {
                        Picker(selection: $settings.dictationIdleRelease) {
                            ForEach(DictationIdleRelease.allCases) { option in
                                Text(option.title(locale: .current)).tag(option)
                            }
                        } label: {
                            SettingsRowTitle(.dictationMemory, "Release model from memory")
                        }
                    } header: {
                        SettingsSectionHeader(.dictationMemory)
                    } footer: {
                        Text("Releasing it when idle frees memory. The next dictation takes a moment longer.")
                    }
                }

                Section {
                    Picker(selection: microphoneBinding) {
                        Text(microphones.isEmpty ? "No microphone available" : "System default")
                            .tag("")
                        if !microphones.isEmpty { Divider() }
                        ForEach(microphones, id: \.uniqueID) { microphone in
                            Text(microphone.localizedName).tag(microphone.uniqueID)
                        }
                    } label: {
                        SettingsRowTitle(.dictationOutput, "Microphone")
                    }
                    Picker(selection: $settings.dictationIndicatorStyle) {
                        ForEach(DictationIndicatorStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    } label: {
                        SettingsRowTitle(.dictationOutput, "Indicator style")
                    }
                    SettingsRow(title: String(localized: "Preview")) {
                        DictationIndicatorPreviews(style: settings.dictationIndicatorStyle)
                    }
                    settingToggle(
                        anchor: .dictationOutput, title: "Adapt capitalization",
                        subtitle: "Match the first letter to the text before the cursor.",
                        isOn: $settings.dictationAdaptsCapitalization)
                } header: {
                    SettingsSectionHeader(.dictationOutput)
                } footer: {
                    Text(
                        "Press Return to finish dictating or Escape to cancel. Protected fields may refuse insertion."
                    )
                }

            }

            Section {
                settingToggle(
                    anchor: .dictationDictionary, title: "Auto-learn words",
                    subtitle: "Learn spelling corrections you make just after dictation.",
                    isOn: $settings.dictationAutoLearnsWords)
                .settingsEnabled(settings.dictationEnabled)
                HStack(spacing: Theme.Spacing.lg) {
                    TextField("Word or phrase", text: $dictionaryWord, prompt: Text("Word or phrase"))
                        .labelsHidden()
                    TextField(
                        "Misspelling (optional)", text: $dictionaryMisspelling, prompt: Text("Misspelling (optional)"))
                    .labelsHidden()
                    Button("Add", action: addDictionaryWord)
                        .disabled(dictionaryWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onSubmit(addDictionaryWord)
                ForEach(coordinator.corrections.entries) { correction in
                    let title = correction.original == correction.spelling
                        ? correction.spelling : "\(correction.original) → \(correction.spelling)"
                    SettingsRow(title: title) {
                        Button("Remove") { coordinator.removeCorrection(correction) }
                    }
                }
            } header: {
                SettingsSectionHeader(.dictationDictionary)
            }

            Section {
                Picker(selection: $settings.dictationHistoryRetention) {
                    ForEach(ClipboardRetention.allCases) { retention in
                        Text(retention.title).tag(retention)
                    }
                } label: {
                    SettingsRowTitle(.dictationHistory, "Keep history for")
                }
            } header: {
                SettingsSectionHeader(.dictationHistory)
            }
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.dictation)
        .onChange(of: settings.dictationAutoLearnsWords) { _, enabled in
            if !enabled { coordinator.stopCorrectionLearning() }
        }
        .onAppear {
            microphoneAccess = Permissions.microphoneAccess()
            if settings.dictationEnabled { microphones = DictationCapture.microphones }
        }
        .onChange(of: settings.dictationEnabled) { _, enabled in
            if enabled { microphones = DictationCapture.microphones }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(
                named: NSApplication.didBecomeActiveNotification)
            {
                microphoneAccess = Permissions.microphoneAccess()
                if settings.dictationEnabled { microphones = DictationCapture.microphones }
            }
        }
        .task(id: settings.dictationEnabled && !settings.dictationUsesApple ? settings.dictationModel : nil) {
            modelSize = nil
            guard settings.dictationEnabled, !settings.dictationUsesApple else { return }
            coordinator.models.refreshInstalledModels()
            await refreshModelSize(settings.dictationModel)
        }
    }

    private func addDictionaryWord() {
        guard let correction = DictationCorrection.manual(spelling: dictionaryWord, misspelling: dictionaryMisspelling),
            coordinator.addCorrection(correction)
        else { return }
        dictionaryWord = ""
        dictionaryMisspelling = ""
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { settings.dictationEnabled },
            set: { coordinator.setEnabled($0) })
    }

    private func settingToggle(
        anchor: SettingsAnchor, title: LocalizedStringResource, subtitle: LocalizedStringResource, isOn: Binding<Bool>
    ) -> some View {
        SettingsRow(title: title, subtitle: subtitle.resolved(), subtitleLineLimit: 2, anchor: anchor) {
            Toggle(isOn: isOn) { Text(title) }
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    private func modelPicker<Value: Hashable, Choices: View>(
        anchor: SettingsAnchor, title: LocalizedStringResource, subtitle: String, selection: Binding<Value>,
        @ViewBuilder choices: () -> Choices
    ) -> some View {
        SettingsRow(title: title, subtitle: subtitle, subtitleLineLimit: 2, anchor: anchor) {
            Picker(selection: selection, content: choices) { Text(title) }
                .labelsHidden()
                .fixedSize()
        }
    }

    private var engineSummary: String {
        if settings.dictationUsesApple {
            return String(localized: "Uses your Mac’s preferred language and downloads speech assets as needed.")
        }
        return settings.dictationModel.family.summary + " · " + settings.dictationModel.coverage
    }

    private var microphoneBinding: Binding<String> {
        Binding(
            get: { settings.dictationMicrophone ?? "" },
            set: { settings.dictationMicrophone = $0.isEmpty ? nil : $0 })
    }

    private var engineBinding: Binding<DictationModel.Family?> {
        Binding(
            get: { settings.dictationUsesApple ? nil : settings.dictationModel.family },
            set: { family in
                if let family, family != settings.dictationModel.family {
                    settings.dictationModel = family.defaultModel
                }
                settings.dictationUsesApple = family == nil
            })
    }

    private var languageBinding: Binding<String> {
        Binding(
            get: { settings.dictationLanguage ?? "" },
            set: {
                settings.dictationLanguage = $0.isEmpty ? nil : $0
            })
    }

    private var modelDescription: String {
        let approximate = Int64(settings.dictationModel.approximateInstalledMegabytes) * 1_000_000
        return modelSize.map {
            String(localized: "\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)) on disk")
        } ?? String(localized: "About \(approximate.formatted(.byteCount(style: .file))) on disk")
    }

    private struct DownloadProgressView: View {
        let models: DictationModelStore

        var body: some View {
            let progress = models.downloadProgress
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                LabeledContent {
                    Button("Cancel") { models.cancelDownload() }
                } label: {
                    Text(title)
                }
                if let progress, progress.total > 0 {
                    ProgressView(value: Double(progress.received), total: Double(progress.total))
                        .tint(.accentColor)
                        .accessibilityLabel("Model download progress")
                    HStack {
                        let received = progress.received.formatted(.byteCount(style: .file))
                        let total = progress.total.formatted(.byteCount(style: .file))
                        Text("\(received) of \(total)")
                        Spacer()
                        Text(
                            Double(progress.received) / Double(progress.total),
                            format: .percent.precision(.fractionLength(0)))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .accessibilityLabel("Preparing model download")
                }
            }
        }

        private var title: String {
            guard let progress = models.downloadProgress else {
                return String(localized: "Preparing download…")
            }
            return progress.total > 0 && progress.received >= progress.total
                ? String(localized: "Finishing download…") : String(localized: "Downloading model…")
        }
    }

    private func refreshModelSize(_ model: DictationModel) async {
        let size = await coordinator.models.installedSize(model)
        if !Task.isCancelled, settings.dictationModel == model { modelSize = size }
    }

    private func downloadModel(_ model: DictationModel) {
        Task {
            await coordinator.downloadModel(model)
            await refreshModelSize(model)
        }
    }

    private func removeModel(_ model: DictationModel) {
        Task {
            await coordinator.removeModel(model)
            await refreshModelSize(model)
        }
    }
}

private struct DictationIndicatorPreviews: View {
    let style: DictationIndicatorStyle
    @State private var transcribing = DictationIndicatorView.Phase.randomTranscribing()

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.xl) { previews }
            VStack(spacing: Theme.Spacing.md) { previews }
        }
    }

    private var previews: some View {
        Group {
            preview(.listening)
            preview(transcribing)
        }
    }

    private func preview(_ phase: DictationIndicatorView.Phase) -> some View {
        DictationIndicatorView(
            style: style, phase: phase,
            levels: [0.05, 0.25, 0.55, 0.75, 0.45, 0.25, 0.05])
    }
}
