import Darwin
import Foundation

@main
@MainActor
struct DescriptionSearchTests {
    static var failures = 0
    static let now = Date(timeIntervalSince1970: 1_799_409_600)
    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        value.firstWeekday = 2
        return value
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { failures += 1; print("FAIL: \(message)") }
    }

    static func parse(_ query: String) -> SearchDescription? {
        SearchDescription(query, now: now, calendar: calendar)
    }

    static func main() async throws {
        parser()
        weekdayDescriptions()
        try await files()
        try weekdayFiles()
        try await clipboard()
        try await interpretedClipboard()
        try imageContent()
        intentPolicy()
        dates()
        print("Description search tests: \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }

    static func parser() {
        let allPDFs = parse("all pdf from last week")
        expect(allPDFs?.fileExtension == "pdf" && allPDFs?.text == "", "all is a qualifier, not a filename")
        expect(allPDFs?.dates == parse("pdf from last week")?.dates, "all preserves the previous week range")
        expect(parse("show all my PDFs from last week") == allPDFs, "leading qualifiers combine")
        expect(parse("PDFs named all")?.text == "all", "literal all filename is preserved")
        let pdf = parse("Find my PDFs in Downloads from last week containing invoice")!
        expect(pdf.kind == .documents && pdf.fileExtension == "pdf", "PDF is an exact extension")
        expect(pdf.folder == "Downloads" && pdf.text == "invoice", "folder and filename parse")
        let week = calendar.dateInterval(of: .weekOfYear, for: now)!
        expect(pdf.dates?.end == week.start, "last week ends at this week's start")
        let screenshot = parse("Screenshot from yesterday with Tinycast Dev")!
        expect(screenshot.kind == .images && screenshot.text == "Tinycast Dev", "OCR phrase preserved")
        let today = calendar.startOfDay(for: now)
        expect(screenshot.dates?.end == today, "yesterday ends at local midnight")
        expect(!screenshot.includes(timestamp: today.timeIntervalSince1970), "upper date bound excluded")
        expect(
            screenshot.includes(timestamp: screenshot.dates!.start.timeIntervalSince1970),
            "lower bound included")
        expect(parse("pdf guide.pdf") == nil, "ordinary filenames stay literal")
        expect(parse("images from tomorrow") == nil, "unknown date stays literal")
        expect(parse("screenshots from yesterday banana") == nil, "unconsumed words stay literal")
        expect(parse("\"screenshots from yesterday\"") == nil, "quoted phrase is not interpreted")
        expect(parse(String(repeating: "file ", count: 1000)) == nil, "input work is bounded")
        expect(
            parse("screenshots containing from yesterday")?.text == "from yesterday",
            "content is not parsed as a date")
        var pacific = calendar
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let dst = Date(timeIntervalSince1970: 1_773_014_400)
        let day = SearchDescription("images from yesterday", now: dst, calendar: pacific)!
        expect(day.dates?.end == pacific.startOfDay(for: dst), "local day uses the injected timezone")
    }

    static func weekdayDescriptions() {
        let friday = parse("HTML files from last week Friday")
        let start = calendar.date(from: DateComponents(year: 2027, month: 1, day: 1))!
        let end = calendar.date(from: DateComponents(year: 2027, month: 1, day: 2))!
        expect(friday?.fileExtension == "html" && friday?.text == "", "HTML needs no filename term")
        expect(friday?.dates == DateInterval(start: start, end: end), "weekday crosses the year boundary")
        for phrase in ["Friday last week", "Friday of last week", "last week on Friday", "last Fri"] {
            expect(parse("HTML files from \(phrase)") == friday, "equivalent weekday phrase: \(phrase)")
        }
        expect(parse("show all my .HTML files modified on last Friday") == friday, "format case and dot")
        expect(friday?.includes(timestamp: start.timeIntervalSince1970) == true, "weekday start included")
        expect(friday?.includes(timestamp: end.timeIntervalSince1970) == false, "weekday end excluded")
        for (format, ext) in [("CSV", "csv"), ("Markdown", "md"), ("JSON", "json"), ("PNG", "png")] {
            expect(parse("\(format) files from last week Friday")?.fileExtension == ext, "format \(format)")
        }
        let literal = parse("HTML files named last week Friday")
        expect(literal?.dates == nil && literal?.text == "last week Friday", "filename dates stay literal")
        expect(literal?.matchesFilenameOnly == true, "named bypasses Context Search")
        expect(parse("HTML files containing last week Friday")?.dates == nil, "content dates stay literal")
        for phrase in ["Friday", "next Friday", "last week Friday morning", "last week Friday yesterday",
            "last week Friday or Thursday", "before last Friday", "last week Fri tomorrow"] {
            expect(parse("HTML files from \(phrase)") == nil, "unsupported date stays literal: \(phrase)")
        }
        expect(parse("HTML files created last Friday") == nil, "creation is not modification")
        let filtered = parse("HTML files in Downloads from last week Friday containing invoice")
        expect(filtered?.dates == friday?.dates && filtered?.folder == "Downloads", "combined constraints")
        expect(filtered?.text == "invoice", "content term survives weekday constraints")
        let today = calendar.startOfDay(for: now)
        expect(parse("files from this Friday")?.dates?.start == today, "this Friday includes today")
        var sundayFirst = calendar
        sundayFirst.firstWeekday = 1
        let sunday = calendar.date(from: DateComponents(year: 2027, month: 1, day: 10, hour: 12))!
        let mondayWeek = SearchDescription("files from this Friday", now: sunday, calendar: calendar)
        let sundayWeek = SearchDescription("files from this Friday", now: sunday, calendar: sundayFirst)
        expect(mondayWeek?.dates?.start == today, "Monday week includes the preceding Friday")
        expect(
            sundayWeek?.dates?.start == calendar.date(byAdding: .day, value: 7, to: today),
            "Sunday week includes the following Friday")
        var pacific = calendar
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        for (month, day, hours) in [(3, 9, 23), (11, 2, 25)] {
            let date = pacific.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
            let result = SearchDescription("files from last week Sunday", now: date, calendar: pacific)
            expect(result?.dates?.duration == Double(hours * 3600), "DST day has \(hours) hours")
        }
    }

    static func weekdayFiles() throws {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "weekday-files-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = scratch.resolvingSymlinksInPath().appending(path: "home")
        let description = parse("HTML files in Downloads from last week Friday")!
        let dates = description.dates!
        for (name, date) in [
            ("Downloads/start.html", dates.start), ("Downloads/upper.HTML", dates.end.addingTimeInterval(-1)),
            ("Downloads/before.html", dates.start.addingTimeInterval(-1)), ("Downloads/end.html", dates.end),
            ("Downloads/wrong.htm", dates.start), ("Documents/outside.html", dates.start)
        ] {
            let path = root.appending(path: name)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("<p>invoice</p>".utf8).write(to: path)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path.path)
        }
        let policy = FileSearchPolicy(scopes: [root.path], ignorePatterns: [], homeDirectory: root)
        let roots = FileIndexCrawler.roots(of: policy)
        let listings = FileIndexCrawler.Crawl(roots: roots, policy: policy).run(workers: 1)
        let file = scratch.appending(path: "index.bin")
        try FileIndexSnapshot.write(listings, roots: roots, eventID: 0, fingerprint: policy.fingerprint, to: file)
        let index = FileIndex()
        index.replace(with: FileIndexSnapshot(contentsOf: file), policy: policy)
        expect(
            Set(index.search(description: description, filter: .all).map(\.name)) == ["start.html", "upper.HTML"],
            "HTML, folder and weekday boundaries intersect in the index")
        expect(index.search(description: description, filter: .images).isEmpty, "dropdown still narrows HTML")
        let live = root.appending(path: "Downloads/live.html")
        try Data().write(to: live)
        try FileManager.default.setAttributes([.modificationDate: dates.start], ofItemAtPath: live.path)
        let downloads = index.snapshot!.roots[0] + "/Downloads"
        index.apply(folder: downloads)
        expect(index.search(description: description, filter: .all).count == 3, "live files use weekday filters")
        try FileManager.default.setAttributes([.modificationDate: dates.end], ofItemAtPath: live.path)
        index.apply(folder: downloads)
        expect(index.search(description: description, filter: .all).count == 2, "live date changes leave the range")
    }

    static func files() async throws {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "description-files-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = scratch.resolvingSymlinksInPath().appending(path: "home")
        let yesterday = parse("files from yesterday")!.dates!.start.addingTimeInterval(100)
        for (name, date) in [
            ("Downloads/invoice.pdf", yesterday), ("Downloads/invoice.txt", yesterday),
            ("Documents/invoice.pdf", yesterday), ("Downloads/new.pdf", now),
            ("Downloads/notinvoice.pdf", yesterday)
        ] {
            let path = root.appending(path: name)
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: path)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path.path)
        }
        for offset in 0..<250 {
            let path = root.appending(path: "Downloads/recent-\(offset).pdf")
            try Data().write(to: path)
            try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: path.path)
        }
        let policy = FileSearchPolicy(scopes: [root.path], ignorePatterns: [], homeDirectory: root)
        let roots = FileIndexCrawler.roots(of: policy)
        let listings = FileIndexCrawler.Crawl(roots: roots, policy: policy).run(workers: 1)
        let file = scratch.appending(path: "index.bin")
        try FileIndexSnapshot.write(
            listings, roots: roots, eventID: 0, fingerprint: policy.fingerprint, to: file)
        let index = FileIndex()
        index.replace(with: FileIndexSnapshot(contentsOf: file), policy: policy)
        let alias = root.appending(path: "Downloads/invoice.pdf").path
        let indexed = index.snapshot!.roots[0] + "/Downloads/invoice.pdf"
        let contentMatches = await index.documentContentMatches(
            paths: [alias, indexed], description: nil, filter: .all, fingerprint: policy.fingerprint)
        expect(contentMatches.map(\.name) == ["invoice.pdf"], "content aliases resolve to one indexed file")
        let query = parse("PDFs in Downloads from yesterday named invoice")!
        let matches = index.search(description: query, filter: .all)
        expect(
            Set(matches.map(\.name)) == ["invoice.pdf", "notinvoice.pdf"],
            "filename, exact type, folder and dates intersect")
        expect(index.search(description: query, filter: .images).isEmpty, "explicit filter still narrows")
        expect(
            index.search(description: query, filter: .all, isCancelled: { true }).isEmpty,
            "cancellation returns no results")
        expect(
            index.search(description: parse("PDFs from yesterday named missing")!, filter: .all).isEmpty,
            "missing filename never becomes a date-only query")
        expect(
            index.search(description: parse("files in Downloads from yesterday")!, filter: .all).count == 3,
            "metadata-only search works before limiting results")
        let added = root.appending(path: "Downloads/live-invoice.pdf")
        try Data().write(to: added)
        try FileManager.default.setAttributes([.modificationDate: yesterday], ofItemAtPath: added.path)
        let downloads = index.snapshot!.roots[0] + "/Downloads"
        index.apply(folder: downloads)
        expect(index.search(description: query, filter: .all).count == 3, "live additions obey descriptions")
        try FileManager.default.removeItem(at: root.appending(path: "Downloads/invoice.pdf"))
        index.apply(folder: downloads)
        expect(
            index.search(description: query, filter: .all).count == 2,
            "deleted snapshot entries stay excluded")
        try await fileSession(index, yesterday: query.dates!)
        try await contextSearchProgress(index, path: root.appending(path: "Downloads/new.pdf").path,
                                        fingerprint: policy.fingerprint)
        let nested = root.appending(path: "Downloads/Invoices/nested.pdf")
        try FileManager.default.createDirectory(
            at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: nested)
        let narrow = FileSearchPolicy(
            scopes: [nested.deletingLastPathComponent().path], ignorePatterns: [], homeDirectory: root)
        let narrowRoots = FileIndexCrawler.roots(of: narrow)
        let narrowListings = FileIndexCrawler.Crawl(roots: narrowRoots, policy: narrow).run(workers: 1)
        let narrowFile = scratch.appending(path: "narrow.bin")
        try FileIndexSnapshot.write(
            narrowListings, roots: narrowRoots, eventID: 0, fingerprint: narrow.fingerprint, to: narrowFile)
        index.replace(with: FileIndexSnapshot(contentsOf: narrowFile), policy: narrow)
        expect(
            index.search(description: parse("PDFs in Downloads")!, filter: .all).map(\.name) == [
                "nested.pdf"
            ],
            "a scope inside the described folder is included")
    }

    static func fileSession(_ index: FileIndex, yesterday: DateInterval) async throws {
        let session = FileSearchSession(index: index)
        let query = "pull up the old paperwork"
        let description = SearchDescription(
            kind: .documents, text: "unmatched", alternativeTexts: ["invoice"],
            fileExtension: "pdf", folder: "Downloads", dates: yesterday)
        session.search(query, filter: .images)
        session.applyDescription(description, for: query, filter: .images)
        try await waitForFiles(session)
        expect(session.results.isEmpty, "interpretation retains the active file filter")

        session.search(query, filter: .documents)
        try await waitForFiles(session)
        expect(
            Set(session.results.map(\.name)) == ["live-invoice.pdf", "notinvoice.pdf"],
            "filter changes keep the interpreted alternatives and metadata constraints")
        session.refresh()
        try await waitForFiles(session)
        expect(session.results.count == 2, "refresh keeps the interpreted file request")

        session.clearDescription(resumingSearch: true)
        try await waitForFiles(session)
        expect(session.results.isEmpty, "clearing the interpretation restores literal file search")
        session.applyDescription(description, for: query, filter: .documents)
        session.search("new")
        session.applyDescription(description, for: query, filter: .all)
        try await waitForFiles(session)
        expect(session.results.contains { $0.name == "new.pdf" }, "old interpretation leaves the new query alone")
        session.search(query)
        try await waitForFiles(session)
        expect(session.results.isEmpty, "returning to old text searches literally")

        guard case .filters(let filters) = SearchFileQuery.parse(
            "PDFs in Downloads", now: now, calendar: calendar)
        else { fatalError("Expected structured file filters") }
        session.applyDescription(SearchDescription(fileConstraints: filters), for: query, filter: .all)
        try await waitForFiles(session)
        expect(session.filters == filters && !session.results.isEmpty, "interpreted filters reach the file index")
        session.clearDescription(resumingSearch: true)
        try await waitForFiles(session)
        expect(session.filters == nil && session.results.isEmpty, "clearing removes interpreted filter chips")
        session.search("PDFs in Downloads")
        session.applyDescription(description, for: "PDFs in Downloads", filter: .all)
        try await waitForFiles(session)
        expect(session.filters == filters, "model results cannot replace an explicit structured query")
    }

    static func waitForFiles(_ session: FileSearchSession) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while session.state != .ready, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        expect(session.state == .ready, "file search completes")
    }

    static func contextSearchProgress(_ index: FileIndex, path: String, fingerprint: UInt64) async throws {
        let (gate, continuation) = AsyncStream<Void>.makeStream()
        let session = FileSearchSession(index: index, documentPaths: { _, _ in
            for await _ in gate {}
            return [path]
        })
        session.setDocumentContentScope(fingerprint)
        session.search("invoice")
        try await waitForFiles(session)
        expect(!session.results.isEmpty && session.isFetching, "filename matches show while Context Search is running")
        continuation.finish()
        let deadline = ContinuousClock.now + .seconds(2)
        while session.isFetching, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        expect(!session.isFetching, "progress ends after Context Search finishes")
        expect(session.results.contains { $0.name == "new.pdf" }, "Context Search appends its result")
    }

    static func clipboard() async throws {
        let scratch = FileManager.default.temporaryDirectory.appending(
            path: "description-clipboard-\(UUID())")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = ClipboardStore(
            directory: scratch,
            describeQuery: { query in
                guard let description = parse(query) else { return nil }
                let kind: ClipboardItem.Kind
                switch description.kind {
                case .images: kind = .image
                case .files: kind = .file
                case .text, .links: kind = .text
                default: return nil
                }
                return ClipboardStore.DescriptionQuery(
                    text: description.text, kind: kind, dates: description.dates,
                    linksOnly: description.kind == .links, website: description.website)
            })
        defer { store.close() }
        store.maxAge = ClipboardRetention.forever.maxAge
        _ = store.setTextSearchEnabled(true)
        let yesterday = parse("screenshots from yesterday")!.dates!.start.addingTimeInterval(100)
        let target = ClipboardItem(
            imagePath: "/fixture/target.png", createdAt: yesterday, sourceBundleID: nil)
        let today = ClipboardItem(imagePath: "/fixture/today.png", createdAt: now, sourceBundleID: nil)
        let boundary = ClipboardItem(
            imagePath: "/fixture/boundary.png", createdAt: calendar.startOfDay(for: now), sourceBundleID: nil)
        let entries =
            [target, today, boundary]
            + (0..<300).map {
                ClipboardItem(imagePath: "/fixture/new-\($0).png", createdAt: now, sourceBundleID: nil)
            }
        _ = ClipboardStore.importStoredItems(inDatabaseAt: store.dbURL, entries)
        for entry in entries {
            expect(
                store.setExtractedText(
                    "Tinycast Dev 105 MB", for: entry, generation: store.extractionGeneration),
                "OCR metadata stored")
        }
        let query = "screenshots from yesterday containing Tinycast Dev"
        let result = await settled(store, query)
        expect(
            result.map(\.id) == [target.id],
            "date filters apply before the result cap, including OCR-only rows")
        let filtered = await settled(store, query, filter: .text)
        expect(filtered.isEmpty, "clipboard filter intersects the description")
        let metadata = await settled(store, "screenshots from yesterday")
        expect(metadata.map(\.id) == [target.id], "metadata-only search reaches stored images")
        _ = store.setTextSearchEnabled(false)
        let disabled = await settled(store, query)
        expect(disabled.isEmpty, "disabled OCR does not expose recognized text")
        let withoutOCR = await settled(store, "screenshots from yesterday")
        expect(withoutOCR.map(\.id) == [target.id], "dates work with OCR disabled")
        let text = ClipboardItem(
            id: UUID(), kind: .text, text: "meeting notes", imagePath: nil, createdAt: yesterday,
            sourceBundleID: nil)
        let file = ClipboardItem(filePath: "/fixture/invoice.pdf", createdAt: yesterday, sourceBundleID: nil)
        _ = ClipboardStore.importStoredItems(inDatabaseAt: store.dbURL, [text, file])
        let texts = await settled(store, "text from yesterday containing meeting notes")
        expect(texts.map(\.id) == [text.id], "ordinary copied text works without OCR")
        let files = await settled(store, "files named invoice")
        expect(files.map(\.id) == [file.id], "copied file path matches description")
        let invalid = await settled(store, "text containing \" OR 1=1 --")
        expect(invalid.isEmpty, "query content cannot become SQL or an FTS expression")
        _ = store.search("screenshots from today", filter: .all)
        let latest = await settled(store, query)
        expect(latest.isEmpty, "cancelled query cannot publish stale matches")
        let links = [
            "https://www.flaticon.com/free-icon/example",
            "https://flaticon.com/free-icon/second",
            "https://example.com/?next=flaticon.com",
            "https://someflaticon.example.com/icon",
            "Notes about flaticon.com",
            "https://github.com/example/project"
        ].map { value in
            ClipboardItem(
                id: UUID(), kind: .text, text: value, imagePath: nil, createdAt: yesterday,
                sourceBundleID: nil)
        }
        _ = ClipboardStore.importStoredItems(inDatabaseAt: store.dbURL, links)
        let matching = await settled(store, "links from flaticon")
        expect(
            Set(matching.map(\.id)) == Set(links.prefix(2).map(\.id)), "brand matches URL hosts only")
        let domain = await settled(store, "links from flaticon.com from yesterday")
        expect(Set(domain.map(\.id)) == Set(links.prefix(2).map(\.id)), "domain and date combine")
        let narrowed = await settled(store, "links from flaticon containing second", filter: .link)
        expect(narrowed.map(\.id) == [links[1].id], "website, URL text and dropdown combine")
        let none = await settled(store, "links from flaticon", filter: .image)
        expect(none.isEmpty, "image dropdown excludes links")

        store.load()
        let plural = "links from flaticons"
        expect(parse(plural)?.website == "flaticons", "local parser accepts the unresolved website")
        let uncorrected = await settled(store, plural)
        expect(uncorrected.isEmpty, "unresolved website has no copied links")
        let interpreted = SearchIntentPolicy.intent(
            destination: .clipboard, query: plural, kind: "links", website: "flaticons",
            time: nil, websites: store.knownWebsiteHosts, now: now, calendar: calendar)?.description
        if let interpreted {
            store.setInterpretedQuery(
                .init(
                    text: interpreted.text, kind: .text, dates: interpreted.dates,
                    linksOnly: interpreted.kind == .links, website: interpreted.website),
                for: plural)
            let corrected = await settled(store, plural)
            expect(
                Set(corrected.map(\.id)) == Set(links.prefix(2).map(\.id)),
                "interpreted website takes precedence over the local parser")
            let edited = await settled(store, plural + " ")
            expect(edited.isEmpty, "editing the raw query drops the interpreted website")
        } else {
            expect(false, "interpreted clipboard website resolves against stored hosts")
        }

        store.setTextSearchActive(false)
        expect(
            store.search("screenshots from yesterday", filter: .all).isEmpty,
            "inactive search releases results")
    }

    static func settled(
        _ store: ClipboardStore, _ query: String, filter: ClipboardFilter = .all
    ) async -> [ClipboardItem] {
        var published = false
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        store.onSearchResultsChanged = { queryPublished, _, _ in published = queryPublished == trimmed }
        defer { store.onSearchResultsChanged = nil }
        _ = store.search(query, filter: filter)
        let deadline = ContinuousClock.now + .seconds(2)
        while !published, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        expect(published, "clipboard search completes for \(query)")
        return store.search(query, filter: filter)
    }

    static func interpretedClipboard() async throws {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "intent-clipboard-\(UUID())")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = ClipboardStore(directory: scratch)
        defer { store.close() }
        let yesterday = parse("text from yesterday")!.dates!
        let timestamp = yesterday.start.addingTimeInterval(100)
        func copied(_ value: String, at date: Date? = nil) -> ClipboardItem {
            ClipboardItem(
                id: UUID(), kind: .text, text: value, imagePath: nil, createdAt: date ?? timestamp,
                sourceBundleID: nil)
        }
        let literal = copied("bring back what I copied")
        let note = copied("Tax receipt")
        let file = ClipboardItem(filePath: "/fixture/Invoice.pdf", createdAt: timestamp, sourceBundleID: nil)
        let image = ClipboardItem(imagePath: "/fixture/bill.png", createdAt: timestamp, sourceBundleID: nil)
        let movie = ClipboardItem(filePath: "/fixture/clip.mov", createdAt: timestamp, sourceBundleID: nil)
        let domains = [
            copied("https://www.flaticon.com/icons/example"),
            copied("https://cdn.assets.flaticon.com/second"),
            copied("https://notflaticon.com/lookalike"),
            copied("https://flaticon.com.example.org/lookalike"),
            copied("https://example.org/?next=flaticon.com"),
            copied("Notes about flaticon.com")
        ]
        let later = copied("Invoice", at: yesterday.end)
        let items = [literal, note, file, image, movie, later] + domains
        expect(
            ClipboardStore.importStoredItems(inDatabaseAt: store.dbURL, items) == items.count,
            "interpreted clipboard fixtures imported")
        expect(store.setTextSearchEnabled(true), "recognized text search enabled")
        expect(
            store.setExtractedText("TX statement", for: image, generation: store.extractionGeneration),
            "recognized text stored for the alternative")

        let query = literal.text!
        expect(
            store.search(query, filter: .all).map(\.id) == [literal.id],
            "literal results appear before interpretation")
        store.setInterpretedQuery(
            .init(text: "invoice", kind: nil, dates: yesterday, alternativeTexts: ["receipt", "statement"]),
            for: query)
        let fts = await settled(store, query)
        expect(
            Set(fts.map(\.id)) == [note.id, file.id, image.id],
            "FTS searches alternatives across ordinary and OCR rows")

        store.setInterpretedQuery(
            .init(text: "receipt", kind: nil, dates: yesterday, alternativeTexts: ["tx"]), for: query)
        let short = await settled(store, query)
        expect(Set(short.map(\.id)) == [note.id, image.id], "short alternatives use the substring search")
        let images = await settled(store, query, filter: .image)
        expect(images.map(\.id) == [image.id], "dropdown narrows an interpretation with no kind")

        store.recordExtractionFailure(
            for: image, generation: store.extractionGeneration, retryAt: now.addingTimeInterval(30))
        expect(store.nextExtractionRetry(version: 1) == nil, "completed OCR does not poll for unavailable captions")
        expect(store.nextExtractionRetry(version: 2) != nil, "partial visual analysis retains its retry")
        expect(
            store.setExtractedText(
                "TX statement\nA red car parked beside a beach", for: image,
                generation: store.extractionGeneration, version: 2),
            "existing OCR can be upgraded with a visual description")
        let visualQuery = "the photo with a red car beside a beach"
        store.setInterpretedQuery(.init(text: "a red car beside a beach", kind: .image, dates: nil), for: visualQuery)
        let visual = await settled(store, visualQuery)
        expect(visual.map(\.id) == [image.id], "caption terms match without requiring contiguous wording")
        expect(image.text == nil, "generated descriptions never replace clipboard content")
        store.setTextSearchEnabled(false)
        let disabledVisual = await settled(store, visualQuery)
        expect(disabledVisual.isEmpty, "disabled image search cannot return a saved visual match")
        store.setTextSearchEnabled(true)

        expect(
            store.setExtractedText(
                "A purple balloon floating above a lake", for: movie,
                generation: store.extractionGeneration, version: 2),
            "saved video caption is indexed")
        expect(
            store.setExtractedText("Purple balloon above a lake", for: file, generation: store.extractionGeneration),
            "copied PDF fixture has the same words")
        let videoQuery = "the video I copied showing a purple balloon"
        store.setInterpretedQuery(
            .init(text: "purple balloon", kind: .file, dates: yesterday, videosOnly: true), for: videoQuery)
        let video = await settled(store, videoQuery)
        expect(video.map(\.id) == [movie.id], "described videos exclude copied PDFs with matching text")

        let siteQuery = "that site with icons"
        store.setInterpretedQuery(
            .init(text: "", kind: nil, dates: nil, linksOnly: true, website: "flaticon.com"),
            for: siteQuery)
        let site = await settled(store, siteQuery)
        expect(
            Set(site.map(\.id)) == Set(domains.prefix(2).map(\.id)),
            "website matches the exact host and subdomains")
        expect(
            store.search(query, filter: .all).map(\.id) == [literal.id],
            "interpretation is tied to its own query")

        store.setInterpretedQuery(.init(text: "invoice", kind: nil, dates: nil), for: query)
        _ = store.search(query, filter: .all)
        store.setInterpretedQuery(nil, for: query)
        let cleared = await settled(store, query)
        expect(cleared.map(\.id) == [literal.id], "clearing a pending interpretation restores literal results")
    }

    static func dates() {
        func dates(_ range: SearchIntent.DateRange, _ start: String = "", _ end: String = "") -> DateInterval? {
            SearchIntent.dates(range, start: start, end: end, now: now, calendar: calendar)
        }
        let valid = dates(.specific, "2026-10-01", "2026-11-01")
        expect(valid != nil, "specific dates validate")
        expect(dates(.specific, "2026-02-30", "2026-03-02") == nil, "invalid dates rejected")
        expect(dates(.specific, "2026-11-02", "2026-11-01") == nil, "reversed dates rejected")
        expect(
            dates(.lastWeek)?.end == calendar.dateInterval(of: .weekOfYear, for: now)?.start,
            "previous week boundary")
    }

    static func imageContent() throws {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "image-content-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let canonicalPath = realpath(scratch.path, nil)!
        defer { free(canonicalPath) }
        let root = URL(fileURLWithPath: String(cString: canonicalPath), isDirectory: true)
        let dates = parse("images from yesterday")!.dates!
        func media(_ path: String, modified: Date) throws -> URL {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("media fixture".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            return url
        }
        let source = try media("Downloads/IMG_001.png", modified: dates.start)
        let movie = try media("Downloads/VID_001.mov", modified: dates.start)
        let later = try media("Downloads/IMG_002.png", modified: dates.end)
        let otherFolder = try media("Pictures/IMG_003.png", modified: dates.start)
        let ignored = try media("Downloads/ignored.png", modified: dates.start)
        let otherScope = try media("Downloads/IMG_004.png", modified: dates.start)
        let store = ImageContentStore(url: root.appending(path: "content.sqlite3"))
        expect(store.prepare(), "image content schema opens")
        let fingerprint = ImageContentStore.Fingerprint(url: source)!
        let movieFingerprint = ImageContentStore.Fingerprint(url: movie)!
        let policy = FileSearchPolicy(scopes: [root.path], ignorePatterns: ["ignored.png"], homeDirectory: root)
        let scope = String(policy.fingerprint)
        let content = ImageContent(text: "Payment failed", caption: "A red car parked beside a beach")
        for url in [source, movie, later, otherFolder, ignored, otherScope] {
            store.save(
                content, path: url.path, scope: url == otherScope ? "other-scope" : scope,
                fingerprint: ImageContentStore.Fingerprint(url: url)!, version: 2, now: now)
        }
        expect(
            !store.needsExtraction(path: source.path, scope: scope, fingerprint: fingerprint, version: 2, now: now),
            "unchanged images reuse saved descriptions")
        let reopened = ImageContentStore(url: store.url)
        func storedMatches(_ query: String, in cacheScope: String) -> Set<String> {
            Set(reopened.search(
                text: query, scope: cacheScope, dates: nil, limit: 100,
                accepts: { _, _ in true }, isCancelled: { false }))
        }
        expect(
            storedMatches("cars payment", in: scope).contains(source.path),
            "a new store connection finds saved caption and OCR terms together")
        expect(storedMatches("red car", in: "other-scope") == [otherScope.path], "cache rows stay scoped")
        let roots = FileIndexCrawler.roots(of: policy)
        let crawl = FileIndexCrawler.Crawl(roots: roots, policy: policy).run(workers: 1)
        let snapshot = root.appending(path: "index.bin")
        try FileIndexSnapshot.write(crawl, roots: roots, eventID: 0, fingerprint: policy.fingerprint, to: snapshot)
        let index = FileIndex()
        index.replace(with: FileIndexSnapshot(contentsOf: snapshot), policy: policy)
        index.setImageContentURL(store.url)
        func matches(
            _ query: String, description: SearchDescription? = nil, filter: FileSearchFilter = .all
        ) -> Set<String> {
            Set(index.imageContentMatches(
                query: query, description: description, filter: filter, isCancelled: { false }).map(\.id))
        }
        let visibleMedia: Set<String> = [source.path, movie.path, later.path, otherFolder.path]
        expect(matches("red car beach") == visibleMedia, "caption matches respect index membership and cache scope")
        expect(matches("payment failed") == visibleMedia, "OCR and captions share retrieval")
        expect(matches("blue car").isEmpty, "a mismatched color is not discarded")
        expect(matches("red car", filter: .documents).isEmpty, "media results respect the document filter")
        expect(matches("red car", filter: .video) == [movie.path], "video filter admits only videos")
        expect(
            matches("red car", filter: .images) == [source.path, later.path, otherFolder.path],
            "image filter admits only images")
        let description = SearchDescription(
            kind: .any, text: "red car", folder: "Downloads", dates: dates)
        expect(
            matches("ignored raw query", description: description) == [source.path, movie.path],
            "interpreted text intersects the folder and half-open date interval")
        let imageOnly = SearchDescription(kind: .images, text: "red car", fileExtension: "png")
        expect(
            matches("red car", description: imageOnly, filter: .video).isEmpty,
            "described image type intersects the video filter")
        let movieOnly = SearchDescription(kind: .video, text: "red car", fileExtension: "mov")
        expect(matches("red car", description: movieOnly) == [movie.path], "interpreted videos keep the exact format")
        expect(
            index.imageContentMatches(query: "red car", description: nil, filter: .all, isCancelled: { true }).isEmpty,
            "cancelled content searches return nothing")
        let batch = index.imageBatch(after: 0)
        expect(
            Set(batch.paths) == visibleMedia.union([otherScope.path]) && batch.complete,
            "bounded indexing visits scoped image and video files")
        index.setImageContentURL(nil)
        expect(matches("red car").isEmpty, "disabled media search does not consult saved descriptions")
        index.setImageContentURL(store.url)
        let changed = dates.start.addingTimeInterval(60)
        try FileManager.default.setAttributes([.modificationDate: changed], ofItemAtPath: source.path)
        expect(!matches("red car").contains(source.path), "same-size files with new timestamps reject old descriptions")
        let changedFingerprint = ImageContentStore.Fingerprint(url: source)!
        expect(
            store.needsExtraction(path: source.path, scope: scope, fingerprint: changedFingerprint, version: 2, now: now),
            "changed files are eligible for extraction again")
        store.save(
            ImageContent(text: "", caption: "A green mountain"), path: source.path, scope: scope,
            fingerprint: changedFingerprint, version: 2, now: now)
        expect(matches("green mountain") == [source.path], "reindexing publishes the new caption")
        expect(!matches("red car").contains(source.path), "reindexing removes the old caption terms")
        try Data("changed image with a different byte count".utf8).write(to: source)
        try FileManager.default.setAttributes([.modificationDate: changed], ofItemAtPath: source.path)
        expect(matches("green mountain").isEmpty, "size changes reject descriptions at the same timestamp")

        try FileManager.default.removeItem(at: movie)
        expect(!matches("payment failed").contains(movie.path), "deleted videos never return a cached match")
        expect(store.prune(scope: scope, accepts: index.containsImagePath), "pruning reports removed records")
        expect(
            store.needsExtraction(path: movie.path, scope: scope, fingerprint: movieFingerprint, version: 2, now: now),
            "pruning removes deleted media")
        expect(
            store.needsExtraction(path: source.path, scope: scope, fingerprint: changedFingerprint, version: 2, now: now),
            "pruning removes stale metadata for changed files")
        expect(
            storedMatches("red car", in: scope) == [later.path, otherFolder.path],
            "pruning keeps only matching indexed files")
        expect(storedMatches("red car", in: "other-scope").isEmpty, "pruning removes previous scope metadata")
        let databaseFiles = ["", "-wal", "-shm"].map { store.url.path + $0 }
        for sidecar in databaseFiles.dropFirst() {
            try Data().write(to: URL(fileURLWithPath: sidecar))
        }
        expect(store.purge(), "purging the media database succeeds")
        expect(
            databaseFiles.allSatisfy { !FileManager.default.fileExists(atPath: $0) },
            "purging deletes the media database and its sidecars")
        expect(FileManager.default.fileExists(atPath: later.path), "purging preserves original media files")
        expect(storedMatches("red car", in: scope).isEmpty, "purged captions are unavailable")
    }

    static func intentPolicy() {
        func interpret(
            _ query: String, _ destination: SearchIntent.Destination, kind: String,
            website: String? = nil, time: String? = nil,
            websites: [String] = ["flaticon.com", "github.com"], fileDateEvent: SearchIntent.FileDateEvent? = nil
        ) -> SearchDescription? {
            SearchIntentPolicy.intent(
                destination: destination, query: query, kind: kind, website: website,
                time: time, websites: websites, now: now, calendar: calendar, fileDateEvent: fileDateEvent)?.description
        }

        for phrase in ["last week Friday", "Friday last week", "Friday of last week", "last Friday"] {
            let query = "HTML files from \(phrase)"
            let result = interpret(query, .files, kind: "files", time: "last week")
            expect(
                result?.dates == parse(query)?.dates && result?.fileExtension == "html",
                "model and direct parser agree: \(phrase)")
        }
        for phrase in ["last week Fri tomorrow", "last week Friday morning", "before the last Friday"] {
            expect(
                interpret("HTML files from \(phrase)", .files, kind: "documents") == nil,
                "model cannot discard unsupported time: \(phrase)")
        }
        expect(
            interpret("Markdown files from yesterday", .files, kind: "documents")?.fileExtension == "md",
            "model and direct parser share formats")
        let allPDFs = interpret("all pdf from last week", .files, kind: "documents", time: "last week")
        expect(allPDFs?.fileExtension == "pdf" && allPDFs?.text == "", "model validation drops all qualifier")
        expect(allPDFs?.dates == parse("pdf from last week")?.dates, "model validation keeps week dates")
        expect(interpret("PDFs named all", .files, kind: "documents")?.text == "all", "model keeps literal all")
        let site = interpret("links from flaticons", .clipboard, kind: "links", time: "today")
        expect(site?.kind == .links && site?.website == "flaticon.com", "known host resolves a one-edit site name")
        expect(site?.text == "" && site?.dates == nil, "consumed terms and invented dates are dropped")
        for query in ["links from flaticons", "show me the URLs I copied from flaticons"] {
            expect(SearchIntentPolicy.isDirectClipboardLinkQuery(query), "explicit clipboard link query: \(query)")
            expect(
                interpret(query, .clipboard, kind: "links")?.website == "flaticon.com",
                "local clipboard search resolves the known host")
        }
        for query in [
            "open links from github", "links not from github", "PDF invoices from github", "look up links I copied",
        ] {
            expect(!SearchIntentPolicy.isDirectClipboardLinkQuery(query), "other queries keep their routing: \(query)")
        }

        let explicitSite = interpret(
            "links from https://www.flaticon.com/icons", .clipboard, kind: "links", website: "github.com")
        expect(explicitSite?.website == "flaticon.com", "explicit URL host wins over the proposed website")

        let invoices = interpret(
            "PDF invoices I modified last week", .files, kind: "documents", website: "PDF",
            time: "last week")
        expect(
            invoices?.kind == .documents && invoices?.fileExtension == "pdf" && invoices?.website == nil,
            "explicit PDF format is retained when the model proposes it as a website")
        expect(
            invoices?.folder == nil && invoices?.text == "invoices",
            "file topic is preserved without inventing a location")
        expect(invoices?.alternativeTexts.contains("invoice") == true, "a singular filename alternative is included")
        let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start
        expect(invoices?.dates?.end == startOfWeek, "last week uses the supplied calendar")

        let screenshot = interpret(
            "find the screenshot showing memory usage", .clipboard, kind: "images", website: "example.org",
            time: "screenshot")
        expect(
            screenshot?.kind == .images && screenshot?.text == "memory usage"
                && screenshot?.website == nil && screenshot?.dates == nil,
            "screenshot content is kept without invented constraints")
        expect(screenshot?.alternativeTexts.isEmpty == true, "OCR matching retains all requested content words")
        let yesterdayText = interpret(
            "text containing yesterday", .clipboard, kind: "text", time: "yesterday")
        expect(
            yesterdayText?.text == "yesterday" && yesterdayText?.dates == nil,
            "a date word can be literal content")
        expect(
            interpret("PDFs from two months ago", .files, kind: "documents", time: "two months ago") == nil,
            "an unsupported date does not silently broaden file results")
        expect(
            interpret("PDF invoices from two months ago", .files, kind: "documents") == nil,
            "an omitted model time cannot erase an unsupported date")
        expect(
            interpret("PDF invoices Acme 2025", .files, kind: "documents")?.text
                == "invoices Acme 2025",
            "topic extraction retains the company and filename year")
        expect(
            interpret("PDF invoices Acme 2025", .files, kind: "documents", time: "2025")?.text
                == "invoices Acme 2025",
            "a model-proposed filename year remains literal")
        expect(
            interpret("PDF invoices from 2025", .files, kind: "documents") == nil,
            "a year introduced as a date cannot become a filename keyword")
        for event in ["downloaded", "created", "opened", "received"] {
            expect(
                interpret("PDF invoices I \(event) last week", .files, kind: "documents") == nil,
                "unsupported file event \(event) cannot use modification dates")
        }
        let downloads = interpret(
            "html files I downloaded last week", .files, kind: "files", time: "last week", fileDateEvent: .downloaded)
        expect(
            downloads?.fileConstraints?.downloaded?.end == startOfWeek && downloads?.fileExtension == "html"
                && downloads?.dates == nil && downloads?.folder == nil && downloads?.text == "",
            "download intent retains the format and uses a distinct date without inventing a folder")
        let inverted = interpret(
            "Last week, which HTML files did I download?", .files, kind: "files", time: "last week",
            fileDateEvent: .downloaded)
        expect(inverted == downloads, "a grounded date can precede its event")
        let fronted = interpret(
            "Downloaded HTML files last week", .files, kind: "files", time: "last week", fileDateEvent: .downloaded)
        expect(fronted == downloads, "an event before the file type still resolves through the model policy")
        let mixed = interpret(
            "HTML reports I downloaded last week containing \"balance\"", .files, kind: "files",
            time: "last week", fileDateEvent: .downloaded)
        expect(
            mixed?.fileConstraints?.name == "reports" && mixed?.fileConstraints?.content == ["balance"],
            "download searches keep name and content distinct")
        expect(
            interpret("HTML files I opened last week", .files, kind: "files", fileDateEvent: .downloaded) == nil,
            "the proposed event must match the request")
        for exclusion in ["not in Downloads", "except Downloads", "without Acme"] {
            expect(
                interpret("PDF invoices \(exclusion)", .files, kind: "documents") == nil,
                "unsupported exclusion stays literal: \(exclusion)")
        }
        let title = interpret(
            "PDFs named \"report last week\"", .files, kind: "documents", time: "last week")
        expect(title?.text == "report last week" && title?.dates == nil, "quoted title dates stay literal")
        expect(
            interpret("text containing not my project", .clipboard, kind: "text")?.text
                == "not my project",
            "literal content preserves negation and filler words")
        expect(
            interpret("PDF invoices in Downloads", .files, kind: "documents")?.folder
                == "Downloads",
            "an explicitly named folder still filters")
        expect(!SearchIntentPolicy.allowsInterpretation("don't close the window"), "negated actions stay literal")
        let commands = [
            SearchIntent.Command(id: "first", title: "Close Window"),
            SearchIntent.Command(id: "second", title: "close window"),
            SearchIntent.Command(id: "search", title: "Search Files"),
        ]
        expect(
            SearchIntentPolicy.unambiguousCommands(commands).map(\.id) == ["search"],
            "duplicate command titles cannot resolve to the first match")
    }
}
