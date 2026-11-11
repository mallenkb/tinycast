import SwiftUI

enum DictationSettingsPage: CaseIterable {
    case home, cleanup, transforms, dictionary, appearance, models

    var title: LocalizedStringResource {
        switch self {
        case .home: "Dictation"
        case .cleanup: "Text cleanup"
        case .transforms: "After dictation"
        case .dictionary: "Dictionary"
        case .appearance: "Indicator & feedback"
        case .models: "Speech recognition"
        }
    }

    var anchor: SettingsAnchor {
        switch self {
        case .home: .dictationDictation
        case .cleanup: .dictationCleanup
        case .transforms: .dictationTransforms
        case .dictionary: .dictationDictionary
        case .appearance: .dictationOutput
        case .models: .dictationModel
        }
    }

    static func page(for target: SettingsTarget) -> Self {
        let anchor = target.anchor
        switch anchor {
        case .dictationCleanup: return .cleanup
        case .dictationTransforms: return .transforms
        case .dictationDictionary: return .dictionary
        case .dictationModel, .dictationMemory: return .models
        case .dictationOutput:
            if target == .row(anchor, String(localized: "Microphone")) { return .home }
            return .appearance
        default: return .home
        }
    }
}

struct DictationSettingsOverview: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DictationWritingCoordinator.self) private var writing
    let open: (DictationSettingsPage) -> Void

    var body: some View {
        @Bindable var settings = settings
        Section {
            row(.cleanup, summary: cleanupSummary)
            row(.transforms, summary: transformSummary)
            row(.dictionary, summary: String(localized: "Names and phrases"))
            Picker(selection: $settings.dictationHistoryRetention) {
                ForEach(ClipboardRetention.allCases) { retention in
                    Text(retention.title).tag(retention)
                }
            } label: {
                SettingsRowTitle(.dictationHistory, "Keep history for")
            }
        } header: {
            SettingsSectionHeader(anchor: .dictationHistory) { Text("Writing") }
        }
    }

    private func row(_ page: DictationSettingsPage, summary: String = "") -> some View {
        DictationSettingsLink(page: page, open: open) {
            Text(summary).foregroundStyle(.secondary)
        }
    }

    private var cleanupSummary: String {
        switch settings.dictationCleanupMode {
        case .off: String(localized: "Off")
        case .basic: String(localized: "Basic")
        case .advanced: String(localized: "Advanced")
        case .smart: String(localized: "Smart") + " · " + writing.cleanupEngineName
        }
    }

    private var transformSummary: String {
        guard settings.dictationAutoTransform,
            let transform = writing.store.savedTransforms.first(where: {
                $0.id.uuidString == settings.dictationTransformID
            })
        else { return String(localized: "No transform") }
        return transform.name
    }
}

struct DictationSettingsLink<Trailing: View>: View {
    let page: DictationSettingsPage
    let open: (DictationSettingsPage) -> Void
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        Button {
            open(page)
        } label: {
            HStack(spacing: Theme.Spacing.lg) {
                Text(page.title).foregroundStyle(.primary)
                Spacer()
                trailing()
                SymbolImage(name: "chevron.right", size: Theme.Typography.menuSymbolSize)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
