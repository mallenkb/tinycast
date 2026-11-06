import SwiftUI

struct DictionaryPronunciationView: View {
    @Environment(DictionaryCoordinator.self) private var coordinator
    @Environment(\.metrics) private var metrics
    @State private var sourceFrame = CGRect.zero
    @State private var accentFrame = CGRect.zero
    let term: String
    let writtenPronunciation: String?
    let openInputMenu: (PopoverMenuContent, MenuPanelCorner, Int) -> Void

    private var session: DictionaryPronunciationSession { coordinator.pronunciation }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.sm) {
            HStack(spacing: metrics.spacing.sm) {
                Text("Sounds like")
                    .foregroundStyle(Theme.Colors.textTertiary)
                Spacer(minLength: metrics.spacing.sm)
                selector(title: sourceTitle, action: openSources)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { sourceFrame = $0 }
                selector(title: accentTitle, action: openAccents)
                    .disabled(accentItems.isEmpty)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { accentFrame = $0 }
            }
            Divider()
            HStack(spacing: metrics.spacing.sm) {
                if let guide = session.guide {
                    Text(verbatim: guide)
                        .font(metrics.typography.calcResult.weight(.semibold))
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .help("Approximate pronunciation guide")
                }
                BarButton(isCompact: true, action: session.togglePlayback) {
                    if session.sourceLoading, !session.isPlaying {
                        ProgressView().controlSize(.small)
                    } else {
                        SymbolImage(
                            name: session.isPlaying ? "stop.fill" : "speaker.wave.2.fill",
                            size: metrics.size.menuIcon)
                    }
                }
                .disabled(!session.isPlaying && (!session.playbackAvailable || session.sourceLoading))
                .accessibilityLabel(session.isPlaying ? Text("Stop pronunciation") : Text("Play pronunciation"))
                .help(session.error ?? "")
                Spacer(minLength: metrics.spacing.sm)
                Toggle("Slow", isOn: Binding(get: { session.slow }, set: { session.slow = $0 }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .fixedSize()
            }
        }
        .textSelection(.disabled)
        .font(metrics.typography.rowTrailing)
        .foregroundStyle(Theme.Colors.textSecondary)
        .padding(metrics.spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: metrics.radius.row).fill(Theme.Colors.cardFill))
        .onAppear { prepare() }
        .onChange(of: term) { prepare() }
        .onChange(of: writtenPronunciation) { prepare() }
    }

    private func prepare() {
        session.prepare(term: term, writtenPronunciation: writtenPronunciation)
    }

    private func selector(title: String, action: @escaping () -> Void) -> some View {
        BarButton(action: action) {
            HStack(spacing: metrics.spacing.xs) {
                Text(title).lineLimit(1)
                SymbolImage(name: "chevron.down", size: metrics.spacing.md)
            }
        }
    }

    private var sourceTitle: String {
        session.source == .nativeSpeech
            ? LocalizedStringResource("Native speech").resolved()
            : LocalizedStringResource("Recorded audio").resolved()
    }

    private func title(for key: String, fallback: String) -> String {
        switch key {
        case "en-US": LocalizedStringResource("American").resolved()
        case "en-GB": LocalizedStringResource("British").resolved()
        case "en-AU": LocalizedStringResource("Australian").resolved()
        default: fallback
        }
    }

    private var accentTitle: String {
        if session.source == .nativeSpeech {
            guard let voice = session.speech.selectedVoice else {
                return LocalizedStringResource("Accent").resolved()
            }
            return title(for: voice.language, fallback: voice.name)
        }
        if let recording = session.recording.selectedRecording {
            return title(for: DictionaryPronunciationDisplay.accentKey(recording.title), fallback: recording.title)
        }
        return LocalizedStringResource("Accent").resolved()
    }

    private var accentItems: [PopoverMenuItem] {
        if session.source == .nativeSpeech {
            return session.speech.voices.map { voice in
                PopoverMenuItem(
                    title: title(for: voice.language, fallback: voice.name),
                    systemImage: voice.id == session.speech.selectedVoice?.id ? "checkmark" : "waveform"
                ) { session.selectAccent(id: voice.id) }
            }
        }
        return session.recordingChoices.map { recording in
            PopoverMenuItem(
                title: title(for: DictionaryPronunciationDisplay.accentKey(recording.title), fallback: recording.title),
                systemImage: recording.id == session.recording.selectedRecording?.id ? "checkmark" : "waveform"
            ) { session.selectAccent(id: recording.id) }
        }
    }

    private func openAccents() {
        let items = accentItems
        guard !items.isEmpty else { return }
        let selected = items.firstIndex { $0.icon == .symbol("checkmark") } ?? 0
        openInputMenu(PopoverMenuContent(items: items), .belowControl(accentFrame), selected)
    }

    private func openSources() {
        var items = [
            PopoverMenuItem(
                title: LocalizedStringResource("Native speech").resolved(),
                systemImage: session.source == .nativeSpeech ? "checkmark" : "speaker.wave.2"
            ) { session.source = .nativeSpeech },
            PopoverMenuItem(
                title: LocalizedStringResource("Recorded audio").resolved(),
                systemImage: session.source == .recordedAudio ? "checkmark" : "waveform"
            ) { session.source = .recordedAudio }
        ]
        if session.error != nil || !session.playbackAvailable {
            items.append(PopoverMenuItem(
                title: LocalizedStringResource("Try Again").resolved(), systemImage: "arrow.clockwise"
            ) { session.retry() })
        }
        if let recording = session.referenceRecording {
            items.append(PopoverMenuItem(
                title: recording.author, icon: .blank, isEnabled: false,
                sectionTitle: LocalizedStringResource("Recording credits").resolved(), startsSection: true) {})
            items.append(PopoverMenuItem(
                title: LocalizedStringResource("Recording source").resolved(), systemImage: "link"
            ) { AppLauncher.open(recording.sourceURL) })
            if let url = recording.licenseURL {
                items.append(PopoverMenuItem(title: recording.licenseName, systemImage: "link") {
                    AppLauncher.open(url)
                })
            }
            if recording.licenseURL == nil {
                items.append(PopoverMenuItem(title: recording.licenseName, icon: .blank, isEnabled: false) {})
            }
            if let url = recording.phoneticsURL {
                items.append(PopoverMenuItem(
                    title: LocalizedStringResource("Phonetics: Wiktionary").resolved(), systemImage: "link"
                ) { AppLauncher.open(url) })
            }
        }
        openInputMenu(
            PopoverMenuContent(items: items), .belowControl(sourceFrame),
            session.source == .nativeSpeech ? 0 : 1)
    }
}
