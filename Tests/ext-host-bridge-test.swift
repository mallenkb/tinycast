// The host bridge against a fake context: background gates, process consent and capability scans.

import AppKit
import Foundation

// The bridge's app collaborators; no check here reaches them, so they only have to link.
enum Paster {
    @discardableResult static func copyPlainText(_ text: String) -> Bool { true }
    static func pasteString(_ text: String, previousApp: NSRunningApplication?) {}
    static func postCommandV() {}
}

enum AppLauncher {
    static func showInFinder(_ url: URL) {}
}

enum Permissions {
    static func ensureAccessibility() -> Bool { false }
}

enum AccessibilityText {
    static func selection(in app: NSRunningApplication) -> String? { nil }
}

@MainActor
final class FakeContext: ExtensionHostContext {
    var activeExtensionName: String? = "fake"
    var activeLaunchType: ExtensionLaunchType = .userInitiated
    let storage: ExtensionStorage
    var pasteTarget: NSRunningApplication? { nil }
    var applicationURLs: [URL] { [] }
    var processesGranted = false
    var consentAnswer = false
    var consentQuestions = 0
    var onAsk: (() -> Void)?

    init(storage: ExtensionStorage) { self.storage = storage }

    func closeMainWindow(clearRootSearch: Bool) {}
    func reopenPalette() {}
    func popToRoot() {}
    func clearSearchBar() {}
    func openPreferences(scope: String) {}
    func updateCommandMetadata(subtitle: String?) {}
    func present(toast: ExtensionToast) -> Int { 0 }
    func update(toast id: Int, with toast: ExtensionToast) {}
    func hide(toast id: Int) {}
    func showHUD(_ text: String) {}
    func confirmAlert(_ alert: ExtensionAlert) async -> Bool { false }
    func openWithPicker(path: String) async {}
    func launch(
        command: String, extensionName: String?, arguments: [String: String],
        fallbackText: String?, launchType: ExtensionLaunchType, launchContext: [String: RenderValue]
    ) throws {}
    func launch(_ link: ExtensionDeepLink) throws {}

    func askProcessConsent() async -> Bool {
        consentQuestions += 1
        onAsk?()
        return consentAnswer
    }
}

@main
@MainActor
struct ExtensionHostBridgeTests {
    static var failures = 0
    static var passes = 0

    static func main() async {
        await backgroundReads()
        await processConsent()
        shimGate()
        capabilityScan()
        await grantStore()

        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
        print("\(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    static func makeBridge() -> (ExtensionHostBridge, FakeContext, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ext-host-bridge-\(UUID().uuidString)", isDirectory: true)
        let context = FakeContext(storage: ExtensionStorage(directory: directory))
        let bridge = ExtensionHostBridge()
        bridge.context = context
        return (bridge, context, directory)
    }

    static func refusal(
        _ bridge: ExtensionHostBridge, _ api: String, _ method: String
    ) async -> String? {
        do {
            _ = try await bridge.perform(api: api, method: method, arguments: [])
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func backgroundReads() async {
        print("\n# background reads")
        let (bridge, context, directory) = makeBridge()
        defer { try? FileManager.default.removeItem(at: directory) }
        context.activeLaunchType = .background
        for (api, method) in [
            ("clipboard", "readText"), ("clipboard", "read"),
            ("system", "selectedText"), ("system", "selectedFinderItems")
        ] {
            let message = await refusal(bridge, api, method)
            check(
                "\(api).\(method) is refused in the background",
                message?.contains("background refresh") == true)
        }

        context.activeLaunchType = .userInitiated
        let interactive = await refusal(bridge, "system", "selectedText")
        check(
            "an interactive selectedText reaches the permission check",
            interactive?.contains("Accessibility") == true)
    }

    static func processConsent() async {
        print("\n# process consent")
        let (bridge, context, directory) = makeBridge()
        defer { try? FileManager.default.removeItem(at: directory) }

        context.activeLaunchType = .background
        check("a background run without a grant is refused", await bridge.authorizeProcesses() == .deniedInBackground)
        check("a background run never asks", context.consentQuestions == 0)

        context.activeLaunchType = .userInitiated
        context.consentAnswer = false
        check("a declined question denies", await bridge.authorizeProcesses() == .denied)
        check("an interactive run asks", context.consentQuestions == 1)

        context.consentAnswer = true
        check("an accepted question allows", await bridge.authorizeProcesses() == .allowed)

        context.onAsk = { context.activeExtensionName = "other" }
        check("an answer for a session that moved on denies", await bridge.authorizeProcesses() == .denied)
        context.onAsk = nil
        context.activeExtensionName = "fake"

        context.processesGranted = true
        context.activeLaunchType = .background
        let before = context.consentQuestions
        check("a grant allows a background run", await bridge.authorizeProcesses() == .allowed)
        check("a grant asks nothing", context.consentQuestions == before)

        bridge.context = nil
        check("no context denies", await bridge.authorizeProcesses() == .denied)
    }

    static func shimGate() {
        print("\n# node shim gate")
        nonisolated(unsafe) var asked = 0
        nonisolated(unsafe) var answer = ExtensionProcessAccess.deniedInBackground
        let shims = ExtensionNodeShims(authorizeProcesses: {
            asked += 1
            return answer
        })
        let run = #"[{"command":"/usr/bin/true","args":[]}]"#
        shims.beginSession()
        let spawn = envelope(shims.perform(api: "proc", method: "run", argsJSON: run))
        check("a refused spawn fails with EPERM", spawn?["code"] as? String == "EPERM")
        let kill = envelope(shims.perform(api: "proc", method: "kill", argsJSON: "[999999, 0]"))
        check("a refused kill fails with EPERM", kill?["code"] as? String == "EPERM")
        check("a background refusal is asked again", asked == 2)

        answer = .denied
        _ = shims.perform(api: "proc", method: "run", argsJSON: run)
        _ = shims.perform(api: "proc", method: "run", argsJSON: run)
        check("a user's refusal stands for the session", asked == 3)

        answer = .allowed
        shims.beginSession()
        let allowed = envelope(shims.perform(api: "proc", method: "run", argsJSON: run))
        check("an allowed spawn runs", allowed?["ok"] as? Bool == true)
        _ = shims.perform(api: "proc", method: "run", argsJSON: run)
        check("an allowance is asked once per session", asked == 4)
        let uptime = envelope(shims.perform(api: "os", method: "uptime", argsJSON: "[]"))
        check("other modules never ask", uptime?["ok"] as? Bool == true && asked == 4)
    }

    static func capabilityScan() {
        print("\n# capability scan")
        check(
            "child_process is a process capability",
            ExtensionCapability.found(in: #"var c = require("node:child_process");"#) == [.processes])
        check(
            "fs/promises is a filesystem capability",
            ExtensionCapability.found(in: "require('fs/promises')") == [.filesystem])
        check("process.kill is a signal", ExtensionCapability.found(in: "process.kill(pid, 9)") == [.signals])
        check("a word in prose is nothing", ExtensionCapability.found(in: "// uses fs and child_process").isEmpty)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ext-capabilities-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let modules = directory.appendingPathComponent("node_modules/execa", isDirectory: true)
        try? FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        try? #"require("fs")"#.write(
            to: directory.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
        try? #"require("child_process")"#.write(
            to: modules.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
        try? #"require("child_process")"#.write(
            to: directory.appendingPathComponent("index.js.map"), atomically: true, encoding: .utf8)
        check(
            "a bundled package counts, a source map does not",
            ExtensionCapabilityScanner.scan(directory: directory) == [.filesystem, .processes])
    }

    static func grantStore() async {
        print("\n# grant store")
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ext-grants-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = ExtensionProcessGrantStore(fileURL: file)
        store.grant("a")
        store.grant("b")
        store.revoke("b")
        let reloaded = ExtensionProcessGrantStore(fileURL: file)
        check("a grant persists", reloaded.contains("a"))
        check("a revoked grant is gone", !reloaded.contains("b"))
    }

    static func envelope(_ json: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    static func check(_ name: String, _ condition: Bool) {
        if condition {
            passes += 1
            print("  ok    \(name)")
        } else {
            failures += 1
            print("  FAIL  \(name)")
        }
    }
}
