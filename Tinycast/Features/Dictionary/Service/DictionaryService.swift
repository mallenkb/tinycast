import AppKit
import CoreServices
import Darwin

/// Looks a term up in the dictionaries enabled in Dictionary.app, entirely on this Mac.
enum DictionaryService {
    @MainActor static var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Dictionary")
    }

    struct Result: Sendable {
        let sources: [DictionaryEntry.Source]
        let entry: DictionaryEntry?
    }

    nonisolated static func lookup(
        _ term: String, preferredSourceID: String
    ) -> Result {
        if let records = DictionaryRecords.resolved {
            let result = records.lookup(
                term, preferredSourceID: preferredSourceID)
            guard result.entry == nil, !term.isEmpty else { return result }
            return Result(
                sources: result.sources,
                entry: plainText(for: term).map { DictionaryEntry(term: term, plainText: $0) })
        }
        let entry = term.isEmpty
            ? nil : plainText(for: term).map { DictionaryEntry(term: term, plainText: $0) }
        return Result(sources: [], entry: entry)
    }

    private nonisolated static func plainText(for term: String) -> String? {
        let range = CFRange(location: 0, length: term.utf16.count)
        guard let text = DCSCopyTextDefinition(nil, term as CFString, range)?.takeRetainedValue()
        else { return nil }
        let trimmed = (text as String).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Dictionary Services' record calls: what Dictionary.app reads, though no header declares them.
private struct DictionaryRecords: Sendable {
    private typealias ActiveDictionaries = @convention(c) () -> Unmanaged<CFArray>?
    private typealias CopyRecords =
        @convention(c) (
            DCSDictionary, CFString, UnsafeRawPointer?, UnsafeRawPointer?
        ) -> Unmanaged<CFArray>?
    private typealias Metadata = @convention(c) (DCSDictionary) -> Unmanaged<CFString>?
    private typealias CopyData = @convention(c) (CFTypeRef, CFIndex) -> Unmanaged<CFString>?

    /// `DCSRecordCopyData`'s XHTML version; the plain-text one is what the public API returns.
    private static let xhtml: CFIndex = 0

    private let activeDictionaries: ActiveDictionaries
    private let copyRecords: CopyRecords
    private let copyData: CopyData
    private let identifier: Metadata
    private let name: Metadata

    /// Looked up at run time: a macOS that drops a symbol loses the layout, not the launch.
    static let resolved: DictionaryRecords? = {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let active = dlsym(rtldDefault, "DCSGetActiveDictionaries"),
            let records = dlsym(rtldDefault, "DCSCopyRecordsForSearchString"),
            let data = dlsym(rtldDefault, "DCSRecordCopyData"),
            let identifier = dlsym(rtldDefault, "DCSDictionaryGetIdentifier"),
            let name = dlsym(rtldDefault, "DCSDictionaryGetName")
        else { return nil }
        return DictionaryRecords(
            activeDictionaries: unsafeBitCast(active, to: ActiveDictionaries.self),
            copyRecords: unsafeBitCast(records, to: CopyRecords.self),
            copyData: unsafeBitCast(data, to: CopyData.self),
            identifier: unsafeBitCast(identifier, to: Metadata.self),
            name: unsafeBitCast(name, to: Metadata.self))
    }()

    func lookup(
        _ term: String, preferredSourceID: String
    ) -> DictionaryService.Result {
        let dictionaries = activeDictionaries()?.takeUnretainedValue() as? [DCSDictionary] ?? []
        let named = dictionaries.compactMap { dictionary -> (DCSDictionary, DictionaryEntry.Source)? in
            guard let id = identifier(dictionary)?.takeUnretainedValue() as String?,
                let name = name(dictionary)?.takeUnretainedValue() as String?
            else { return nil }
            return (dictionary, DictionaryEntry.Source(id: id, name: name))
        }
        let sources = named.map { $0.1 }
        guard !term.isEmpty else { return DictionaryService.Result(sources: sources, entry: nil) }
        var ordered = named
        if let index = ordered.firstIndex(where: { $0.1.id == preferredSourceID }) {
            ordered.insert(ordered.remove(at: index), at: 0)
        }
        for (dictionary, source) in ordered {
            guard !Task.isCancelled else { break }
            if let entry = entry(for: term, dictionary: dictionary, source: source) {
                return DictionaryService.Result(sources: sources, entry: entry)
            }
        }
        return DictionaryService.Result(sources: sources, entry: nil)
    }

    private func entry(
        for term: String, dictionary: DCSDictionary, source: DictionaryEntry.Source
    ) -> DictionaryEntry? {
        let records = copyRecords(dictionary, term as CFString, nil, nil)?
            .takeRetainedValue() as? [CFTypeRef] ?? []
        var blocks: [DictionaryEntry.Block] = []
        for record in records {
            guard !Task.isCancelled else { return nil }
            autoreleasepool {
                if let markup = copyData(record, Self.xhtml)?.takeRetainedValue() as String? {
                    blocks.append(contentsOf: DictionaryMarkup.blocks(fromXHTML: markup))
                }
            }
        }
        if !blocks.isEmpty { return DictionaryEntry(term: term, blocks: blocks, source: source) }
        guard !Task.isCancelled,
            let text = DCSCopyTextDefinition(
                dictionary, term as CFString, CFRange(location: 0, length: term.utf16.count)
            )?.takeRetainedValue() as String?,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        var entry = DictionaryEntry(term: term, plainText: text)
        entry.source = source
        return entry
    }
}
