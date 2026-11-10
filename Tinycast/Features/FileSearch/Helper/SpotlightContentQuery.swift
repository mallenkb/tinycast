import Foundation

@MainActor
enum SpotlightContentQuery {
    private static let candidateLimit = 2_000
    private static let timeout = Duration.seconds(1)

    static func paths(matching text: String, scopes: [String]) async -> [String] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 2_048, !Task.isCancelled else { return [] }
        return await paths(
            predicate: NSPredicate(format: "kMDItemTextContent CONTAINS[cd] %@", text), scopes: scopes)
    }

    static func paths(filters: SearchFileConstraints, scopes: [String]) async -> [String] {
        guard !filters.content.isEmpty else { return [] }
        let content = filters.content.map { NSPredicate(format: "kMDItemTextContent CONTAINS[cd] %@", $0) }
        var predicates: [NSPredicate] = [combine(content, any: filters.textMode == .any)]
        if !filters.extensions.isEmpty {
            predicates.append(
                combine(filters.extensions.map {
                    NSPredicate(format: "kMDItemFSName ENDSWITH[cd] %@", "." + $0)
                }, any: true))
        }
        for (key, bounds) in [
            ("kMDItemFSContentChangeDate", filters.modified), ("kMDItemFSCreationDate", filters.created)
        ] {
            if let start = bounds?.start {
                predicates.append(NSPredicate(format: "%K >= %@", key, start as NSDate))
            }
            if let end = bounds?.end { predicates.append(NSPredicate(format: "%K < %@", key, end as NSDate)) }
        }
        if let minimum = filters.minimumSize {
            predicates.append(NSPredicate(format: "kMDItemFSSize >= %@", NSNumber(value: minimum)))
        }
        if let maximum = filters.maximumSize {
            predicates.append(NSPredicate(format: "kMDItemFSSize <= %@", NSNumber(value: maximum)))
        }
        if !filters.name.isEmpty {
            let predicate: NSPredicate
            switch filters.nameMode {
            case .contains: predicate = NSPredicate(format: "kMDItemFSName CONTAINS[cd] %@", filters.name)
            case .exact: predicate = NSPredicate(format: "kMDItemFSName ==[cd] %@", filters.name)
            case .prefix: predicate = NSPredicate(format: "kMDItemFSName BEGINSWITH[cd] %@", filters.name)
            case .suffix: predicate = NSPredicate(format: "kMDItemFSName ENDSWITH[cd] %@", filters.name)
            }
            predicates.append(predicate)
        }
        if !filters.tags.isEmpty {
            let tags = filters.tags.map { NSPredicate(format: "kMDItemUserTags ==[cd] %@", $0) }
            predicates.append(combine(tags, any: !filters.allTags))
        }
        for tag in filters.excludedTags {
            predicates.append(
                NSCompoundPredicate(
                    notPredicateWithSubpredicate: NSPredicate(format: "kMDItemUserTags ==[cd] %@", tag)))
        }
        for ext in filters.excludedExtensions {
            predicates.append(
                NSCompoundPredicate(
                    notPredicateWithSubpredicate: NSPredicate(
                        format: "kMDItemFSName ENDSWITH[cd] %@", "." + ext)))
        }
        return await paths(
            predicate: combine(predicates, any: false),
            scopes: scopes, order: filters.order)
    }

    private static func combine(_ predicates: [NSPredicate], any: Bool) -> NSPredicate {
        precondition(!predicates.isEmpty)
        if predicates.count == 1 { return predicates[0] }
        return any ? NSCompoundPredicate(orPredicateWithSubpredicates: predicates)
            : NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
    }

    private static func paths(
        predicate: NSPredicate, scopes: [String], order: SearchFileConstraints.Order = .newest
    ) async -> [String] {
        guard !Task.isCancelled else { return [] }
        let directories = scopes.filter { $0.hasPrefix("/") }.map {
            URL(filePath: $0, directoryHint: .isDirectory)
        }
        guard !directories.isEmpty else { return [] }

        let query = NSMetadataQuery()
        query.searchScopes = directories
        query.predicate = predicate
        query.notificationBatchingInterval = 0.05
        switch order {
        case .largest, .smallest:
            query.sortDescriptors = [NSSortDescriptor(key: "kMDItemFSSize", ascending: order == .smallest)]
        case .name:
            query.sortDescriptors = [NSSortDescriptor(key: "kMDItemFSName", ascending: true)]
        case .newestAdded, .oldestAdded:
            query.sortDescriptors = [NSSortDescriptor(key: "kMDItemDateAdded", ascending: order == .oldestAdded)]
        default:
            query.sortDescriptors = [
                NSSortDescriptor(key: "kMDItemFSContentChangeDate", ascending: order == .oldest)
            ]
        }
        let (gathered, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let center = NotificationCenter.default
        let observer = center.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: query, queue: nil
        ) { _ in
            signal.yield(())
        }
        defer {
            center.removeObserver(observer)
            signal.finish()
        }
        guard query.start() else { return [] }
        defer { if !query.isStopped { query.stop() } }

        var finished = false
        let completion = Task {
            var iterator = gathered.makeAsyncIterator()
            _ = await iterator.next()
            finished = true
        }
        defer { completion.cancel() }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !finished, !Task.isCancelled, query.resultCount < candidateLimit, ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
        }
        query.stop()
        guard !Task.isCancelled else { return [] }

        var paths: [String] = []
        paths.reserveCapacity(min(query.resultCount, candidateLimit))
        query.enumerateResults { result, index, stop in
            if let item = result as? NSMetadataItem,
                let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
            {
                paths.append(path)
            }
            if index + 1 == candidateLimit { stop.pointee = true }
        }
        return paths
    }
}
