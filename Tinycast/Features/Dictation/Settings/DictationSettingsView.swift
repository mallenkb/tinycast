import AppKit
import AVFoundation
import SwiftUI

struct DictationSettingsView: View {
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(DictationWritingCoordinator.self) private var writing
    @Environment(AppSettings.self) private var settings
    @Environment(HotKeyManager.self) private var hotKeys
    @Environment(SettingsNavigationState.self) private var navigation
    private var page: DictationSettingsPage {
        navigation.target.map(DictationSettingsPage.page(for:)) ?? .home
    }
    @State private var microphones: [AVCaptureDevice] = []
    @State private var modelSize: Int64?
    @State private var microphoneAccess = Permissions.microphoneAccess()
    @State private var dictionaryWord = ""
    @State private var dictionaryMisspelling = ""
    var body: some View {
        Form {
            switch page {
            case .home:
                featureSection
                recordingSection
                DictationSettingsOverview(open: openPage)
            case .cleanup: DictationWritingSettingsView(page: .cleanup)
            case .transforms: DictationWritingSettingsView(page: .transforms)
            case .dictionary: dictionarySection
            case .appearance: appearanceSection
            case .models:
                modelSection
                memorySection
            }
        }
        .formStyle(.grouped)
        .id(navigation.detail)
        .frame(maxWidth: Theme.Size.settingsPageWidth)
        .frame(maxWidth: .infinity)
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

    @ViewBuilder private var featureSection: some View {
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
            if coordinator.isSettingUpModels {
                if coordinator.models.downloading != nil {
                    DownloadProgressView(models: coordinator.models)
                } else if let model = writing.cleanup.downloading {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        LabeledContent {
                            Button("Cancel") { coordinator.cancelModelSetup() }
                        } label: {
                            Text("Downloading model…")
                            Text(verbatim: model.name).font(.caption).foregroundStyle(.secondary)
                        }
                        ProgressView(value: Double(writing.cleanup.downloadedBytes), total: Double(model.downloadBytes))
                            .accessibilityLabel("Model download progress")
                    }
                }
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
            ForEach(CommandCatalog.entries(ownedBy: .dictation)) { entry in
                FeatureCommandRow(entry: entry)
            }
        }
        .settingsAnchor(.dictationDictation)

    }

    private var recordingSection: some View {
        Section {
            if settings.dictationEnabled { recordingControls }
            DictationSettingsLink(page: .appearance, open: openPage) {
                DictationIndicatorPreviews(style: settings.dictationIndicatorStyle)
                    .accessibilityHidden(true)
            }
            .accessibilityValue(Text(settings.dictationIndicatorStyle.shape.title))
            DictationSettingsLink(page: .models, open: openPage) {
                Text(settings.dictationUsesApple
                    ? String(localized: "Apple Dictation")
                    : settings.dictationModel.family.rawValue + " " + settings.dictationModel.variantTitle)
                    .foregroundStyle(.secondary)
            }
        } header: {
            SettingsSectionHeader(anchor: .dictationCommands) { Text("Recording") }
        }
    }

    private func openPage(_ page: DictationSettingsPage) {
        navigation.select(.dictation, revealing: .section(page.anchor), highlight: false)
    }

    @ViewBuilder private var recordingControls: some View {
        let issue = coordinator.holdShortcutIssue
        let holdHint =
            issue
            ?? String(
                localized: "Hold a key combination or a single modifier, then release it to transcribe.")
        HStack {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                SettingsRowTitle(.dictationCommands, "Push to talk")
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
                Text("Use either shortcut to start or finish.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: Theme.Spacing.sm) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text("Custom shortcut").font(.caption).foregroundStyle(.secondary)
                    ShortcutRecorder(action: .dictationToggle)
                }
                .padding(.top, Theme.Spacing.xs)
                if let key = hotKeys.binding(for: .dictationHold)?.holdKey {
                    HStack(spacing: Theme.Spacing.sm) {
                        Text("Double tap").foregroundStyle(.secondary)
                        KeyCapChip.Label(
                            text: key.modifier?.glyph ?? "Fn",
                            prefix: key.singleBinding.recorderPrefix
                        )
                        .font(Theme.Typography.keyCap)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Theme.Spacing.xs)
                        .frame(
                            minWidth: Theme.Size.recorderKeyCap,
                            minHeight: Theme.Size.recorderKeyCap
                        )
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.recorderKeyCap)
                                .fill(Color.primary.opacity(0.08)))
                    }
                    .frame(width: Theme.Size.shortcutRecorder, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.menu)
                            .fill(Theme.Colors.cardFill)
                    )
                }
            }
        }
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
    }

    @ViewBuilder private var modelSection: some View {
        @Bindable var settings = settings
        Section {
            modelPicker(
                anchor: .dictationModel, title: "Engine", subtitle: engineSummary, selection: engineBinding
            ) {
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
                        let title = model == .ultra ? String(localized: "Ultra (Recommended)") : model.variantTitle
                        Text(title).tag(model)
                    }
                }

                let installed = coordinator.models.isInstalled(settings.dictationModel)
                let downloading = coordinator.models.downloading == settings.dictationModel
                if downloading {
                    DownloadProgressView(models: coordinator.models)
                } else {
                    let title: LocalizedStringResource =
                        installed
                        ? .init("dictation-model-installed", defaultValue: "Installed")
                        : "Not installed"
                    SettingsRow(title: title.resolved(), subtitle: modelDescription, subtitleLineLimit: 2) {
                        if installed {
                            Button(role: .destructive) {
                                removeModel(settings.dictationModel)
                            } label: {
                                Text("Remove")
                            }
                            .buttonStyle(.dangerAction)
                            .disabled(coordinator.models.transcribing || coordinator.models.removing != nil)
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

        } header: {
            SettingsSectionHeader(.dictationModel)
        }

    }

    @ViewBuilder private var memorySection: some View {
        @Bindable var settings = settings
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

    }

    @ViewBuilder private var appearanceSection: some View {
        @Bindable var settings = settings
        Section {
            Picker(selection: indicatorShapeBinding) {
                ForEach(DictationIndicatorStyle.Shape.allCases) { shape in
                    Text(shape.title).tag(shape)
                }
            } label: {
                SettingsRowTitle(.dictationOutput, "Indicator style")
            }
            SettingsRow(title: "Dark mode", anchor: .dictationOutput) {
                Toggle("Dark mode", isOn: indicatorDarkModeBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            SettingsRow(title: String(localized: "Preview")) {
                DictationIndicatorPreviews(
                    style: settings.dictationIndicatorStyle,
                    showsTranscript: settings.dictationLivePreview,
                    twoLines: settings.dictationTwoLinePreview)
            }
            settingToggle(
                anchor: .dictationOutput, title: "Live transcript preview",
                subtitle: "Show recent words above the indicator while recording.",
                isOn: $settings.dictationLivePreview)
            settingToggle(
                anchor: .dictationOutput, title: "Two-line live preview",
                subtitle: "Wrap the live transcript across two lines.",
                isOn: $settings.dictationTwoLinePreview)
            .settingsEnabled(settings.dictationLivePreview)
            settingToggle(
                anchor: .dictationOutput, title: "Show idle indicator",
                subtitle: "Keep a small bar visible when dictation is ready.",
                isOn: $settings.dictationIdleIndicator)
            settingToggle(
                anchor: .dictationOutput, title: "Play sounds",
                subtitle: "Play a sound when recording starts and stops.",
                isOn: $settings.dictationPlaysSounds)
        } header: {
            SettingsSectionHeader(.dictationOutput)
        } footer: {
            Text(
                "Press Return to finish dictating or Escape to cancel. Protected fields may refuse insertion."
            )
        }
    }

    @ViewBuilder private var dictionarySection: some View {
        @Bindable var settings = settings
        Section {
            settingToggle(
                anchor: .dictationDictionary, title: "Auto-learn words",
                subtitle: "Learn spelling corrections you make just after dictation.",
                isOn: $settings.dictationAutoLearnsWords
            )
            .settingsEnabled(settings.dictationEnabled)
            HStack(spacing: Theme.Spacing.lg) {
                TextField("Word or phrase", text: $dictionaryWord, prompt: Text("Word or phrase"))
                    .labelsHidden()
                TextField(
                    "Misspelling (optional)", text: $dictionaryMisspelling,
                    prompt: Text("Misspelling (optional)")
                )
                .labelsHidden()
                Button("Add", action: addDictionaryWord)
                    .disabled(dictionaryWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .onSubmit(addDictionaryWord)
            ForEach(coordinator.corrections.entries) { correction in
                let title =
                    correction.original == correction.spelling
                    ? correction.spelling : "\(correction.original) → \(correction.spelling)"
                SettingsRow(title: title) {
                    Button(role: .destructive) {
                        coordinator.removeCorrection(correction)
                    } label: {
                        Text("Remove")
                    }
                    .buttonStyle(.dangerAction)
                }
            }
        } header: {
            SettingsSectionHeader(.dictationDictionary)
        }

    }

    private func addDictionaryWord() {
        guard
            let correction = DictationCorrection.manual(
                spelling: dictionaryWord, misspelling: dictionaryMisspelling),
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
        anchor: SettingsAnchor, title: LocalizedStringResource, subtitle: LocalizedStringResource,
        isOn: Binding<Bool>
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
            return String(
                localized: "Uses your Mac’s preferred language and downloads speech assets as needed.")
        }
        return settings.dictationModel.family.summary + " · " + settings.dictationModel.coverage
    }

    private var indicatorShapeBinding: Binding<DictationIndicatorStyle.Shape> {
        Binding(
            get: { settings.dictationIndicatorStyle.shape },
            set: { shape in
                let style = settings.dictationIndicatorStyle
                settings.dictationIndicatorStyle = .init(
                    shape: shape, isDark: style.isDark, usesGrayBackground: false)
            })
    }

    private var indicatorDarkModeBinding: Binding<Bool> {
        Binding(
            get: { settings.dictationIndicatorStyle.isDark },
            set: { isDark in
                let style = settings.dictationIndicatorStyle
                settings.dictationIndicatorStyle = .init(
                    shape: style.shape, isDark: isDark, usesGrayBackground: false)
            })
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

struct DictationIndicatorPreviews: View {
    let style: DictationIndicatorStyle
    var showsTranscript = false
    var twoLines = false
    @State private var hasReachedTwoLines = false
    @State private var transcribing = DictationIndicatorView.Phase.randomTranscribing()

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: Theme.Spacing.xl) { previews }
            VStack(spacing: Theme.Spacing.md) { previews }
        }
        .onChange(of: showsTranscript) {
            if !showsTranscript { hasReachedTwoLines = false }
        }
    }

    private var previews: some View {
        Group {
            VStack(spacing: Theme.Spacing.md) {
                if showsTranscript {
                    DictationTranscriptView(
                        transcript: String(
                            localized: "For Friday, no sorry, Monday, book the room, invite the team, and send the agenda."),
                        animates: true, twoLines: twoLines, style: style,
                        hasReachedTwoLines: $hasReachedTwoLines,
                        maximumWidth: Theme.Size.dictationSettingsPreviewWidth)
                }
                preview(.listening)
            }
            preview(transcribing)
        }
    }

    private func preview(_ phase: DictationIndicatorView.Phase) -> some View {
        DictationIndicatorView(
            style: style, phase: phase,
            levels: [0.05, 0.25, 0.55, 0.75, 0.45, 0.25, 0.05])
    }
}
