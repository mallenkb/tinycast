import SwiftUI

/// The search field is the term; the entry fills the palette instead of competing with a list.
struct DictionaryScreen: PaletteScreen {
    static func sourceMenuWidth(_ content: PopoverMenuContent, metrics: InterfaceMetrics) -> CGFloat {
        let font = metrics.typography.textNSFont(.body)
        let titleWidth = content.items.map {
            ($0.title as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 0
        let rowInsets = metrics.spacing.md * 6 + metrics.spacing.sm + metrics.size.menuIcon
        return min(
            metrics.size.panelWidth - metrics.spacing.md * 2,
            max(metrics.size.formMenuMinimumWidth, ceil(titleWidth + rowInsets)))
    }

    let session: DictionarySession
    let core: AppCore
    let vm: PaletteState
    let openMenuCorner: MenuPanelCorner?
    let openInputMenu: (PopoverMenuContent, MenuPanelCorner, Int) -> Void

    private var term: String { vm.query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The page on screen: it stays up while the next term resolves, and ↵ acts on what is shown.
    private var entry: DictionaryEntry? { session.lookup?.entry }

    /// The one entry, so the footer and ⌘K act on it exactly as on a selected row.
    var rows: [DictionaryEntry] { entry.map { [$0] } ?? [] }

    var primaryActionTitle: String { String(localized: "Copy Definition") }

    func actions(at selection: Int) -> PopoverMenuContent? {
        guard let entry else { return nil }
        return PopoverMenuContent(
            header: entry.term,
            items: [
                PopoverMenuItem(
                    title: String(localized: "Copy Definition"), systemImage: "doc.on.doc", shortcut: "↵"
                ) {
                    core.dictionaryCoordinator.copy(entry)
                },
                PopoverMenuItem(
                    title: String(localized: "Open in Dictionary"), systemImage: "book", shortcut: "⌘↵"
                ) {
                    core.dictionaryCoordinator.openInDictionary(entry)
                }
            ])
    }

    func activate(at selection: Int) {
        guard let entry else { return }
        core.dictionaryCoordinator.copy(entry)
    }

    func secondary(at selection: Int) -> Bool {
        guard let entry else { return false }
        core.dictionaryCoordinator.openInDictionary(entry)
        return true
    }

    func sourceButton() -> some View {
        DictionarySourceButton(openMenuCorner: openMenuCorner, openInputMenu: openInputMenu)
            .environment(core.dictionaryCoordinator)
    }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        AnyView(
            DictionaryContentView(query: term, isVisible: vm.isVisible)
                .environment(core.dictionaryCoordinator))
    }
}

private struct DictionarySourceButton: View {
    @Environment(DictionaryCoordinator.self) private var coordinator
    @Environment(\.metrics) private var metrics
    @State private var menuFrame = CGRect.zero
    let openMenuCorner: MenuPanelCorner?
    let openInputMenu: (PopoverMenuContent, MenuPanelCorner, Int) -> Void

    private var session: DictionarySession { coordinator.session }
    private var selectionName: String {
        session.sources.first { $0.id == coordinator.preferredSourceID }?.name
            ?? session.lookup?.entry?.source?.name
            ?? session.sources.first?.name
            ?? String(localized: "Choose Dictionary")
    }

    var body: some View {
        BarButton(isSelected: openMenuCorner == .belowControl(menuFrame), action: openSources) {
            HStack(spacing: metrics.spacing.sm) {
                Text(selectionName)
                    .font(metrics.typography.bar)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(1)
                SymbolImage(name: "chevron.down", size: metrics.spacing.md)
            }
        }
        .accessibilityLabel(Text("Choose Dictionary"))
        .accessibilityValue(selectionName)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            menuFrame = $0
        }
    }

    private func openSources() {
        let sources = coordinator.orderedSources
        let selectedID = sources.first { $0.id == coordinator.preferredSourceID }?.id
            ?? session.lookup?.entry?.source?.id
            ?? sources.first?.id
        let items = sources.map { source in
            PopoverMenuItem(
                title: source.name,
                systemImage: selectedID == source.id ? "checkmark" : "book"
            ) { coordinator.selectSource(source.id) }
        }
        let selection = sources.firstIndex { $0.id == selectedID } ?? 0
        openInputMenu(PopoverMenuContent(items: items), .belowControl(menuFrame), selection)
    }
}

private struct DictionaryContentView: View {
    @Environment(DictionaryCoordinator.self) private var coordinator
    @Environment(\.metrics) private var metrics
    let query: String
    let isVisible: Bool

    private var session: DictionarySession { coordinator.session }
    private var entry: DictionaryEntry? { session.lookup?.entry }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.sm) {
            if let entry {
                if let lookup = session.lookup,
                    !lookup.preferredSourceID.isEmpty, entry.source?.id != lookup.preferredSourceID
                {
                    Text("Showing another source because the preferred dictionary has no available entry.")
                        .font(metrics.typography.rowTrailing)
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .padding(.horizontal, metrics.spacing.xxl)
                }
            }
            definition
        }
        .onAppear { if isVisible { coordinator.prepare(query: query) } }
        .onChange(of: coordinator.preferredSourceID) {
            if isVisible { coordinator.prepare(query: query) }
        }
        .onChange(of: isVisible) {
            if isVisible { coordinator.prepare(query: query) } else { session.reset() }
        }
        .onDisappear { session.reset() }
    }

    @ViewBuilder private var definition: some View {
        if query.isEmpty {
            DictionaryEmptyView(
                text: String(localized: "Type a word to define"),
                detail: String(localized: "Choose active dictionaries in Dictionary.app."))
        } else if let entry {
            DictionaryEntryView(entry: entry)
                .id(entry.source?.id)
        } else if session.lookup?.term == query {
            DictionaryEmptyView(text: String(localized: "No definition found"))
        } else {
            Color.clear
        }
    }

}

private struct DictionaryEmptyView: View {
    @Environment(DictionaryCoordinator.self) private var coordinator
    @Environment(\.metrics) private var metrics
    let text: String
    var detail: String?

    var body: some View {
        VStack(spacing: metrics.spacing.lg) {
            Group {
                if let url = coordinator.applicationURL {
                    EntryIconView(source: .file(stamp: 0), fileURL: url)
                } else {
                    FeatureIconView(name: "FeatureDictionary", size: metrics.size.dictionaryEmptyIcon)
                }
            }
            .frame(width: metrics.size.dictionaryEmptyIcon, height: metrics.size.dictionaryEmptyIcon)
            .accessibilityHidden(true)
            Text(text)
                .font(metrics.typography.rowTitle)
                .foregroundStyle(Theme.Colors.textSecondary)
            if let detail {
                Text(detail)
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(metrics.spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
