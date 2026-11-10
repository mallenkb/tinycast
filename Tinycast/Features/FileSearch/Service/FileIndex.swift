import Foundation
import Synchronization
import UniformTypeIdentifiers

final class FileIndex: Sendable {
    /// Past this many changes since the snapshot, a rebuild is cheaper than carrying them.
    static let rebuildThreshold = 100_000
    static let addedRebuildThreshold = 8_192

    private struct Added: Sendable {
        let name: String
        let isDirectory: Bool
        let mtime: UInt32
        let prior: Int8
        let mask: UInt64

        var isRecent: Bool { prior == 2 && !isDirectory }
    }

    private struct State: Sendable {
        var snapshot: FileIndexSnapshot?
        var policy: FileSearchPolicy?
        var dead: [UInt64] = []
        var deadCount = 0
        var added: [String: Added] = [:]
        var addedChildren: [String: Set<String>] = [:]
        var recentRevision = 0

        var changeCount: Int { deadCount + added.count }

        func isDead(_ index: Int) -> Bool { dead[index >> 6] & (1 << UInt64(index & 63)) != 0 }

        mutating func kill(_ index: Int, in snapshot: FileIndexSnapshot) {
            markDead(index, in: snapshot)
            guard snapshot.isDirectory(index) else { return }
            for descendant in snapshot.subtree(of: index) { markDead(descendant, in: snapshot) }
        }

        private mutating func markDead(_ index: Int, in snapshot: FileIndexSnapshot) {
            let bit: UInt64 = 1 << UInt64(index & 63)
            guard dead[index >> 6] & bit == 0 else { return }
            dead[index >> 6] |= bit
            deadCount += 1
            if snapshot.prior[index] == 2, !snapshot.isDirectory(index) { recentRevision &+= 1 }
        }

        mutating func add(_ path: String, _ child: FileIndexCrawler.Child) {
            var name = child.name
            let mask = name.withUTF8(FileSearchQuery.nameMask)
            let entry = Added(
                name: child.name, isDirectory: child.isDirectory, mtime: child.mtime,
                prior: child.prior, mask: mask)
            added[path] = entry
            addedChildren[parentPath(of: path), default: []].insert(child.name)
            if entry.isRecent { recentRevision &+= 1 }
        }

        mutating func remove(_ path: String, isDirectory: Bool) {
            if let entry = added.removeValue(forKey: path) {
                let parent = parentPath(of: path)
                addedChildren[parent]?.remove(entry.name)
                if addedChildren[parent]?.isEmpty == true { addedChildren.removeValue(forKey: parent) }
                if entry.isRecent { recentRevision &+= 1 }
            }
            if isDirectory {
                let prefix = path == "/" ? "/" : path + "/"
                for key in added.keys.filter({ $0.hasPrefix(prefix) }) {
                    let entry = added.removeValue(forKey: key)
                    if entry?.isRecent == true { recentRevision &+= 1 }
                }
                for key in addedChildren.keys.filter({ $0 == path || $0.hasPrefix(prefix) }) {
                    addedChildren.removeValue(forKey: key)
                }
            }
            if added.isEmpty { added = [:] }
            if addedChildren.isEmpty { addedChildren = [:] }
        }
    }

    private let state = Mutex(State())
    private let lister = Mutex(FileIndexCrawler.Lister())
    private let imageContentURL = Mutex<URL?>(nil)

    func setImageContentURL(_ url: URL?) { imageContentURL.withLock { $0 = url } }

    func containsImagePath(_ path: String) -> Bool {
        state.withLock { state in
            if let entry = state.added[path] { return !entry.isDirectory }
            guard let snapshot = state.snapshot, let row = snapshot.lookup(path) else { return false }
            return !state.isDead(row) && !snapshot.isDirectory(row)
        }
    }

    func imageBatch(after cursor: Int) -> (paths: [String], next: Int, complete: Bool, scope: String) {
        let state = state.withLock { $0 }
        guard let snapshot = state.snapshot, let policy = state.policy else { return ([], 0, true, "") }
        var types = TypeFilter(filter: .images)
        var videos = TypeFilter(filter: .video)
        var paths: [String] = []
        let end = min(cursor + 2048, snapshot.entryCount)
        if cursor < end {
            for row in cursor..<end where row >= snapshot.rootCount && !state.isDead(row) {
                let matches = types.accepts(name: snapshot.name(row), isDirectory: snapshot.isDirectory(row))
                    || videos.accepts(name: snapshot.name(row), isDirectory: snapshot.isDirectory(row))
                if matches { paths.append(snapshot.path(of: row)) }
            }
        }
        let overlayStart = max(0, cursor - snapshot.entryCount)
        let overlayEnd = min(overlayStart + (2048 - max(0, end - cursor)), state.added.count)
        if end == snapshot.entryCount || cursor >= snapshot.entryCount {
            for (offset, element) in state.added.enumerated() where offset >= overlayStart && offset < overlayEnd {
                let (path, entry) = element
                var name = entry.name
                if name.withUTF8({
                    types.accepts(name: $0, isDirectory: entry.isDirectory)
                        || videos.accepts(name: $0, isDirectory: entry.isDirectory)
                }) { paths.append(path) }
            }
        }
        let next = max(end, min(cursor, snapshot.entryCount)) + overlayEnd
        return (paths, next, next >= snapshot.entryCount + state.added.count, String(policy.fingerprint))
    }

    func imageContentMatches(
        query: String, description: SearchDescription?, filter: FileSearchFilter,
        isCancelled: @Sendable () -> Bool
    ) -> [FileSearchResult] {
        guard description?.fileConstraints == nil,
            [.all, .images, .video].contains(filter),
            description.map({ [.any, .files, .images, .video].contains($0.kind) }) ?? true,
            let url = imageContentURL.withLock({ $0 })
        else { return [] }
        let state = state.withLock { $0 }
        guard let policy = state.policy else { return [] }
        let folder = FileIndexCrawler.withoutMaterializing {
            description?.folder.map { FileSearchMetadata.folder($0, home: policy.homeDirectory) }
        }
        let paths = ImageContentStore(url: url).search(
            text: description?.text ?? query, scope: String(policy.fingerprint), dates: description?.dates,
            limit: FileSearchQuery.resultLimit, accepts: { path, _ in
                let type = FileSearchFilter.contentType(extension: (path as NSString).pathExtension, isDirectory: false)
                let requested: FileSearchFilter = description?.kind == .images ? .images
                    : description?.kind == .video ? .video : .all
                guard type?.conforms(to: .image) == true || type?.conforms(to: .movie) == true,
                    filter.accepts(contentType: type, isDirectory: false),
                    requested.accepts(contentType: type, isDirectory: false),
                    folder.map({ path.hasPrefix($0 + "/") }) ?? true,
                    description?.fileExtension.map({ (path as NSString).pathExtension.lowercased() == $0 }) ?? true
                else { return false }
                if let added = state.added[path] { return !added.isDirectory }
                guard let snapshot = state.snapshot, let row = snapshot.lookup(path), !state.isDead(row),
                    !snapshot.isDirectory(row)
                else { return false }
                return true
            }, isCancelled: isCancelled)
        return paths.map {
            FileSearchResult(url: URL(fileURLWithPath: $0), isDirectory: false, homeDirectory: policy.homeDirectory)
        }
    }

    var snapshot: FileIndexSnapshot? { state.withLock { $0.snapshot } }

    func documentContentScopes(fingerprint: UInt64, folder: String? = nil) -> [String] {
        state.withLock { state in
            guard let snapshot = state.snapshot, snapshot.fingerprint == fingerprint else { return [] }
            if let folder, let policy = state.policy {
                let path = FileSearchMetadata.folder(folder, home: policy.homeDirectory)
                return snapshot.roots.compactMap { root in
                    if FileSearchScope.contains(root, path) { return path }
                    return FileSearchScope.contains(path, root) ? root : nil
                }
            }
            return snapshot.roots
        }
    }

    @concurrent
    func documentContentMatches(
        paths: [String], description: SearchDescription?, filter: FileSearchFilter, fingerprint: UInt64
    ) async -> [FileSearchResult] {
        let state = state.withLock { $0 }
        guard let snapshot = state.snapshot, snapshot.fingerprint == fingerprint, let policy = state.policy else {
            return []
        }
        if let constraints = description?.fileConstraints {
            return filteredSearch(constraints, filter: filter, contentPaths: paths, isCancelled: { Task.isCancelled })
        }
        let folder = description?.folder.map { name in
            let path = (policy.homeDirectory.path as NSString).appendingPathComponent(name)
            guard let resolved = realpath(path, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let kind = description?.kind ?? .any
        let describedFilter: FileSearchFilter = [.documents, .text].contains(kind) ? .documents : .all
        var ranked: [Ranked] = []
        let indexedPaths = FileIndexCrawler.withoutMaterializing {
            Set(paths.lazy.map { Self.indexedPath($0, state: state, snapshot: snapshot) })
        }
        for path in indexedPaths {
            guard !Task.isCancelled else { return [] }
            guard folder.map({ $0 != path && FileSearchScope.contains($0, path) }) ?? true else { continue }
            let timestamp: UInt32
            if let added = state.added[path] {
                guard !added.isDirectory else { continue }
                timestamp = added.mtime
            } else {
                guard let row = snapshot.lookup(path), !state.isDead(row), !snapshot.isDirectory(row) else { continue }
                timestamp = snapshot.mtime[row]
            }
            let ext = (path as NSString).pathExtension.lowercased()
            guard description?.includes(timestamp: Double(timestamp)) ?? true,
                description?.fileExtension.map({ $0 == ext }) ?? true
            else { continue }
            let type = FileSearchFilter.contentType(extension: ext, isDirectory: false)
            guard type?.conforms(to: .image) != true, type?.conforms(to: .movie) != true,
                filter.accepts(contentType: type, isDirectory: false),
                describedFilter.accepts(contentType: type, isDirectory: false)
            else { continue }
            ranked.append(Ranked(score: Int(timestamp), path: path, isDirectory: false))
        }
        return Self.results(ranked, limit: FileSearchQuery.resultLimit, policy: policy, matchesDocumentContent: true)
    }

    func filteredSearch(
        _ filters: SearchFileConstraints, filter: FileSearchFilter, contentPaths: [String]? = nil,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> [FileSearchResult] {
        let state = state.withLock { $0 }
        guard let snapshot = state.snapshot, let policy = state.policy,
            filters.content.isEmpty || contentPaths != nil else { return [] }
        return FileIndexCrawler.withoutMaterializing {
            let contentPaths = contentPaths.map { paths in
                Set(paths.lazy.map { Self.indexedPath($0, state: state, snapshot: snapshot) })
            }
            let folder = filters.folder.map { FileSearchMetadata.folder($0, home: policy.homeDirectory) }
            let category = FileSearchFilter(category: filters.category)
            struct Hit {
                let path: String
                let directory: Bool
                let modified: UInt32
                let added: Date?
                let size: Int64
                let name: String
                let relevance: Int
            }
            func precedes(_ left: Hit, _ right: Hit) -> Bool {
                switch filters.order {
                case .name:
                    let order = left.name.localizedStandardCompare(right.name)
                    if order != .orderedSame { return order == .orderedAscending }
                case .largest: if left.size != right.size { return left.size > right.size }
                case .smallest: if left.size != right.size { return left.size < right.size }
                case .oldest: if left.modified != right.modified { return left.modified < right.modified }
                case .newestAdded, .oldestAdded:
                    if let leftDate = left.added, let rightDate = right.added, leftDate != rightDate {
                        return filters.order == .newestAdded ? leftDate > rightDate : leftDate < rightDate
                    }
                case .relevance:
                    if left.relevance != right.relevance { return left.relevance > right.relevance }
                    if left.modified != right.modified { return left.modified > right.modified }
                case .newest: if left.modified != right.modified { return left.modified > right.modified }
                }
                return left.path < right.path
            }
            var hits: [Hit] = []
            var cutoff: Hit?
            var typeCache: [String: UTType] = [:]
            let limit = FileSearchQuery.resultLimit
            let term = filters.name.lowercased()
            let included = filters.extensions.map { Array(("." + $0).utf8) }
            let excluded = filters.excludedExtensions.map { Array(("." + $0).utf8) }
            let suffixes = included + excluded
            let longestSuffix = suffixes.map(\.count).max() ?? 0
            let asciiExtensions = suffixes.allSatisfy { $0.allSatisfy { $0 < 128 } }
            func matchesExtension(_ name: UnsafeBufferPointer<UInt8>, fallback: () -> String) -> Bool {
                guard !included.isEmpty || !excluded.isEmpty else { return true }
                guard asciiExtensions, !name.suffix(longestSuffix).contains(where: { $0 >= 128 }) else {
                    return filters.matchesExtension(fallback())
                }
                func hasSuffix(_ suffix: [UInt8]) -> Bool {
                    guard suffix.count <= name.count else { return false }
                    return FileSearchQuery.find(
                        suffix, in: UnsafeBufferPointer(rebasing: name.suffix(suffix.count))) == 0
                }
                return (included.isEmpty || included.contains(where: hasSuffix))
                    && !excluded.contains(where: hasSuffix)
            }
            func canBeatCutoff(
                modified: UInt32, relevance: Int?, name: String? = nil, size: Int64? = nil, added: Date? = nil
            ) -> Bool {
                guard let cutoff else { return true }
                switch filters.order {
                case .newest: return modified >= cutoff.modified
                case .oldest: return modified <= cutoff.modified
                case .newestAdded, .oldestAdded:
                    guard let added, let cutoffDate = cutoff.added else { return true }
                    return filters.order == .newestAdded ? added >= cutoffDate : added <= cutoffDate
                case .relevance:
                    guard let relevance else { return true }
                    if relevance != cutoff.relevance { return relevance > cutoff.relevance }
                    return modified >= cutoff.modified
                case .name:
                    guard let name else { return true }
                    return name.localizedStandardCompare(cutoff.name) != .orderedDescending
                case .largest: return size.map { $0 >= cutoff.size } ?? true
                case .smallest: return size.map { $0 <= cutoff.size } ?? true
                }
            }
            func consider(
                _ name: String, directory: Bool, modified: UInt32, formatMatched: Bool = false, path: () -> String
            ) {
                guard filters.matchesName(name), formatMatched || filters.matchesExtension(name),
                    filters.modified?.contains(Date(timeIntervalSince1970: Double(modified))) ?? true
                else { return }
                let relevance: Int
                if term.isEmpty {
                    relevance = 0
                } else {
                    let key = name.lowercased()
                    relevance = key == term ? 2 : key.hasPrefix(term) ? 1 : 0
                }
                guard canBeatCutoff(modified: modified, relevance: relevance, name: name) else { return }
                if directory, filters.category == .files || contentPaths != nil {
                    guard FileSearchFilter.contentType(extension: (name as NSString).pathExtension, isDirectory: true)?
                            .conforms(to: .package) == true else { return }
                }
                if filter != .all || category != .all {
                    let ext = (name as NSString).pathExtension.lowercased()
                    let type = directory ? FileSearchFilter.contentType(extension: ext, isDirectory: true)
                        : typeCache[ext] ?? FileSearchFilter.contentType(extension: ext, isDirectory: false)
                    if !directory, typeCache.count < 512 { typeCache[ext] = type }
                    guard filter.accepts(contentType: type, isDirectory: directory),
                        category.accepts(contentType: type, isDirectory: directory) else { return }
                }
                let path = path()
                if !filters.recursive, folder == nil,
                    !snapshot.roots.contains((path as NSString).deletingLastPathComponent) { return }
                guard contentPaths?.contains(path) ?? true,
                    FileSearchMetadata.acceptsPath(path, filters: filters, folder: folder, home: policy.homeDirectory)
                else { return }
                let metadata = FileSearchMetadata.read(path, attributes: filters.needsMetadata, tags: filters.needsTags)
                if let downloaded = filters.downloaded {
                    guard !directory, let date = FileSearchMetadata.downloadedDate(path), downloaded.contains(date)
                    else { return }
                }
                if let created = filters.created {
                    guard let date = metadata.created, created.contains(date) else { return }
                }
                if filters.needsMetadata {
                    guard let size = metadata.size,
                        filters.minimumSize.map({ size >= $0 }) ?? true,
                        filters.maximumSize.map({ size <= $0 }) ?? true else { return }
                    if directory, filters.minimumSize != nil || filters.maximumSize != nil
                        || filters.order == .largest || filters.order == .smallest { return }
                }
                if filters.needsTags {
                    guard let tags = metadata.tags, filters.matchesTags(tags) else { return }
                }
                let added = filters.needsAddedDate
                    ? FileSearchMetadata.addedDate(path) ?? Date(timeIntervalSince1970: Double(modified))
                    : nil
                if let bounds = filters.added {
                    guard let added, bounds.contains(added) else { return }
                }
                guard canBeatCutoff(
                    modified: modified, relevance: relevance, name: name, size: metadata.size, added: added
                ) else {
                    return
                }
                hits.append(Hit(path: path, directory: directory, modified: modified, added: added,
                                size: metadata.size ?? 0, name: name, relevance: relevance))
                if hits.count >= limit * 4 {
                    hits.sort(by: precedes)
                    hits.removeSubrange(limit...)
                    cutoff = hits.last
                }
            }
            if let contentPaths {
                for path in contentPaths {
                    if isCancelled() { return [] }
                    if let entry = state.added[path] {
                        consider(entry.name, directory: entry.isDirectory, modified: entry.mtime, path: { path })
                    } else if let row = snapshot.lookup(path), !state.isDead(row) {
                        consider(snapshot.nameString(row), directory: snapshot.isDirectory(row),
                                 modified: snapshot.mtime[row], path: { path })
                    }
                }
            } else {
                for row in snapshot.rootCount..<snapshot.entryCount {
                    if isCancelled() { return [] }
                    guard !state.isDead(row),
                        filters.modified?.contains(Date(timeIntervalSince1970: Double(snapshot.mtime[row]))) ?? true,
                        canBeatCutoff(modified: snapshot.mtime[row], relevance: term.isEmpty ? 0 : nil),
                        matchesExtension(snapshot.name(row), fallback: { snapshot.nameString(row) })
                    else { continue }
                    consider(snapshot.nameString(row), directory: snapshot.isDirectory(row), modified: snapshot.mtime[row],
                             formatMatched: true, path: { snapshot.path(of: row) })
                }
                for (path, entry) in state.added {
                    if isCancelled() { return [] }
                    consider(entry.name, directory: entry.isDirectory, modified: entry.mtime, path: { path })
                }
            }
            guard !isCancelled() else { return [] }
            return hits.sorted(by: precedes).prefix(limit).map {
                FileSearchResult(url: URL(filePath: $0.path), isDirectory: $0.directory,
                                 homeDirectory: policy.homeDirectory, matchesDocumentContent: contentPaths != nil)
            }
        }
    }

    var itemCount: Int {
        state.withLock { state in
            guard let snapshot = state.snapshot else { return 0 }
            return snapshot.entryCount - snapshot.rootCount - state.deadCount + state.added.count
        }
    }

    private static func indexedPath(_ path: String, state: State, snapshot: FileIndexSnapshot) -> String {
        guard state.added[path] == nil, snapshot.lookup(path) == nil else { return path }
        return FileSearchMetadata.filePath(path)
    }

    /// Moves only when a file Recent can list comes, goes or is saved.
    var recentRevision: Int { state.withLock { $0.recentRevision } }

    func replace(with snapshot: FileIndexSnapshot?, policy: FileSearchPolicy?) {
        let words = ((snapshot?.entryCount ?? 0) + 63) / 64
        state.withLock {
            $0 = State(snapshot: snapshot, policy: policy, dead: [UInt64](repeating: 0, count: words))
        }
    }

    func search(
        _ query: FileSearchQuery.Prepared, filter: FileSearchFilter,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> [FileSearchResult] {
        guard !isCancelled() else { return [] }
        let state = state.withLock { $0 }
        guard let snapshot = state.snapshot, let policy = state.policy else { return [] }
        guard let literal = searchNames(query, filter: filter, state: state, snapshot: snapshot, policy: policy,
                                        typo: false, isCancelled: isCancelled) else { return [] }
        guard literal.isEmpty, query.allowsTypo, !isCancelled() else { return literal }
        return searchNames(query, filter: filter, state: state, snapshot: snapshot, policy: policy,
                           typo: true, isCancelled: isCancelled) ?? []
    }

    private func searchNames(
        _ query: FileSearchQuery.Prepared, filter: FileSearchFilter, state: State, snapshot: FileIndexSnapshot,
        policy: FileSearchPolicy, typo: Bool, isCancelled: @Sendable () -> Bool
    ) -> [FileSearchResult]? {
        @Sendable func canMatch(_ mask: UInt64) -> Bool {
            if typo {
                return mask & FileSearchQuery.nonASCIIBit == 0 && (query.mask & ~mask).nonzeroBitCount <= 1
            }
            return mask & query.mask == query.mask
        }
        @Sendable func scoreName(_ name: UnsafeBufferPointer<UInt8>, _ mask: UInt64, _ prior: Int8) -> Int? {
            if typo { return FileSearchQuery.typoScore(query, name: name, prior: prior) }
            return FileSearchQuery.score(query, name: name, mask: mask, prior: prior)
        }
        let limit = FileSearchQuery.resultLimit
        let names = NameScores(count: snapshot.nameCount)
        Self.chunked(0..<snapshot.nameCount, alignment: 64) { range in
            for id in range {
                if id == range.lowerBound || id & 255 == 0, isCancelled() { return }
                let mask = snapshot.nameMask[id]
                guard canMatch(mask) else { continue }
                let score = scoreName(snapshot.name(id: id), mask, 0)
                if let score { names.set(id, score) }
            }
        }
        guard !isCancelled() else { return nil }
        let base =
            names.isEmpty
            ? []
            : Self.collect(snapshot, limit: limit) { range, top in
                var types = TypeFilter(filter: filter)
                for index in range {
                    if index == range.lowerBound || index & 255 == 0, isCancelled() { return }
                    let id = Int(snapshot.nameID[index])
                    guard let score = names.score(id), !state.isDead(index),
                        types.accepts(name: snapshot.name(id: id), isDirectory: snapshot.isDirectory(index))
                    else { continue }
                    top.insert(score + FileSearchQuery.priorWeight * Int(snapshot.prior[index]), index)
                }
            }
        guard !isCancelled() else { return nil }
        var ranked = base.map { hit in
            Ranked(
                score: hit.score, path: snapshot.path(of: hit.index),
                isDirectory: snapshot.isDirectory(hit.index))
        }
        var types = TypeFilter(filter: filter)
        for (path, entry) in state.added where canMatch(entry.mask) {
            guard !isCancelled() else { return nil }
            var name = entry.name
            let score = name.withUTF8 { name -> Int? in
                guard
                    let score = scoreName(name, entry.mask, entry.prior),
                    types.accepts(name: name, isDirectory: entry.isDirectory)
                else { return nil }
                return score
            }
            guard let score else { continue }
            ranked.append(Ranked(score: score, path: path, isDirectory: entry.isDirectory))
        }
        guard !isCancelled() else { return nil }
        return Self.results(ranked, limit: limit, policy: policy)
    }

    func search(
        description: SearchDescription, filter: FileSearchFilter,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> [FileSearchResult] {
        if let constraints = description.fileConstraints {
            return filteredSearch(constraints, filter: filter, isCancelled: isCancelled)
        }
        let state = state.withLock { $0 }
        guard let snapshot = state.snapshot, let policy = state.policy else { return [] }
        let describedFilter: FileSearchFilter
        switch description.kind {
        case .any, .files: describedFilter = .all
        case .folders: describedFilter = .folders
        case .documents, .text: describedFilter = .documents
        case .images: describedFilter = .images
        case .audio: describedFilter = .audio
        case .video: describedFilter = .video
        case .archives: describedFilter = .archives
        case .links: return []
        }
        let folderPath = description.folder.map { folder in
            let path = (policy.homeDirectory.path as NSString).appendingPathComponent(folder)
            guard let resolved = realpath(path, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let folderRanges = folderPath.map { path -> [Range<Int>] in
            if let index = snapshot.lookup(path) { return [snapshot.subtree(of: index)] }
            return snapshot.roots.enumerated().compactMap { root, rootPath in
                rootPath.hasPrefix(path + "/") ? snapshot.subtree(of: root) : nil
            }
        }
        let queries = ([description.text] + description.alternativeTexts).compactMap(FileSearchQuery.prepare)
        let suffix = description.fileExtension.map { Array(("." + $0).utf8) }
        let base = Self.collect(snapshot, limit: FileSearchQuery.resultLimit) { range, top in
            var types = TypeFilter(filter: filter)
            var describedTypes = TypeFilter(filter: describedFilter)
            for index in range {
                if index == range.lowerBound || index & 255 == 0, isCancelled() { return }
                guard !state.isDead(index),
                    description.includes(timestamp: Double(snapshot.mtime[index])),
                    folderRanges?.contains(where: { $0.contains(index) }) ?? true
                else { continue }
                let name = snapshot.name(index)
                let directory = snapshot.isDirectory(index)
                guard description.kind != .files || !directory,
                    types.accepts(name: name, isDirectory: directory),
                    describedTypes.accepts(name: name, isDirectory: directory)
                else { continue }
                if let suffix {
                    guard name.count >= suffix.count,
                        FileSearchQuery.find(suffix, in: UnsafeBufferPointer(rebasing: name.suffix(suffix.count))) == 0
                    else { continue }
                }
                let score: Int?
                if !queries.isEmpty {
                    var best: Int?
                    for query in queries {
                        if let match = FileSearchQuery.score(
                            query, name: name, mask: snapshot.nameMask[Int(snapshot.nameID[index])],
                            prior: snapshot.prior[index])
                        { best = max(best ?? match, match) }
                    }
                    score = best
                } else {
                    score = Int(snapshot.mtime[index])
                }
                if let score { top.insert(score, index) }
            }
        }
        guard !isCancelled() else { return [] }
        var ranked = base.map {
            Ranked(score: $0.score, path: snapshot.path(of: $0.index), isDirectory: snapshot.isDirectory($0.index))
        }
        var types = TypeFilter(filter: filter)
        var describedTypes = TypeFilter(filter: describedFilter)
        for (path, entry) in state.added {
            guard !isCancelled() else { return [] }
            guard description.includes(timestamp: Double(entry.mtime)),
                folderPath.map({ path.hasPrefix($0 + "/") }) ?? true,
                description.kind != .files || !entry.isDirectory
            else { continue }
            if let ext = description.fileExtension, (entry.name as NSString).pathExtension.lowercased() != ext { continue }
            var name = entry.name
            let score = name.withUTF8 { bytes -> Int? in
                guard types.accepts(name: bytes, isDirectory: entry.isDirectory),
                    describedTypes.accepts(name: bytes, isDirectory: entry.isDirectory)
                else { return nil }
                guard !queries.isEmpty else { return Int(entry.mtime) }
                var best: Int?
                for query in queries {
                    if let match = FileSearchQuery.score(query, name: bytes, mask: entry.mask, prior: entry.prior) {
                        best = max(best ?? match, match)
                    }
                }
                return best
            }
            if let score { ranked.append(Ranked(score: score, path: path, isDirectory: entry.isDirectory)) }
            if ranked.count >= FileSearchQuery.resultLimit * 2 {
                ranked.sort { $0.score > $1.score }
                ranked.removeLast(ranked.count - FileSearchQuery.resultLimit)
            }
        }
        return isCancelled() ? [] : Self.results(ranked, limit: FileSearchQuery.resultLimit, policy: policy)
    }

    func recent(
        filter: FileSearchFilter, isCancelled: @Sendable () -> Bool = { false }
    ) -> [FileSearchResult] {
        guard !isCancelled() else { return [] }
        let state = state.withLock { $0 }
        guard let snapshot = state.snapshot, let policy = state.policy else { return [] }
        let limit = FileSearchQuery.recentLimit
        let base = Self.collect(snapshot, limit: limit) { range, top in
            var types = TypeFilter(filter: filter)
            for index in range {
                if index == range.lowerBound || index & 255 == 0, isCancelled() { return }
                guard snapshot.prior[index] == 2, !snapshot.isDirectory(index) else { continue }
                guard !state.isDead(index),
                    types.accepts(name: snapshot.name(index), isDirectory: false)
                else { continue }
                top.insert(Int(snapshot.mtime[index]), index)
            }
        }
        guard !isCancelled() else { return [] }
        var ranked = base.map { hit in
            Ranked(score: hit.score, path: snapshot.path(of: hit.index), isDirectory: false)
        }
        var types = TypeFilter(filter: filter)
        for (path, entry) in state.added where entry.isRecent {
            guard !isCancelled() else { return [] }
            var name = entry.name
            guard name.withUTF8({ types.accepts(name: $0, isDirectory: false) }) else { continue }
            ranked.append(Ranked(score: Int(entry.mtime), path: path, isDirectory: false))
        }
        guard !isCancelled() else { return [] }
        return Self.results(ranked, limit: limit, policy: policy)
    }

    private struct Ranked {
        let score: Int
        let path: String
        let isDirectory: Bool
    }

    private static func results(
        _ ranked: [Ranked], limit: Int, policy: FileSearchPolicy, matchesDocumentContent: Bool = false
    ) -> [FileSearchResult] {
        ranked.sorted { left, right in
            if left.score != right.score { return left.score > right.score }
            if left.path.count != right.path.count { return left.path.count < right.path.count }
            return left.path < right.path
        }
        .prefix(limit)
        .map { hit in
            FileSearchResult(
                url: URL(filePath: hit.path, directoryHint: hit.isDirectory ? .isDirectory : .notDirectory),
                isDirectory: hit.isDirectory, homeDirectory: policy.homeDirectory,
                matchesDocumentContent: matchesDocumentContent)
        }
    }

    /// Only the overall best come back, so no more paths are built than can be shown.
    private static func collect(
        _ snapshot: FileIndexSnapshot, limit: Int,
        _ scan: @Sendable (Range<Int>, inout TopHits) -> Void
    ) -> [TopHits.Hit] {
        let gathered = Gathered()
        chunked(snapshot.rootCount..<snapshot.entryCount) { range in
            var top = TopHits(limit: limit)
            scan(range, &top)
            gathered.append(top.best)
        }
        let hits = gathered.hits.sorted { left, right in
            left.score != right.score ? left.score > right.score : left.index < right.index
        }
        return Array(hits.prefix(limit))
    }

    /// Splits `range` across the cores; `alignment` keeps chunks off each other's bitset words.
    private static func chunked(
        _ range: Range<Int>, alignment: Int = 1, _ body: @Sendable (Range<Int>) -> Void
    ) {
        let chunks = max(1, min(ProcessInfo.processInfo.activeProcessorCount, range.count / 32_768))
        let size = ((range.count + chunks - 1) / chunks + alignment - 1) / alignment * alignment
        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
            let lower = range.lowerBound + chunk * size
            let upper = min(range.upperBound, lower + size)
            if lower < upper { body(lower..<upper) }
        }
    }

    /// Idempotent, so a replayed or duplicate event is harmless; true asks for a rebuild.
    @discardableResult
    func apply(folder path: String, recursive: Bool = false) -> Bool {
        guard let (snapshot, changes) = diff(folder: path, recursive: recursive) else { return false }
        return state.withLock { state in
            // A rebuild landed meanwhile; it replays this event from its own start.
            guard state.snapshot === snapshot else { return false }
            for index in changes.kills { state.kill(index, in: snapshot) }
            for removal in changes.removals { state.remove(removal.path, isDirectory: removal.isDirectory) }
            for (childPath, child) in changes.additions { state.add(childPath, child) }
            return state.changeCount > Self.rebuildThreshold || state.added.count > Self.addedRebuildThreshold
        }
    }

    /// Its copy of the state dies on return, so `apply` writes the overlay without copying it.
    private func diff(
        folder path: String, recursive: Bool
    ) -> (FileIndexSnapshot, FolderDiff.Changes)? {
        let current = state.withLock { $0 }
        guard let snapshot = current.snapshot, let policy = current.policy else { return nil }
        let overlay = current.added[path]
        let base =
            overlay == nil
            ? snapshot.lookup(path).flatMap { index in
                snapshot.isDirectory(index) && !current.isDead(index) ? index : nil
            } : nil
        guard
            let prior = overlay?.isDirectory == true ? overlay?.prior : base.map({ snapshot.prior[$0] })
        else { return nil }

        var diff = FolderDiff(folder: path, state: current, snapshot: snapshot, policy: policy)
        let listed = lister.withLock { lister in
            recursive
                ? diff.rescan(base: base, prior: prior, using: lister)
                : diff.compare(base: base, prior: prior, using: lister)
        }
        guard listed, !diff.changes.isEmpty else { return nil }
        return (snapshot, diff.changes)
    }

    /// One folder's changes. A row that did not change costs a `memcmp` and allocates nothing.
    private struct FolderDiff {
        struct Changes {
            var kills: [Int] = []
            var removals: [(path: String, isDirectory: Bool)] = []
            var additions: [(String, FileIndexCrawler.Child)] = []

            var isEmpty: Bool { kills.isEmpty && removals.isEmpty && additions.isEmpty }
        }

        let folder: String
        let state: State
        let snapshot: FileIndexSnapshot
        let policy: FileSearchPolicy
        private(set) var changes = Changes()
        /// Walked once the listing is released, since walking reuses the same lister.
        private var newFolders: [(path: String, prior: Int8)] = []

        init(folder: String, state: State, snapshot: FileIndexSnapshot, policy: FileSearchPolicy) {
            self.folder = folder
            self.state = state
            self.snapshot = snapshot
            self.policy = policy
        }

        /// Both sides are sorted by name bytes, so one merge pass finds every difference.
        mutating func compare(base: Int?, prior: Int8, using lister: FileIndexCrawler.Lister) -> Bool {
            let overlayNames = state.addedChildren[folder] ?? []
            let listed: Void? = lister.list(folder, prior: prior, policy: policy) { entries, order, name in
                let rows = base.map(snapshot.children(of:)) ?? 0..<0
                var row = rows.lowerBound
                var overlaySeen = 0
                for position in order {
                    let entry = entries[position]
                    let entryName = name(entry)
                    while row < rows.upperBound, FileIndexCrawler.compare(snapshot.name(row), entryName) < 0 {
                        killIfAlive(row)
                        row += 1
                    }
                    if row < rows.upperBound, FileIndexCrawler.compare(snapshot.name(row), entryName) == 0 {
                        let matched = row
                        row += 1
                        if !state.isDead(matched) {
                            if hasChanged(matched, to: entry) {
                                kill(matched)
                                add(entry, named: String(decoding: entryName, as: UTF8.self))
                            }
                            continue
                        }
                    }
                    let text = String(decoding: entryName, as: UTF8.self)
                    guard overlayNames.contains(text) else {
                        add(entry, named: text)
                        continue
                    }
                    overlaySeen += 1
                    update(text, to: entry)
                }
                while row < rows.upperBound {
                    killIfAlive(row)
                    row += 1
                }
                guard overlaySeen < overlayNames.count else { return }
                let onDisk = Set(order.map { String(decoding: name(entries[$0]), as: UTF8.self) })
                for gone in overlayNames where !onDisk.contains(gone) { removeAdded(gone) }
            }
            guard listed != nil else { return false }
            walkNewFolders(using: lister)
            return true
        }

        /// For an event that lost its detail: everything beneath the folder is listed afresh.
        mutating func rescan(base: Int?, prior: Int8, using lister: FileIndexCrawler.Lister) -> Bool {
            if let base {
                for row in snapshot.children(of: base) { killIfAlive(row) }
            }
            for name in state.addedChildren[folder] ?? [] { removeAdded(name) }
            let listed: Void? = lister.list(folder, prior: prior, policy: policy) { entries, _, name in
                for entry in entries { add(entry, named: String(decoding: name(entry), as: UTF8.self)) }
            }
            guard listed != nil else { return false }
            walkNewFolders(using: lister)
            return true
        }

        private func hasChanged(_ row: Int, to entry: FileIndexCrawler.Entry) -> Bool {
            if snapshot.isDirectory(row) != entry.isDirectory { return true }
            return snapshot.mtime[row] != entry.mtime
        }

        private mutating func update(_ name: String, to entry: FileIndexCrawler.Entry) {
            let path = FileIndexCrawler.path(folder, name)
            guard let added = state.added[path] else {
                add(entry, named: name)
                return
            }
            if added.isDirectory != entry.isDirectory {
                changes.removals.append((path, added.isDirectory))
                add(entry, named: name)
            } else if added.mtime != entry.mtime {
                add(entry, named: name)
            }
        }

        private mutating func killIfAlive(_ row: Int) {
            if !state.isDead(row) { kill(row) }
        }

        /// A vanished folder also takes whatever the overlay added beneath it.
        private mutating func kill(_ row: Int) {
            changes.kills.append(row)
            guard snapshot.isDirectory(row) else { return }
            changes.removals.append((FileIndexCrawler.path(folder, snapshot.nameString(row)), true))
        }

        private mutating func removeAdded(_ name: String) {
            let path = FileIndexCrawler.path(folder, name)
            if let index = state.added.index(forKey: path) {
                let existing = state.added[index]
                changes.removals.append((existing.key, existing.value.isDirectory))
            } else {
                changes.removals.append((path, false))
            }
        }

        private mutating func add(_ entry: FileIndexCrawler.Entry, named name: String) {
            let child = FileIndexCrawler.Child(entry, name: name, parent: folder, policy: policy)
            let path = FileIndexCrawler.path(folder, name)
            changes.additions.append((path, child))
            if child.isDirectory { newFolders.append((path, child.prior)) }
        }

        private mutating func walkNewFolders(using lister: FileIndexCrawler.Lister) {
            for (path, prior) in newFolders {
                changes.additions += lister.walk(path, prior: prior, policy: policy)
            }
            newFolders = []
        }
    }
}

private func parentPath(of path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return path }
    return slash == path.startIndex ? "/" : String(path[..<slash])
}

private struct TopHits {
    struct Hit: Sendable {
        let score: Int
        let index: Int
    }

    let limit: Int
    private var hits: [Hit] = []
    private var floor = Int.min

    init(limit: Int) { self.limit = limit }

    mutating func insert(_ score: Int, _ index: Int) {
        guard score > floor else { return }
        hits.append(Hit(score: score, index: index))
        guard hits.count >= limit * 4 else { return }
        hits.sort { $0.score > $1.score }
        hits.removeSubrange(limit...)
        floor = hits[limit - 1].score
    }

    var best: [Hit] { Array(hits.sorted { $0.score > $1.score }.prefix(limit)) }
}

/// Unchecked: each chunk writes only its own 64-aligned range of names.
private final class NameScores: @unchecked Sendable {
    private let matched: UnsafeMutableBufferPointer<UInt64>
    private let scores: UnsafeMutableBufferPointer<Int32>

    init(count: Int) {
        matched = .allocate(capacity: (count + 63) / 64)
        matched.initialize(repeating: 0)
        scores = .allocate(capacity: max(count, 1))
    }

    deinit {
        matched.deallocate()
        scores.deallocate()
    }

    var isEmpty: Bool { !matched.contains { $0 != 0 } }

    func set(_ id: Int, _ score: Int) {
        scores[id] = Int32(clamping: score)
        matched[id >> 6] |= 1 << UInt64(id & 63)
    }

    func score(_ id: Int) -> Int? {
        matched[id >> 6] & (1 << UInt64(id & 63)) != 0 ? Int(scores[id]) : nil
    }
}

private final class Gathered: Sendable {
    private let storage = Mutex<[TopHits.Hit]>([])

    func append(_ hits: [TopHits.Hit]) { storage.withLock { $0 += hits } }

    var hits: [TopHits.Hit] { storage.withLock { $0 } }
}

private struct TypeFilter {
    let filter: FileSearchFilter
    private var cache: [String: Bool] = [:]

    init(filter: FileSearchFilter) { self.filter = filter }

    mutating func accepts(name: UnsafeBufferPointer<UInt8>, isDirectory: Bool) -> Bool {
        guard filter != .all else { return true }
        if filter == .folders && !isDirectory { return false }
        var pathExtension = ""
        if let dot = name.lastIndex(of: 0x2E), dot > 0 {
            pathExtension = String(decoding: name[(dot + 1)...], as: UTF8.self).lowercased()
        }
        let key = isDirectory ? "/" + pathExtension : pathExtension
        if let known = cache[key] { return known }
        let type = FileSearchFilter.contentType(extension: pathExtension, isDirectory: isDirectory)
        let accepted = filter.accepts(contentType: type, isDirectory: isDirectory)
        cache[key] = accepted
        return accepted
    }
}
