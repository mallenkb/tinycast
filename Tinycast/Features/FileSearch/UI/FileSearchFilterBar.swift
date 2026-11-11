import SwiftUI

struct FileSearchFilterBar: View {
    @Environment(\.metrics) private var metrics
    @Environment(\.locale) private var locale
    let session: FileSearchSession
    let settings: AppSettings
    let palette: PaletteState
    let coordinator: FileSearchCoordinator
    @State private var editing: SearchFileConstraints.Clause?
    @State private var adding = false

    private var chipHeight: CGFloat { metrics.scaled(22) }

    var body: some View {
        let clauses = session.filters?.clauses ?? []
        VStack(alignment: .leading, spacing: metrics.spacing.sm) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: metrics.spacing.sm) {
                    ForEach(clauses) { clause in
                        chip(clause)
                    }
                    Button {
                        adding = true
                    } label: {
                        Text("Edit Filters…")
                            .foregroundStyle(.secondary)
                            .frame(height: chipHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, clauses.isEmpty ? 0 : -metrics.spacing.sm)
            if let issue = session.queryIssue {
                Text(issueMessage(issue)).foregroundStyle(.secondary)
                if case .ambiguousDate(let token, let choices) = issue {
                    HStack(spacing: metrics.spacing.sm) {
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
                        .buttonStyle(.link)
                } else {
                    Text("Content results depend on Spotlight indexing and may be incomplete.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(metrics.typography.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, metrics.paletteQueryLeadingInset)
        .padding(.trailing, metrics.spacing.md * 2)
        .padding(.vertical, metrics.spacing.xs)
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

    private func chip(_ clause: SearchFileConstraints.Clause) -> some View {
        let field = title(clause.field)
        let value = detail(clause)
        return HStack(spacing: metrics.spacing.xs) {
            Button {
                editing = clause
            } label: {
                HStack(spacing: metrics.spacing.xs) {
                    Text(field).foregroundStyle(.secondary)
                    Text(verbatim: value).fontWeight(.medium)
                }
                .lineLimit(1)
                .frame(height: chipHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                guard let filters = session.filters else { return }
                palette.query = filters.query(replacing: clause.id, with: nil)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: metrics.scaled(8), weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: metrics.scaled(18), height: chipHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Remove \(field) filter"))
        }
        .padding(.leading, metrics.spacing.sm)
        .padding(.trailing, metrics.spacing.xxs)
        .background(Theme.Colors.cardFill, in: Capsule())
    }

    private func detail(_ clause: SearchFileConstraints.Clause) -> String {
        if let filters = session.filters {
            switch clause.field {
            case .format:
                return filters.extensions.map { $0.uppercased() }.joined(separator: ", ")
            case .modified: return dateDetail(filters.modified) ?? clause.detail
            case .created: return dateDetail(filters.created) ?? clause.detail
            case .downloaded: return dateDetail(filters.downloaded) ?? clause.detail
            case .added: return dateDetail(filters.added) ?? clause.detail
            default: break
            }
        }
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

    private func dateDetail(_ bounds: SearchFileConstraints.Bounds?) -> String? {
        guard let bounds else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let dateStyle = Date.FormatStyle(
            date: .abbreviated, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        switch (bounds.start, bounds.end) {
        case let (start?, end?):
            let last = end.addingTimeInterval(-1)
            if calendar.isDate(start, inSameDayAs: last) { return start.formatted(dateStyle) }
            let interval = Date.IntervalFormatStyle(
                date: .abbreviated, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            return interval.format(start..<last)
        case let (nil, end?):
            return "< " + end.formatted(dateStyle)
        case let (start?, nil):
            return "> " + start.addingTimeInterval(-1).formatted(dateStyle)
        case (nil, nil):
            return nil
        }
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
