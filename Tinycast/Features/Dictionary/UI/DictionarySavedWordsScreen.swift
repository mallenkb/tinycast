import SwiftUI

struct DictionarySavedWordsScreen: PaletteScreen {
    let coordinator: DictionaryCoordinator
    let query: String

    struct Row: Identifiable {
        let word: String
        var id: String { word }
    }

    var rows: [Row] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return coordinator.savedTerms
            .filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
            .map(Row.init(word:))
    }

    var primaryActionTitle: String { String(localized: "Open") }

    func activate(at selection: Int) {
        guard let row = row(at: selection) else { return }
        coordinator.openSavedWord(row.word)
    }

    func secondary(at selection: Int) -> Bool { false }

    func actions(at selection: Int) -> PopoverMenuContent? {
        guard let row = row(at: selection) else { return nil }
        return PopoverMenuContent(header: row.word, items: [
            PopoverMenuItem(title: String(localized: "Open"), systemImage: "book", shortcut: "↵") {
                coordinator.openSavedWord(row.word)
            },
            PopoverMenuItem(title: String(localized: "Remove Saved Word"), icon: .asset("DictionaryBookmarkFilled")) {
                coordinator.toggleSaved(row.word)
            },
        ])
    }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        let rows = rows
        if rows.isEmpty {
            return AnyView(EmptyResults(text: coordinator.savedTerms.isEmpty
                ? String(localized: "No saved words") : String(localized: "No Results")))
        }
        let selectedID = rows.indices.contains(selection) ? rows[selection].id : nil
        return AnyView(DictionarySavedWordsList(
            rows: rows, selectedID: selectedID, scroll: scroll, onOpen: coordinator.openSavedWord))
    }

    private func row(at selection: Int) -> Row? {
        let rows = rows
        return rows.indices.contains(selection) ? rows[selection] : nil
    }
}

private struct DictionarySavedWordsList: View {
    @Environment(\.metrics) private var metrics
    let rows: [DictionarySavedWordsScreen.Row]
    let selectedID: String?
    let scroll: ScrollIntent
    let onOpen: (String) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        Button { onOpen(row.word) } label: {
                            HStack(spacing: metrics.spacing.lg) {
                                Image("DictionaryBookmarkFilled")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: metrics.size.menuBrandIcon, height: metrics.size.menuBrandIcon)
                                    .foregroundStyle(Theme.Colors.textSecondary)
                                    .accessibilityHidden(true)
                                Text(row.word)
                                    .font(metrics.typography.rowTitle)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, metrics.spacing.md)
                            .frame(height: metrics.size.menuRowHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(
                            RoundedRectangle(cornerRadius: metrics.radius.row)
                                .fill(row.id == selectedID ? Theme.Colors.selection : .clear))
                        .selectionFrame(row.id == selectedID)
                        .accessibilityAddTraits(row.id == selectedID ? .isSelected : [])
                    }
                }
                .padding(.horizontal, metrics.spacing.md)
                .padding(.vertical, metrics.spacing.xs)
                .hideNativeScrollers()
                .scrollOriginAnchor()
            }
            .edgeDissolve()
            .thinScrollbar()
            .scrollFollowsSelection(scroll, row: selectedID, atOrigin: selectedID == rows.first?.id, proxy: proxy)
        }
    }
}
