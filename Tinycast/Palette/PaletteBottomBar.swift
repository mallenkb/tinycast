import SwiftUI

/// The palette's floating footer; the edge dissolve ghosts the rows passing beneath it.
struct PaletteBottomBar: View {
    let pillLabel: String
    let showActionGroup: Bool
    let formPrimaryShortcut: Bool
    let primaryActionEnabled: Bool
    let showActions: Bool
    let appMenuOpen: Bool
    let onAppMenu: () -> Void
    let onSavedWords: () -> Void
    let onPrimary: () -> Void
    let onActions: () -> Void
    @Environment(PaletteState.self) private var vm
    @Environment(ExtensionManager.self) private var extensions
    @Environment(\.metrics) private var metrics

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: metrics.spacing.sm) {
                appMenuButton
                if vm.mode == .dictionary || vm.mode == .dictionarySavedWords {
                    DictionarySavedWordsButton(
                        isOpen: vm.mode == .dictionarySavedWords, action: onSavedWords)
                }
            }
            .modifier(ExtensionToastSlot(extensions: extensions, showing: vm.mode == .extensionCommand))
            if showActionGroup {
                actionGroup.fixedSize()
            }
        }
        .padding(.horizontal, metrics.spacing.md)
        .frame(height: metrics.size.bottomBarHeight)
        .frame(maxWidth: .infinity)
    }

    /// The Uninstall screen's primary action is destructive, so its pill isn't white.
    private var pillTint: Color {
        vm.mode == .uninstall ? Theme.Colors.destructive : .primary
    }

    @ViewBuilder private var appMenuButton: some View {
        if vm.mode == .launcher {
            MenuCircleButton(action: onAppMenu)
        } else {
            BarButton(isSelected: appMenuOpen, action: onAppMenu) {
                HStack(spacing: metrics.spacing.sm) {
                    if vm.mode == .dictionary || vm.mode == .dictionarySavedWords {
                        FeatureIconView(name: "FeatureDictionary", size: metrics.size.resultRowIcon)
                    } else if let tab = vm.mode.featureTab {
                        FeatureIconView(name: tab.iconAsset, size: metrics.size.resultRowIcon)
                    } else {
                        SymbolImage(
                            name: vm.mode.systemImage,
                            size: metrics.size.barButtonHeight - metrics.spacing.md)
                    }
                    Text(vm.mode.featureTitle)
                        .font(metrics.typography.bar)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(metrics.spacing.xs)
            .frame(height: metrics.size.barButtonHeight + metrics.spacing.xs * 2)
            .frosted(in: Capsule())
            .accessibilityLabel(Text("\(vm.mode.featureTitle), menu"))
        }
    }

    private var actionGroup: some View {
        HStack(spacing: 2) {
            BarButton(action: onPrimary) {
                HStack(spacing: metrics.spacing.sm) {
                    Text(pillLabel)
                        .font(metrics.typography.bar)
                        .foregroundStyle(pillTint)
                    if formPrimaryShortcut {
                        HStack(spacing: metrics.spacing.xxs) {
                            KeyCapChip(text: "⌘", style: .outline)
                            KeyCapChip(text: "↵", style: .outline)
                        }
                    } else {
                        KeyCapChip(text: "↵", style: .outline)
                    }
                }
            }
            .disabled(!primaryActionEnabled)
            if showActions {
                BarButton(action: onActions) {
                    HStack(spacing: metrics.spacing.sm) {
                        Text("Actions")
                            .font(metrics.typography.bar)
                            .foregroundStyle(Theme.Colors.textSecondary)
                        HStack(spacing: metrics.spacing.xxs) {
                            KeyCapChip(text: "⌘", style: .outline)
                            KeyCapChip(text: "K", style: .outline)
                        }
                    }
                }
            }
        }
        .padding(metrics.spacing.xs)
        .frosted(in: Capsule())
    }
}

/// The footer's menu circle; hover lives here, so a sweep never re-renders the body.
private struct MenuCircleButton: View {
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.metrics) private var metrics

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Capsule().frame(width: 14, height: 1.5)
                Capsule().frame(width: 8, height: 1.5)
            }
            .foregroundStyle(Theme.Colors.textSecondary)
            .frame(width: metrics.size.menuButton, height: metrics.size.menuButton)
            .background(Circle().fill(hovered ? Theme.Colors.rowHover : Color.clear))
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .frosted(in: Circle())
    }
}

private extension PaletteMode {
    var featureTab: SettingsTab? {
        switch self {
        case .launcher: nil
        case .clipboard: .clipboard
        case .dictationHistory: .dictation
        case .ai, .aiHistory: .ai
        case .calculatorHistory, .dictionary, .dictionarySavedWords: nil
        case .emoji: .emoji
        case .fileSearch, .uninstall: .fileSearch
        case .menuSearch, .switchWindows: .navigation
        case .rooms, .roomWindows: .windowManagement
        case .schedule, .eventEditor, .meetingDetails: .calendar
        case .customCommands, .customCommandEditor: .commands
        case .quicklinks, .quicklinkEditor: .quicklinks
        case .snippets, .snippetEditor: .snippets
        case .extensionCommand: .extensions
        }
    }

    var featureTitle: String {
        switch self {
        case .clipboard: String(localized: "Clipboard History")
        case .dictationHistory: String(localized: "Dictation History")
        case .calculatorHistory: String(localized: "Calculator History")
        case .dictionary, .dictionarySavedWords: String(localized: "Dictionary")
        case .launcher: String(localized: "Tinycast")
        default: featureTab?.title ?? ""
        }
    }
}
