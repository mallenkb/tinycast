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
    @State private var modelFilter: ModelFilter = .all
    @State private var microphones: [AVCaptureDevice] = []
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
        .task(id: page) {
            if page == .models { coordinator.models.refreshInstalledModels() }
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
            modelFilters
            ForEach(visibleChoices, id: \.self) { choice in
                if let model = choice.model {
                let selected = !settings.dictationUsesApple && settings.dictationModel == model
                let installed = coordinator.models.isInstalled(model)
                let downloading = coordinator.models.downloading == model
                HStack(alignment: .center, spacing: Theme.Spacing.lg) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Button {
                            if model.isCohere, let language = settings.dictationLanguage,
                                !cohereLanguages.contains(language) {
                                settings.dictationLanguage = nil
                            }
                            settings.dictationModel = model
                            settings.dictationUsesApple = false
                        } label: {
                            modelChoiceLabel(
                                title: modelChoiceTitle(model), subtitle: model.summary,
                                model: model, installed: installed, selected: selected)
                        }
                        .buttonStyle(.plain)
                        .disabled(!installed)
                        if downloading {
                            DownloadProgressView(models: coordinator.models, inline: true)
                                .padding(.leading, Theme.Spacing.xl + Theme.Spacing.md)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: Theme.Spacing.sm)
                    if downloading {
                        Button("Cancel") { coordinator.models.cancelDownload() }
                    } else if !installed {
                        Button("Download") { downloadModel(model) }
                            .disabled(coordinator.models.downloading != nil || coordinator.models.removing == model)
                    } else if installed && !selected {
                        Button(role: .destructive) { removeModel(model) } label: { Text("Remove") }
                            .buttonStyle(.dangerAction)
                            .disabled(coordinator.models.transcribing || coordinator.models.removing != nil)
                    }
                }
                .padding(.vertical, Theme.Spacing.sm)
                if selected && model.isCohere {
                    Text("Live preview is not available for this model.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                } else {
                    HStack(spacing: Theme.Spacing.md) {
                        Image(systemName: "circle").foregroundStyle(.secondary).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            HStack(spacing: Theme.Spacing.xs) {
                                Text(verbatim: choice.title)
                                if choice == recommendedChoice {
                                    modelBadge("Recommended")
                                }
                            }
                            Text("Unavailable").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, Theme.Spacing.sm)
                }
            }
            if modelFilter == .all || modelFilter == .live {
                Button {
                    settings.dictationUsesApple = true
                } label: {
                    modelChoiceLabel(
                        title: String(localized: "Apple Dictation"),
                        subtitle: String(localized: "Uses your Mac’s preferred language and downloads speech assets as needed."),
                        model: nil, installed: true, selected: settings.dictationUsesApple)
                }
                .buttonStyle(.plain)
            }
            if !settings.dictationUsesApple, settings.dictationModel.isQwen || settings.dictationModel.isCohere,
                coordinator.models.isInstalled(settings.dictationModel)
            {
                Picker(selection: languageBinding) {
                    if settings.dictationModel.isCohere {
                        Text(verbatim: DictationLanguage.english.displayName(locale: .current)).tag("")
                    } else {
                        Text(LocalizedStringResource("dictation-language-auto", defaultValue: "Auto")).tag("")
                    }
                    Divider()
                    ForEach(availableLanguages) { language in
                        Text(language.displayName(locale: .current)).tag(language.rawValue)
                    }
                } label: {
                    SettingsRowTitle(.dictationModel, "Language")
                }
            }
        } header: {
            SettingsSectionHeader(.dictationModel)
        }
    }

    private enum ModelFilter: CaseIterable {
        case all, accuracy, speed, multilingual, compact, live

        var title: LocalizedStringResource {
            switch self {
            case .all: "All"
            case .accuracy: "Accuracy"
            case .speed: "Speed"
            case .multilingual: "Multilingual"
            case .compact: "Compact"
            case .live: "Live"
            }
        }

        var icon: String {
            switch self {
            case .all: "list-filter"
            case .accuracy: "target"
            case .speed: "zap"
            case .multilingual: "languages"
            case .compact: "hard-drive"
            case .live: "mic"
            }
        }
    }

    private var modelFilters: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(ModelFilter.allCases, id: \.self) { filter in
                    let selected = filter == modelFilter
                    Button { modelFilter = filter } label: {
                        HStack(spacing: Theme.Spacing.xs) {
                            if filter != .all { lucideIcon(filter.icon, size: Theme.Size.dictationModelFilterIcon) }
                            Text(filter.title)
                        }
                            .font(.body)
                            .foregroundStyle(selected ? Theme.Colors.modelFilterSelectedInk : Theme.Colors.textPrimary)
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, Theme.Spacing.md)
                            .background(selected ? Theme.Colors.modelFilterSelected : Theme.Colors.cardFill, in: Capsule())
                            .overlay(Capsule().strokeBorder(
                                selected ? Theme.Colors.modelFilterSelected : Theme.Colors.cardStroke))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private enum ModelChoice: Hashable {
        case available(DictationModel)
        case cohereQ4

        var model: DictationModel? {
            if case .available(let model) = self { return model }
            return nil
        }

        var title: String {
            switch self {
            case .cohereQ4: "Cohere Transcribe Q4"
            case .available(let model): model.title
            }
        }
    }

    private var visibleChoices: [ModelChoice] {
        let listed: [ModelChoice] = [
            .available(.unified), .available(.v2), .available(.ultra), .available(.v3),
            .available(.phonon2), .available(.redux), .available(.cohereQ8), .cohereQ4,
            .available(.qwenSmall), .available(.qwenLarge)
        ]
        let filtered: [ModelChoice]
        switch modelFilter {
        case .all: filtered = listed
        case .accuracy:
            filtered = listed.filter { $0.model == .unified || $0.model == .cohereQ8 || $0.model == .v2 || $0.model == .ultra }
        case .speed:
            filtered = listed.filter {
                $0.model == .unified || $0.model == .ultra || $0.model == .phonon2 || $0.model == .redux
            }
        case .multilingual:
            filtered = listed.filter {
                $0.model == .ultra || $0.model == .v3 || $0.model == .redux ||
                    $0.model?.isQwen == true || $0.model?.isCohere == true
            }
        case .compact:
            filtered = listed.filter { ($0.model?.approximateInstalledMegabytes ?? .max) <= 650 }
        case .live: filtered = listed.filter { $0.model == .unified }
        }
        return filtered.filter { $0 == recommendedChoice } + filtered.filter { $0 != recommendedChoice }
    }

    private var recommendedChoice: ModelChoice {
        switch modelFilter {
        case .all, .accuracy: .available(.unified)
        case .speed, .multilingual: .available(.ultra)
        case .compact: .available(.redux)
        case .live: .available(.unified)
        }
    }

    private func lucideIcon(_ name: String, size: CGFloat = 12) -> some View {
        Image("lucide-" + name).renderingMode(.template).resizable()
            .scaledToFit().frame(width: size, height: size).accessibilityHidden(true)
    }

    private func modelChoiceLabel(
        title: String, subtitle: String, model: DictationModel?, installed: Bool, selected: Bool
    ) -> some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(verbatim: title)
                    if selected {
                        modelBadge("In use")
                    }
                    if let model, ModelChoice.available(model) == recommendedChoice {
                        modelBadge("Recommended")
                    }
                }
                Text(verbatim: subtitle).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let model {
                    modelChoiceDetails(model, installed: installed)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func modelBadge(_ title: LocalizedStringKey) -> some View {
        Text(title).font(.caption).foregroundStyle(.tint)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xxs)
            .background(Theme.Colors.modelBadgeBackground, in: Capsule())
    }

    private func modelChoiceDetails(_ model: DictationModel, installed: Bool) -> some View {
        let bytes = Int64(model.approximateInstalledMegabytes) * 1_000_000
        let size = "~" + bytes.formatted(.byteCount(style: .file))
        let benchmark: (speed: Int?, wer: String)? = switch model {
        case .unified: (144, "1.68")
        case .v2: (nil, "1.86")
        case .ultra: (151, "2.13")
        case .v3: (149, "2.27")
        case .phonon2: (159, "2.47")
        case .redux: (84, "2.71")
        case .cohereQ8: (11, "1.49")
        case .qwenSmall, .qwenLarge: nil
        }
        return HStack(spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.xxs) {
                lucideIcon("hard-drive")
                Text(verbatim: size)
            }
            if let speed = benchmark?.speed {
                HStack(spacing: Theme.Spacing.xxs) {
                    lucideIcon("zap")
                    Text("~\(speed)× realtime")
                }
                .help(benchmarkHelp(for: model))
            }
            HStack(spacing: Theme.Spacing.xxs) {
                lucideIcon("languages")
                Text(verbatim: model.coverage)
            }
            .help(languageNames(for: model))
            if let benchmark {
                HStack(spacing: Theme.Spacing.xxs) {
                    lucideIcon("badge-check")
                    Text("\(benchmark.wer)% clean WER")
                }
                .help(benchmarkHelp(for: model))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }

    private func benchmarkHelp(for model: DictationModel?) -> String {
        let source: String
        if model == .unified {
            source = "https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml"
        } else if model == .v2 || model == .cohereQ8 {
            source = "https://github.com/moona3k/macparakeet#asr-benchmarks"
        } else {
            source = "https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md"
        }
        return String(localized: "External benchmark; results vary by device.") + "\n" + source
    }

    private let cohereLanguages: Set<String> = [
        "English", "French", "German", "Spanish", "Italian", "Portuguese", "Dutch", "Polish",
        "Greek", "Arabic", "Japanese", "Chinese", "Vietnamese", "Korean"
    ]

    private var availableLanguages: [DictationLanguage] {
        DictationLanguage.allCases.filter {
            !settings.dictationModel.isCohere || (cohereLanguages.contains($0.rawValue) && $0 != .english)
        }
    }

    private func languageNames(for model: DictationModel) -> String {
        if model == .v2 || model == .phonon2 || model == .unified { return String(localized: "English only") }
        let codes = ["bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
                     "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk"]
        let names: [String]
        if model.isCohere {
            names = DictationLanguage.allCases.filter { cohereLanguages.contains($0.rawValue) }
                .map { $0.displayName(locale: .current) }
        } else if model.isQwen {
            names = DictationLanguage.allCases.map { $0.displayName(locale: .current) }
        } else {
            names = codes.map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }
        }
        return ListFormatter.localizedString(byJoining: names.sorted())
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
                    twoLines: settings.dictationTwoLinePreview,
                    animatesTranscript: settings.dictationAnimateTranscript)
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
            SettingsRow(
                title: "Auto-learn words",
                subtitle: String(localized: "Learn spelling corrections while the dictation field is focused."),
                anchor: .dictationDictionary
            ) { EmptyView() }
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

    private var languageBinding: Binding<String> {
        Binding(
            get: { settings.dictationLanguage ?? "" },
            set: {
                settings.dictationLanguage = $0.isEmpty ? nil : $0
            })
    }

    private func modelChoiceTitle(_ model: DictationModel) -> String {
        return model.title
    }

    private struct DownloadProgressView: View {
        let models: DictationModelStore
        var inline = false

        var body: some View {
            let progress = models.downloadProgress
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                if !inline {
                    LabeledContent {
                        Button("Cancel") { models.cancelDownload() }
                    } label: {
                        Text(title)
                    }
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

    private func downloadModel(_ model: DictationModel) {
        Task { await coordinator.downloadModel(model) }
    }

    private func removeModel(_ model: DictationModel) {
        Task { await coordinator.removeModel(model) }
    }

}

struct DictationIndicatorPreviews: View {
    let style: DictationIndicatorStyle
    var showsTranscript = false
    var twoLines = false
    var animatesTranscript = true
    @State private var transcribing = DictationIndicatorView.Phase.randomTranscribing()

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: Theme.Spacing.xl) { previews }
            VStack(spacing: Theme.Spacing.md) { previews }
        }
    }

    private var previews: some View {
        Group {
            VStack(spacing: Theme.Spacing.md) {
                if showsTranscript {
                    DictationTranscriptView(
                        transcript: String(
                            localized: "For Friday, no sorry, Monday, book the room, invite the team, and send the agenda."),
                        animates: animatesTranscript, twoLines: twoLines, style: style,
                        maximumWidth: Theme.Size.dictationSettingsPreviewWidth)
                        .id(twoLines)
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
