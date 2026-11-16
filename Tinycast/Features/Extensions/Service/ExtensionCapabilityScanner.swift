import Foundation

/// Reads every bundled script, `node_modules` included, since a package can reach a built-in too.
enum ExtensionCapabilityScanner {
    /// A file past this is minified vendor code that never names a built-in its bundle didn't.
    private static let largestScannedFile = 16 * 1024 * 1024

    nonisolated static func scan(directory: URL) -> Set<ExtensionCapability> {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard
            let files = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return [] }
        var found: Set<ExtensionCapability> = []
        for case let file as URL in files {
            guard ["js", "cjs", "mjs"].contains(file.pathExtension),
                let values = try? file.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true, (values.fileSize ?? 0) <= largestScannedFile,
                let source = try? String(contentsOf: file, encoding: .utf8)
            else { continue }
            found.formUnion(ExtensionCapability.found(in: source))
            if found.count == ExtensionCapability.allCases.count { break }
        }
        return found
    }
}
