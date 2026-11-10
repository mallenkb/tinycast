import CoreServices
import Darwin
import Foundation

nonisolated enum FileSearchMetadata {
    struct Values {
        var created: Date?
        var size: Int64?
        var tags: [String]?
    }

    static func downloadedDate(_ path: String) -> Date? {
        guard getxattr(path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) > 0 else { return nil }
        return autoreleasepool {
            let values = try? URL(filePath: path).resourceValues(forKeys: [.quarantinePropertiesKey])
            return values?.quarantineProperties?[kLSQuarantineTimeStampKey as String] as? Date
        }
    }

    static func addedDate(_ path: String) -> Date? {
        autoreleasepool {
            try? URL(filePath: path).resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate
        }
    }

    static func read(_ path: String, attributes: Bool, tags: Bool) -> Values {
        var value = Values()
        if attributes {
            var info = stat()
            if lstat(path, &info) == 0 {
                value.created = Date(timeIntervalSince1970: Double(info.st_birthtimespec.tv_sec))
                value.size = info.st_size
            }
        }
        if tags {
            do {
                let resource = try URL(filePath: path).resourceValues(forKeys: [.tagNamesKey])
                value.tags = (resource.tagNames ?? []).map { String($0.split(separator: "\n").first ?? "") }
            } catch { value.tags = nil }
        }
        return value
    }

    static func folder(_ name: String, home: URL) -> String {
        let standard = ["Downloads", "Documents", "Desktop", "Pictures", "Movies", "Music"]
        var name = standard.first { $0.caseInsensitiveCompare(name) == .orderedSame } ?? name
        if name.lowercased().hasPrefix("my "),
            let alias = standard.first(where: { $0.caseInsensitiveCompare(String(name.dropFirst(3))) == .orderedSame }),
            !FileManager.default.fileExists(atPath: home.appending(path: name).path)
        {
            name = alias
        }
        let path: String
        if name == "~" {
            path = home.path
        } else if name.hasPrefix("~/") {
            path = home.appending(path: String(name.dropFirst(2))).path
        } else if name.hasPrefix("/") {
            path = name
        } else {
            path = home.appending(path: name).path
        }
        let standardized = URL(filePath: path).standardizedFileURL.path
        guard let resolved = realpath(standardized, nil) else { return standardized }
        defer { free(resolved) }
        let resolvedPath = String(cString: resolved)
        let values = try? URL(filePath: resolvedPath).resourceValues(forKeys: [.canonicalPathKey])
        return values?.canonicalPath ?? resolvedPath
    }

    static func filePath(_ path: String) -> String {
        let path = path as NSString
        guard let resolved = realpath(path.deletingLastPathComponent, nil) else { return path as String }
        defer { free(resolved) }
        let parent = String(cString: resolved)
        return parent == "/" ? parent + path.lastPathComponent : parent + "/" + path.lastPathComponent
    }

    static func acceptsPath(
        _ path: String, filters: SearchFileConstraints, folder: String?, home: URL
    ) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        if let folder {
            guard
                filters.recursive
                    ? path != folder && FileSearchScope.contains(folder, path) : parent == folder
            else { return false }
        }
        return !filters.excludedFolders.contains { excluded in
            if excluded.hasPrefix("/") || excluded.hasPrefix("~") {
                return FileSearchScope.contains(Self.folder(excluded, home: home), path)
            }
            return parent.split(separator: "/").contains {
                $0.caseInsensitiveCompare(excluded) == .orderedSame
            }
        }
    }
}

extension FileSearchFilter {
    init(category: SearchFileConstraints.Category) {
        switch category {
        case .all, .files: self = .all
        case .folders: self = .folders
        case .documents: self = .documents
        case .spreadsheets: self = .spreadsheets
        case .presentations: self = .presentations
        case .images: self = .images
        case .audio: self = .audio
        case .video: self = .video
        case .archives: self = .archives
        case .code: self = .code
        case .applications: self = .applications
        case .fonts: self = .fonts
        }
    }

}
