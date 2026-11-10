import SwiftUI

struct FileSearchFilterBar: View {
    let session: FileSearchSession
    let settings: AppSettings
    let palette: PaletteState
    let coordinator: FileSearchCoordinator
    @State private var editing: SearchFileConstraints.Clause?
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.sm) {
                    ForEach(session.filters?.clauses ?? []) { clause in
                        HStack(spacing: Theme.Spacing.xs) {
                            Button {
                                editing = clause
                            } label: {
                                Text("\(title(clause.field)): \(detail(clause))")
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            Button {
                                guard let filters = session.filters else { return }
                                palette.query = filters.query(replacing: clause.id, with: nil)
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Remove \(title(clause.field)) filter"))
                        }
                        .padding(.horizontal, Theme.Spacing.sm)
                        .padding(.vertical, Theme.Spacing.xs)
                        .background(Theme.Colors.cardFill, in: Capsule())
                    }
                    Button("Edit Filters…") { adding = true }
                        .buttonStyle(.plain)
                }
                .font(.caption)
            }
            if let issue = session.queryIssue {
                Text(issueMessage(issue)).font(.caption).foregroundStyle(.secondary)
                if case .ambiguousDate(let token, let choices) = issue {
                    HStack {
                        ForEach(choices, id: \.self) { choice in
                            Button {
                                palette.query = SearchFileQuery.resolvingDate(
                                    in: palette.query, token: token, choice: choice)
                            } label: {
                                Text(verbatim: choice)
                            }
                        }
                    }
                }
            }
            if let filters = session.filters, !filters.content.isEmpty {
                if !settings.fileSearchDocumentContentEnabled {
                    Button("Enable Context Search") { coordinator.enableContextSearch() }
                        .font(.caption)
                } else {
                    Text("Content results depend on Spotlight indexing and may be incomplete.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
        .task(id: editing?.id) {
            guard let editing, let filters = session.filters else { return }
            let query = palette.query
            let replacement = await coordinator.editFilter(editing.expression)
            guard !Task.isCancelled else { return }
            if let replacement, palette.query == query {
                palette.query = filters.query(replacing: editing.id, with: replacement)
            }
            self.editing = nil
        }
        .task(id: adding) {
            guard adding else { return }
            let query = palette.query
            let replacement = await coordinator.editFilter(query.isEmpty ? "files" : query)
            guard !Task.isCancelled else { return }
            if let replacement, palette.query == query { palette.query = replacement }
            adding = false
        }
    }

    private func detail(_ clause: SearchFileConstraints.Clause) -> String {
        if clause.field == .category, let category = session.filters?.category {
            return category == .files
                ? String(localized: "Files") : FileSearchFilter(category: category).title
        }
        if clause.field == .order, let order = session.filters?.order {
            switch order {
            case .relevance: return String(localized: "Relevance")
            case .newest: return String(localized: "Newest Modified")
            case .oldest: return String(localized: "Oldest Modified")
            case .newestAdded: return String(localized: "Newest Added")
            case .oldestAdded: return String(localized: "Oldest Added")
            case .name: return String(localized: "Name")
            case .largest: return String(localized: "Largest First")
            case .smallest: return String(localized: "Smallest First")
            }
        }
        return clause.detail
    }

    private func title(_ field: SearchFileConstraints.Field) -> String {
        switch field {
        case .category: String(localized: "Type")
        case .format: String(localized: "Format")
        case .folder: String(localized: "Folder")
        case .modified: String(localized: "Modified")
        case .created: String(localized: "Created")
        case .downloaded: String(localized: "Downloaded")
        case .added: String(localized: "Added")
        case .name: String(localized: "Name")
        case .content: String(localized: "Content")
        case .size: String(localized: "Size")
        case .excluded: String(localized: "Exclude")
        case .tags: String(localized: "Tags")
        case .order: String(localized: "Sort")
        }
    }

    private func issueMessage(_ issue: SearchFileQuery.Issue) -> String {
        switch issue {
        case .invalidDate: String(localized: "Check the date or range, for example 26 May 2026.")
        case .ambiguousDate: String(localized: "Choose which date you mean.")
        case .invalidFilter:
            String(localized: "Check the filter wording and put literal names or phrases in quotes.")
        case .unclosedQuote: String(localized: "Close the quotation marks to finish this search.")
        }
    }
}
