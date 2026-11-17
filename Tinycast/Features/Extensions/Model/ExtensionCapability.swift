import Foundation

/// A native power an extension's bundle reaches for, read from its JavaScript before it runs.
enum ExtensionCapability: String, CaseIterable, Sendable {
    case processes
    case signals
    case filesystem

    /// A quoted specifier is how esbuild's CommonJS output names a Node built-in it left external.
    private var markers: [String] {
        switch self {
        case .processes: Self.quoted(["child_process", "node:child_process"])
        case .signals: ["process.kill("]
        case .filesystem:
            Self.quoted(["fs", "node:fs", "fs/promises", "node:fs/promises", "fs-extra"])
        }
    }

    private static func quoted(_ names: [String]) -> [String] {
        names.flatMap { ["\"\($0)\"", "'\($0)'"] }
    }

    static func found(in source: String) -> Set<ExtensionCapability> {
        Set(allCases.filter { capability in capability.markers.contains { source.contains($0) } })
    }

    var summary: String {
        switch self {
        case .processes: String(localized: "Runs programs and shell commands on this Mac.")
        case .signals: String(localized: "Can stop other processes.")
        case .filesystem: String(localized: "Reads and writes files.")
        }
    }
}
