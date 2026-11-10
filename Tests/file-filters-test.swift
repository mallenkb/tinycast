import CoreServices
import Darwin
import Foundation

@main
struct FileFilterTests {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        return calendar
    }
    static var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12))! }

    static func filters(_ query: String) -> SearchFileConstraints {
        guard case .filters(let filters) = SearchFileQuery.parse(query, now: now, calendar: calendar) else {
            fatalError("Did not parse: \(query)")
        }
        return filters
    }
    static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError(message) }
    }

    static func main() throws {
        let examples = [
            "HTML files in Downloads modified on 26 May",
            "PDFs in Documents from 26 of last month containing \"invoice\"",
            "PNG or JPG files created between 1 June and 15 June", "videos larger than 500 MB, largest first",
            "CSV files named \"sales\" modified in June 2021",
            "files in \"~/Work\" excluding folder \"Archive\""
        ]
        for query in examples { _ = filters(query) }
        expect(filters("files on 26 May").modified?.start == day(2026, 5, 26), "missing year is current year")
        expect(
            filters("files on 26 of last month").modified?.start == day(2026, 10, 26), "day in previous month"
        )
        expect(filters("files on 26 June 2021").modified?.start == day(2021, 6, 26), "explicit year")
        expect(filters("files on 2021-06-26").modified?.end == day(2021, 6, 27), "ISO whole day")
        expect(filters("files in June 2021").modified?.end == day(2021, 7, 1), "whole month")
        expect(filters("files in 2021").modified?.end == day(2022, 1, 1), "whole year")
        expect(filters("files between 26 May and 2 June").modified?.end == day(2026, 6, 3), "inclusive range")
        expect(filters("files before 26 May").modified?.end == day(2026, 5, 26), "exclusive before")
        expect(filters("files after 26 May").modified?.start == day(2026, 5, 27), "exclusive after")
        expect(filters("files from last week Friday").modified?.start == day(2026, 11, 6), "weekday")
        let htmlThursday = filters("all html files from last week thursday")
        expect(htmlThursday.extensions == ["html"], "HTML format is explicit")
        expect(
            htmlThursday.modified?.start == day(2026, 11, 5)
                && htmlThursday.modified?.end == day(2026, 11, 6),
            "last week's Thursday is one calendar day")
        expect(filters("extension .blend").extensions == ["blend"], "arbitrary extension")
        expect(filters(".tar.gz files").extensions == ["tar.gz"], "compound extension")
        expect(filters("PDF or DOCX files").extensions == ["pdf", "docx"], "alternative formats")
        expect(
            filters("files named invoice from yesterday").modified == nil, "unquoted filename remains literal"
        )
        let literal = filters("files named \"report modified on 26 May\"")
        expect(
            literal.name == "report modified on 26 May" && literal.modified == nil,
            "quoted content remains literal")
        expect(filters("files named exactly \"invoice.pdf\"").nameMode == .exact, "exact filename")
        expect(filters("files named starting with \"invoice\"").nameMode == .prefix, "filename prefix")
        expect(filters("files named ending with \"draft.pdf\"").nameMode == .suffix, "filename suffix")
        expect(
            filters("files containing all words invoice overdue").content == ["invoice", "overdue"],
            "all content words")
        expect(filters("files containing any words invoice receipt").textMode == .any, "any content words")
        expect(filters("files tagged any \"Work\" \"Tax\"").allTags == false, "any tags")
        expect(filters("files tagged \"Work\" and \"Tax\"").allTags, "all tags")
        expect(filters("files in \"~/Work\" without subfolders").recursive == false, "direct children")
        expect(filters("files larger than 1 MB").minimumSize == 1_000_001, "strict decimal size")
        expect(filters("files smaller than 1 MiB").maximumSize == 1_048_575, "strict binary size")
        expect(filters("empty files").maximumSize == 0, "empty files")
        expect(filters("files between 1 MB and 10 MB").maximumSize == 10_000_000, "inclusive size range")
        for query in [
            "files on 31 April", "files on 2021-02-29", "files from tomorrow", "files on 26",
            "files after 2026-02-31", "files between 2 June and 26 May", "files larger than 1e99 GB",
            "files on 26 June 2021 morning", "files named \"unclosed"
        ] {
            guard case .issue = SearchFileQuery.parse(query, now: now, calendar: calendar) else {
                fatalError("Unsafe fallback: \(query)")
            }
        }
        guard
            case .issue(.ambiguousDate(_, let choices)) = SearchFileQuery.parse(
                "files on 06/07/2021", now: now, calendar: calendar)
        else {
            fatalError("Ambiguous date was guessed")
        }
        expect(Set(choices) == ["2021-06-07", "2021-07-06"], "both date interpretations")
        guard case .literal = SearchFileQuery.parse("2021", now: now, calendar: calendar) else {
            fatalError("filename year was filtered")
        }
        let combined = filters("HTML files in Downloads modified on 26 May named \"invoice\"")
        let folder = combined.clauses.first { $0.field == .folder }!
        let edited = filters(combined.query(replacing: folder.id, with: "in Documents"))
        expect(
            edited.folder == "Documents" && edited.extensions == ["html"] && edited.name == "invoice",
            "chip editing preserves other filters")
        let resolved = SearchFileQuery.resolvingDate(in: "Find files on 06/07/2021!",
                                                     token: "06/07/2021", choice: "2021-06-07")
        expect(filters(resolved).modified?.start == day(2021, 6, 7),
               "choosing an ambiguous date also handles sentence punctuation")
        queryNuances()
        try index()
        try addedFolders()
        try ranking()
        print("File filter checks passed")
    }

    static func queryNuances() {
        let latest = filters("What was the latest folder I added to /my movies?")
        expect(latest.category == .folders && latest.folder == "~/my movies" && !latest.recursive
            && latest.order == .newestAdded, "a natural folder question keeps its scope and Date Added sort")
        expect(filters("Find folders in My Movies without subfolders.").folder == "My Movies",
               "multiword folder paths end at the next filter")
        let videos = filters("Which MP4 or MOV files in Movies did I download last week and edit yesterday, largest first?")
        expect(videos.extensions == ["mp4", "mov"] && videos.folder == "Movies"
            && videos.downloaded?.start == day(2026, 11, 2)
            && videos.modified?.start == day(2026, 11, 9) && videos.order == .largest,
               "a conversational video query keeps both date fields, formats, folder and sort")
        let content = filters(
            #"Find HTML files in "~/Work/Client A" downloaded last week Friday "#
                + #"excluding folder "Archive" containing "balance due"."#)
        expect(content.folder == "~/Work/Client A" && content.downloaded?.start == day(2026, 11, 6)
            && content.excludedFolders == ["Archive"] && content.content == ["balance due"],
               "sentence punctuation after a quoted content clause is ignored")
        let images = filters(
            "Find PNG or JPG files in Pictures created between 1 June 2026 and 15 June 2026 "
                + "larger than 2 MB, smallest first.")
        expect(images.created?.end == day(2026, 6, 16) && images.minimumSize == 2_000_001
            && images.order == .smallest, "creation range, size and sort survive a final period")
        let pdfs = filters(
            #"Find PDFs in Documents tagged all "Work" "Tax" excluding tag "Private" "#
                + #"created before 1 November 2026 containing "payment overdue"."#)
        expect(pdfs.tags == ["Work", "Tax"] && pdfs.excludedTags == ["Private"]
            && pdfs.created?.end == day(2026, 11, 1) && pdfs.content == ["payment overdue"],
               "tag and date constraints survive a quoted content clause")
        let archives = filters(
            #"Find .tar.gz files in "~/Backups" without subfolders modified on 26 of last month "#
                + "size between 10 MB and 100 MB, largest first.")
        expect(archives.extensions == ["tar.gz"] && !archives.recursive
            && archives.modified?.start == day(2026, 10, 26)
            && archives.minimumSize == 10_000_000 && archives.maximumSize == 100_000_000
            && archives.order == .largest, "compound extension, date, size bounds and scope stay intact")
    }

    static func index() throws {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "file-filters-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = scratch.resolvingSymlinksInPath().appending(path: "home")
        for (name, count) in [
            ("Downloads/invoice.html", 10), ("Downloads/report.pdf", 20),
            ("Downloads/Archive/old.pdf", 30), ("Downloads/design.blend", 40),
            ("Downloads/invoice.html.txt", 1), ("Downloads/clip-noon.mp4", 1)
        ] {
            var url = root.appending(path: name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 65, count: count).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: day(2026, 5, 26)], ofItemAtPath: url.path)
            if name.hasSuffix(".html") {
                var resource = URLResourceValues()
                resource.quarantineProperties = [
                    kLSQuarantineTimeStampKey as String: day(2026, 11, 5),
                    kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String
                ]
                try url.setResourceValues(resource)
            }
            if count == 20 {
                var values = URLResourceValues()
                values.tagNames = ["Work", "Tax"]
                try url.setResourceValues(values)
            }
        }
        let policy = FileSearchPolicy(scopes: [root.path], ignorePatterns: [], homeDirectory: root)
        let roots = FileIndexCrawler.roots(of: policy)
        let crawl = FileIndexCrawler.Crawl(roots: roots, policy: policy).run(workers: 1)
        let cache = scratch.appending(path: "index.bin")
        try FileIndexSnapshot.write(
            crawl, roots: roots, eventID: 0, fingerprint: policy.fingerprint, to: cache)
        let index = FileIndex()
        index.replace(with: FileIndexSnapshot(contentsOf: cache), policy: policy)
        func names(_ query: String) -> [String] {
            index.filteredSearch(filters(query), filter: .all).map(\.name)
        }
        expect(
            names("HTML files in Downloads modified on 26 May") == ["invoice.html"], "combined index filters")
        expect(
            names("HTML files downloaded last week") == ["invoice.html"],
            "download filters use the recorded download date even when the file was modified earlier")
        expect(names("HTML files downloaded in May").isEmpty, "modification dates cannot stand in for downloads")
        expect(
            names("files downloaded last week") == ["invoice.html"],
            "files without download metadata are excluded")
        expect(
            names("files larger than 20 B, largest first") == ["design.blend", "old.pdf"],
            "size and sorting before limit")
        expect(names("PDFs in Downloads without subfolders") == ["report.pdf"], "direct folder children")
        expect(names("PDFs excluding folder Archive") == ["report.pdf"], "excluded subtree")
        expect(names("files tagged all Work Tax") == ["report.pdf"], "Finder tags")
        expect(names(#"PDFs tagged any "Tax" "Private" excluding name "invoice""#) == ["report.pdf"],
               "a name exclusion alone retains the other tag matches")
        expect(names(".html") == ["invoice.html"], "a bare dotted extension rejects a misleading suffix")
        for query in ["clp-noon", "clpi-noon"] {
            let results = index.search(FileSearchQuery.prepare(query)!, filter: .all)
            expect(results.map(\.name) == ["clip-noon.mp4"], "filename typo fallback for \(query)")
        }
        expect(names("extension .blend") == ["design.blend"], "unfamiliar format in index")
        expect(
            index.filteredSearch(filters("files"), filter: .all, isCancelled: { true }).isEmpty,
            "cancelled query")
        let content = filters("PDFs named exactly \"report.pdf\" containing invoice")
        expect(index.filteredSearch(content, filter: .all).isEmpty, "content requires Spotlight candidates")
        let report = root.appending(path: "Downloads/report.pdf").path
        let indexedReport = index.snapshot!.roots[0] + "/Downloads/report.pdf"
        expect(
            index.filteredSearch(content, filter: .all, contentPaths: [report, indexedReport, "/outside/report.pdf"]).map(
                \.name) == ["report.pdf"], "content candidates stay within the index")
    }

    static func addedFolders() throws {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "file-added-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = scratch.resolvingSymlinksInPath()
        let movies = root.appending(path: "My Movies")
        let first = movies.appending(path: "First")
        let latest = movies.appending(path: "Latest")
        let nested = latest.appending(path: "Nested")
        for folder in [first, nested] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if folder == first { Thread.sleep(forTimeInterval: 1.1) }
        }
        try FileManager.default.setAttributes([.modificationDate: day(2026, 11, 10)], ofItemAtPath: first.path)
        try FileManager.default.setAttributes([.modificationDate: day(2026, 11, 5)], ofItemAtPath: latest.path)
        let policy = FileSearchPolicy(scopes: [movies.path], ignorePatterns: [], homeDirectory: root)
        let roots = FileIndexCrawler.roots(of: policy)
        let crawl = FileIndexCrawler.Crawl(roots: roots, policy: policy).run(workers: 1)
        let cache = scratch.appending(path: "index.bin")
        try FileIndexSnapshot.write(crawl, roots: roots, eventID: 0, fingerprint: policy.fingerprint, to: cache)
        let index = FileIndex()
        index.replace(with: FileIndexSnapshot(contentsOf: cache), policy: policy)
        let lowercase = root.appending(path: "my movies").path
        let query = filters(FileManager.default.fileExists(atPath: lowercase)
            ? "What was the latest folder I added to /my movies?"
            : #"What was the latest folder I added to "~/My Movies"?"#)
        let results = index.filteredSearch(query, filter: .all).map(\.name)
        let dateKey: Set<URLResourceKey> = [.addedToDirectoryDateKey, .contentModificationDateKey]
        let dates = try [first, latest].map { url in
            let values = try url.resourceValues(forKeys: dateKey)
            return (url.lastPathComponent, values.addedToDirectoryDate ?? values.contentModificationDate!)
        }
        let expected = dates.sorted { left, right in
            left.1 == right.1 ? left.0 < right.0 : left.1 > right.1
        }.map { $0.0 }
        expect(results == expected, "Date Added orders only direct children, using modification when unavailable")
    }

    static func ranking() throws {
        struct Fixture {
            let name: String
            let modified: Int
            let added: Date
            let size: Int
            let relevance: Int
        }
        let scratch = FileManager.default.temporaryDirectory.appending(path: "file-ranking-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var fixtures: [Fixture] = []
        for number in 0..<1_200 {
            let prefix = number.isMultiple(of: 2) ? "item" : "xitem"
            let name = String(format: "%@-%04d.%@", prefix, number, number.isMultiple(of: 3) ? "HTML" : "html")
            let modified = 1_790_000_000 + (number * 37) % 307
            let size = number % 37
            let path = scratch.appending(path: name)
            try Data(repeating: 65, count: size).write(to: path)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: Double(modified))], ofItemAtPath: path.path)
            let date = try path.resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate
            fixtures.append(Fixture(
                name: name, modified: modified, added: date ?? Date(timeIntervalSince1970: Double(modified)),
                size: size, relevance: prefix == "item" ? 1 : 0))
        }
        let policy = FileSearchPolicy(scopes: [scratch.path], ignorePatterns: [], homeDirectory: scratch)
        let roots = FileIndexCrawler.roots(of: policy)
        let crawl = FileIndexCrawler.Crawl(roots: roots, policy: policy).run(workers: 1)
        let cache = scratch.appending(path: "index.bin")
        try FileIndexSnapshot.write(crawl, roots: roots, eventID: 0, fingerprint: policy.fingerprint, to: cache)
        let index = FileIndex()
        index.replace(with: FileIndexSnapshot(contentsOf: cache), policy: policy)
        for order in SearchFileConstraints.Order.allCases {
            var query = SearchFileConstraints()
            query.category = .files
            query.extensions = ["html"]
            query.order = order
            if order == .relevance { query.name = "item" }
            let expected = fixtures.sorted { left, right in
                switch order {
                case .relevance:
                    if left.relevance != right.relevance { return left.relevance > right.relevance }
                    if left.modified != right.modified { return left.modified > right.modified }
                case .newest: if left.modified != right.modified { return left.modified > right.modified }
                case .oldest: if left.modified != right.modified { return left.modified < right.modified }
                case .newestAdded: if left.added != right.added { return left.added > right.added }
                case .oldestAdded: if left.added != right.added { return left.added < right.added }
                case .largest: if left.size != right.size { return left.size > right.size }
                case .smallest: if left.size != right.size { return left.size < right.size }
                case .name:
                    let compared = left.name.localizedStandardCompare(right.name)
                    if compared != .orderedSame { return compared == .orderedAscending }
                }
                return left.name < right.name
            }.prefix(FileSearchQuery.resultLimit).map(\.name)
            expect(index.filteredSearch(query, filter: .all).map(\.name) == expected, "top results by \(order)")
        }
    }
}
