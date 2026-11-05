import SwiftUI

struct DictionaryPronunciationView: View {
    @Environment(DictionaryCoordinator.self) private var coordinator
    @Environment(\.metrics) private var metrics
    let term: String

    private var session: DictionaryPronunciationSession { coordinator.pronunciation }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.sm) {
            if session.term != term || session.loading {
                HStack(spacing: metrics.spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("Loading pronunciation…")
                }
            } else if let recording = session.selectedRecording {
                recordingView(recording)
            } else if session.error == nil {
                Text("No recording available.")
            }
            if let error = session.error {
                HStack(spacing: metrics.spacing.sm) {
                    Text(error)
                    Button("Try Again") { session.retry() }
                        .buttonStyle(.plain)
                }
            }
        }
        .textSelection(.disabled)
        .font(metrics.typography.rowTrailing)
        .foregroundStyle(Theme.Colors.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, metrics.spacing.md)
        .onAppear { session.prepare(term: term) }
        .onChange(of: term) { session.prepare(term: term) }
    }

    @ViewBuilder private func recordingView(_ recording: DictionaryPronunciation.Recording) -> some View {
        let transcriptions = recording.ipa.map { [$0] } ?? recording.ipaVariants
        let hasGuide = transcriptions.contains { PronunciationRespelling.english($0) != nil }
        HStack(alignment: .firstTextBaseline, spacing: metrics.spacing.sm) {
            Text("English pronunciation")
                .foregroundStyle(Theme.Colors.textTertiary)
            Spacer(minLength: metrics.spacing.sm)
            accentLabel(recording.title)
        }
        if hasGuide { Text("Sounds like").foregroundStyle(Theme.Colors.textTertiary) }
        HStack(alignment: .center, spacing: metrics.spacing.sm) {
            VStack(alignment: .leading, spacing: metrics.spacing.xs) {
                ForEach(transcriptions, id: \.self) { ipa in
                    Text(verbatim: PronunciationRespelling.english(ipa) ?? ipa)
                        .font(metrics.typography.calcResult.weight(.semibold))
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            BarButton(isCompact: true, action: session.togglePlayback) {
                if session.loadingAudio {
                    ProgressView().controlSize(.small)
                } else {
                    SymbolImage(
                        name: session.isPlaying ? "stop.fill" : "speaker.wave.2.fill",
                        size: metrics.size.menuIcon)
                }
            }
            .accessibilityLabel(session.isPlaying ? Text("Stop pronunciation") : Text("Play pronunciation"))
            .disabled(session.loadingAudio)
            Spacer(minLength: 0)
        }
        if !transcriptions.isEmpty {
            VStack(alignment: .leading, spacing: metrics.spacing.xs) {
                if hasGuide {
                    Text("Approximate guide")
                    Text(verbatim: transcriptions.joined(separator: " · "))
                }
                if transcriptions.count > 1 {
                    Text("The recording may use one of these pronunciations.")
                }
            }
            .foregroundStyle(Theme.Colors.textTertiary)
        }
        controls
        HStack(spacing: metrics.spacing.sm) {
            Link("Audio: Wikimedia Commons", destination: recording.sourceURL)
            if let url = recording.licenseURL {
                Link(destination: url) { Text(verbatim: recording.licenseName) }
            } else {
                Text(verbatim: recording.licenseName)
            }
        }
        .foregroundStyle(Theme.Colors.textSecondary)
        if !transcriptions.isEmpty, let url = recording.phoneticsURL {
            Link("Phonetics: Wiktionary", destination: url)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
        Text(verbatim: recording.author)
            .foregroundStyle(Theme.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func accentLabel(_ title: String) -> Text {
        switch title.lowercased() {
        case "ga": Text("General American")
        case "us": Text("American")
        case "uk": Text("British")
        case "rp": Text("Received Pronunciation")
        case "au": Text("Australian")
        default: Text(verbatim: title)
        }
    }

    private var controls: some View {
        HStack(spacing: metrics.spacing.md) {
            Toggle("Slow", isOn: Binding(get: { session.slow }, set: { session.slow = $0 }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .fixedSize()
            if session.recordings.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: metrics.spacing.xs) {
                        ForEach(session.recordings) { recording in
                            BarButton(
                                isSelected: recording.id == session.selectedRecording?.id,
                                action: { session.selectRecording(id: recording.id) }
                            ) {
                                accentLabel(recording.title)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}
