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
    @State private var showsSupersededModels = false
    @State private var englishOnly = false
    @State private var modelSort = ModelSort.recommended
    @State private var confirmingRemoval: DictationModel?
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
        HStack {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                SettingsRowTitle(.dictationCommands, "Paste last transcript")
                Text("Pastes your latest dictation again where you're typing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ShortcutRecorder(action: .command(.pasteLastDictation))
        }
        HStack {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                SettingsRowTitle(.dictationCommands, "Undo last dictation")
                Text("Removes the last dictation if nothing was typed after it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ShortcutRecorder(action: .command(.undoDictation))
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
        let models = sortedModels.filter { !englishOnly || $0.isEnglishOnly }
        let installed = models.filter { coordinator.models.isInstalled($0) }
        let hidden = models.filter {
            !coordinator.models.isInstalled($0) && Self.supersededModels.contains($0)
                && coordinator.models.downloading != $0 && usesModel != $0
        }
        let available = models.filter {
            !coordinator.models.isInstalled($0) && (showsSupersededModels || !hidden.contains($0))
        }
        let megabytes = installed.reduce(0) { $0 + $1.approximateInstalledMegabytes }
        Section {
            HStack(spacing: Theme.Spacing.lg) {
                Picker("Languages", selection: $englishOnly) {
                    Text("Any language").tag(false)
                    Text("English only").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: Theme.Spacing.lg)
                Picker("Sort", selection: $modelSort) {
                    ForEach(ModelSort.allCases, id: \.self) { sort in
                        Text(sort.title).tag(sort)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            languagePicker
        } header: {
            SettingsSectionHeader(.dictationModel)
        } footer: {
            if !settings.dictationUsesApple && settings.dictationModel.isCohere {
                Text("Live preview is not available for this model.")
            }
        }
        Section {
            if !installed.isEmpty { modelListHeader(showsSelection: true) }
            ForEach(installed, id: \.self) { model in
                if confirmingRemoval == model { removalConfirmation(model) }
                modelListRow(model)
            }
            appleDictationRow
        } header: {
            Text(verbatim: installed.count == 1
                ? String(localized: "On this Mac · 1 model · \(Self.size(megabytes: megabytes))")
                : String(localized: "On this Mac · \(installed.count) models · \(Self.size(megabytes: megabytes))"))
        }
        Section {
            if !available.isEmpty { modelListHeader(showsSelection: false) }
            ForEach(available, id: \.self) { model in
                modelListRow(model)
            }
            if available.isEmpty {
                Text("Everything that matches is downloaded.").foregroundStyle(.secondary)
            }
            if !hidden.isEmpty {
                Button(showsSupersededModels
                    ? String(localized: "Show fewer")
                    : String(localized: "Show \(hidden.count) more: \(hidden.map(\.title).formatted(.list(type: .and)))")
                ) {
                    showsSupersededModels.toggle()
                }
                .buttonStyle(.link)
            }
        } header: {
            Text("Available to download")
        }
    }

    private var usesModel: DictationModel? { settings.dictationUsesApple ? nil : settings.dictationModel }

    private func use(_ model: DictationModel) {
        if model.isCohere, let language = settings.dictationLanguage, !cohereLanguages.contains(language) {
            settings.dictationLanguage = nil
        }
        settings.dictationModel = model
        settings.dictationUsesApple = false
    }

    @ViewBuilder private var languagePicker: some View {
        if let model = usesModel, model.isQwen || model.isCohere, coordinator.models.isInstalled(model) {
            Picker(selection: languageBinding) {
                if model.isCohere {
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
    }

    private enum ModelSort: CaseIterable {
        case recommended, accuracy, speed, size

        var title: LocalizedStringKey {
            switch self {
            case .recommended: "Recommended"
            case .accuracy: "Fewest errors"
            case .speed: "Fastest"
            case .size: "Smallest"
            }
        }
    }

    /// Unmeasured models sort last, so a missing figure never reads as the best one.
    private var sortedModels: [DictationModel] {
        func ordered(_ value: (DictationModel) -> Double?) -> [DictationModel] {
            Self.listedModels.sorted { lhs, rhs in
                switch (value(lhs), value(rhs)) {
                case let (left?, right?): left < right
                case (.some, nil): true
                default: false
                }
            }
        }
        switch modelSort {
        case .recommended: return Self.listedModels
        case .accuracy: return ordered { Self.benchmark(for: $0).errors.flatMap(Double.init) }
        case .speed: return ordered { Self.benchmark(for: $0).speed.map { -Double($0) } }
        case .size: return ordered { Double($0.approximateInstalledMegabytes) }
        }
    }

    @ViewBuilder private func downloadControl(_ model: DictationModel) -> some View {
        if coordinator.models.downloading == model {
            VStack(alignment: .trailing, spacing: Theme.Spacing.xxs) {
                DownloadProgressView(models: coordinator.models, inline: true)
                Button("Cancel") { coordinator.models.cancelDownload() }.buttonStyle(.link)
            }
        } else {
            Button("Download") { downloadModel(model) }
                .disabled(coordinator.models.downloading != nil || coordinator.models.removing == model)
        }
    }

    private static let listedModels: [DictationModel] = [
        .ultra, .fluidMini, .fluidPro, .unified, .cohereQ8, .phonon2, .redux, .v3, .qwenSmall, .v2, .qwenLarge
    ]
    private static let supersededModels: Set<DictationModel> = [.v2, .qwenLarge]

    private func modelListHeader(showsSelection: Bool) -> some View {
        HStack(spacing: Theme.Spacing.lg) {
            if showsSelection {
                Color.clear.frame(width: Theme.Size.settingsRowIcon, height: 0)
                    .accessibilityHidden(true)
            }
            Text("Model")
                .frame(maxWidth: .infinity, alignment: .leading)
            modelStatColumns(
                size: String(localized: "Size"), speed: String(localized: "Speed"),
                errors: "WER/100", isHeader: true)
            Text("Live")
                .frame(width: Theme.Size.dictationModelLive, alignment: .center)
                .help("Shows words in the preview while you speak.")
            Color.clear.frame(width: Theme.Size.dictationModelAction, height: 0)
                .accessibilityHidden(true)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    private func modelStatColumns(size: String, speed: String, errors: String, isHeader: Bool = false) -> some View {
        HStack(spacing: Theme.Spacing.lg) {
            Text(verbatim: size).frame(width: Theme.Size.dictationModelStat, alignment: .leading)
            Text(verbatim: speed).frame(width: Theme.Size.dictationModelStat, alignment: .leading)
            Group {
                if isHeader {
                    Text(verbatim: errors)
                        .help("Errors per 100 words")
                        .accessibilityLabel("Errors per 100 words")
                } else {
                    Text(verbatim: errors)
                }
            }
            .frame(width: Theme.Size.dictationModelErrors, alignment: .leading)
        }
        .lineLimit(isHeader ? nil : 1)
        .fixedSize(horizontal: false, vertical: true)
        .minimumScaleFactor(0.8)
        .monospacedDigit()
    }

    private func modelListRow(_ model: DictationModel) -> some View {
        let installed = coordinator.models.isInstalled(model)
        let selected = usesModel == model
        let benchmark = Self.benchmark(for: model)
        return HStack(spacing: Theme.Spacing.lg) {
            if installed {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(width: Theme.Size.settingsRowIcon, alignment: .leading)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(verbatim: model.title).lineLimit(1)
                Text(verbatim: model.summary).font(.caption).foregroundStyle(.secondary)
                    .help(languageNames(for: model))
                if model == DictationModel.Family.parakeet.defaultModel {
                    modelBadge("Recommended")
                        .padding(.top, Theme.Spacing.xxs)
                }
            }
            Spacer(minLength: Theme.Spacing.lg)
            modelStatColumns(
                size: Self.size(of: model), speed: Self.speedLabel(for: model),
                errors: benchmark.errors ?? String(localized: "Not measured"))
                .font(.caption).foregroundStyle(.secondary)
                .help(benchmarkHelp(for: model))
            liveIndicator(model.isCohere == false)
            Group {
                if installed {
                    modelMenu(model, inUse: selected)
                } else {
                    downloadControl(model)
                }
            }
            .frame(width: Theme.Size.dictationModelAction, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture { if installed { use(model) } }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(installed ? (selected ? [.isButton, .isSelected] : .isButton) : [])
    }

    /// Cohere's fixed 35-second encoder can only transcribe after you stop speaking.
    private func liveIndicator(_ isLive: Bool) -> some View {
        Image(systemName: isLive ? "checkmark" : "minus")
            .font(.caption.weight(isLive ? .semibold : .regular))
            .foregroundStyle(isLive ? Color.accentColor : Color.secondary)
            .frame(width: Theme.Size.dictationModelLive, alignment: .center)
            .help(isLive
                ? String(localized: "Shows words in the preview while you speak.")
                : String(localized: "Shows the text only after you stop speaking."))
            .accessibilityLabel(isLive ? String(localized: "Live preview") : String(localized: "No live preview"))
    }

    private func modelMenu(_ model: DictationModel, inUse: Bool) -> some View {
        Menu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([coordinator.models.directory(for: model)])
            }
            Divider()
            Button("Remove…") { confirmingRemoval = model }
                .disabled(inUse || coordinator.models.transcribing || coordinator.models.removing != nil)
            if inUse { Text("Switch to another model to remove this one.") }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: Theme.Size.settingsRowIcon)
        .accessibilityLabel(String(localized: "More actions for \(model.title)"))
    }

    private func removalConfirmation(_ model: DictationModel) -> some View {
        HStack(spacing: Theme.Spacing.lg) {
            Text("Remove \(model.title)? This frees \(Self.size(of: model)). You can download it again later.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Spacing.lg)
            Button("Cancel") { confirmingRemoval = nil }
            Button("Remove") {
                confirmingRemoval = nil
                removeModel(model)
            }
            .buttonStyle(.dangerAction)
        }
    }

    private var appleDictationRow: some View {
        HStack(spacing: Theme.Spacing.lg) {
            Image(systemName: settings.dictationUsesApple ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(settings.dictationUsesApple ? Color.accentColor : Color.secondary)
                .frame(width: Theme.Size.settingsRowIcon, alignment: .leading)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text("Apple Dictation")
                Text("Uses your Mac’s preferred language and downloads speech assets as needed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { settings.dictationUsesApple = true }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(settings.dictationUsesApple ? [.isButton, .isSelected] : .isButton)
    }

    private func modelBadge(_ title: LocalizedStringKey) -> some View {
        Text(title).font(.caption).foregroundStyle(.tint).lineLimit(1).fixedSize()
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xxs)
            .background(Theme.Colors.modelBadgeBackground, in: Capsule())
    }

    private static func size(of model: DictationModel) -> String {
        size(megabytes: model.approximateInstalledMegabytes)
    }

    private static func size(megabytes: Int) -> String {
        (Int64(megabytes) * 1_000_000).formatted(.byteCount(style: .file))
    }

    /// External benchmark figures: real-time speed and word errors per 100 words on clean speech.
    private static func benchmark(for model: DictationModel) -> (speed: Int?, errors: String?) {
        switch model {
        case .unified: (144, "1.7")
        case .v2: (nil, "1.9")
        case .ultra: (151, "2.1")
        case .fluidMini: (417, "1.5")
        case .fluidPro: (237, nil)
        case .v3: (149, "2.3")
        case .phonon2: (159, "2.5")
        case .redux: (84, "2.7")
        case .cohereQ8: (11, "1.5")
        case .qwenSmall, .qwenLarge: (nil, nil)
        }
    }

    private static func speedLabel(for model: DictationModel) -> String {
        guard let speed = benchmark(for: model).speed else {
            return model.isQwen ? String(localized: "Moderate") : String(localized: "Not measured")
        }
        if speed >= 140 { return String(localized: "Very fast") }
        return speed >= 80 ? String(localized: "Fast") : String(localized: "Slow")
    }

    private func benchmarkHelp(for model: DictationModel?) -> String {
        let source: String
        if let model, model.family == .fluidSpeech {
            source = "https://huggingface.co/\(model.repository)"
        } else if model == .unified {
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
        if model.isEnglishOnly { return String(localized: "English only") }
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
            SettingsRow(title: "Hide indicator text", anchor: .dictationOutput) {
                Toggle("Hide indicator text", isOn: $settings.dictationHideIndicatorText)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            SettingsRow(title: "Position", anchor: .dictationOutput) {
                Button("Restore Defaults") { settings.dictationIndicatorPositions = [:] }
                    .disabled(settings.dictationIndicatorPositions.isEmpty)
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
                SettingsRow(
                    title: title,
                    subtitle: correction.isManual ? nil : String(localized: "Learned from your edits")
                ) {
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
    @Environment(AppSettings.self) private var settings
    let style: DictationIndicatorStyle
    var showsTranscript = false
    var twoLines = false
    var animatesTranscript = true
    @Environment(\.appearsActive) private var appearsActive
    @State private var transcribing = DictationIndicatorView.Phase.randomTranscribing()
    @State private var scrolledIntoView = true

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: Theme.Spacing.xl) { previews }
            VStack(spacing: Theme.Spacing.md) { previews }
        }
        .onScrollVisibilityChange { scrolledIntoView = $0 }
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
            ZStack {
                if style.showsProcessingText(hidesStatusText: settings.dictationHideIndicatorText) {
                    DictationProcessingWidth(style: style)
                }
                preview(transcribing)
            }
        }
    }

    private func preview(_ phase: DictationIndicatorView.Phase) -> some View {
        DictationIndicatorView(
            style: style, phase: phase, hidesStatusText: settings.dictationHideIndicatorText,
            levels: [0.05, 0.25, 0.55, 0.75, 0.45, 0.25, 0.05],
            cyclesWords: appearsActive && scrolledIntoView)
    }
}
