import AppKit

@main
@MainActor
struct SnippetCoordinatorTests {
    static var failures = 0
    static var passes = 0

    static func main() async throws {
        for outcome in ["enabled", "disabled", "cancelled", "declined"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let repository = SnippetRepository(
                bundleIdentifier: "com.example.snippet-coordinator", applicationSupportRoot: directory)
            let original = Snippet(name: "Existing", text: "Preserved")
            _ = try repository.create(original)
            let store = SnippetsStore(repository: repository)
            await store.start()
            defer { store.stop() }
            let settings = AppSettings()
            let core = AppCore()
            let coordinator = SnippetCoordinator(
                store: store, listener: SnippetKeywordListener(), injector: TextInjector(),
                clipboardStore: ClipboardStore(), appIndex: AppIndex(), settings: settings,
                windowController: PaletteWindowController(), paletteCoordinator: PaletteCoordinator(),
                palette: PaletteState(), showMessage: { _, _ in }, core: core)
            core.onConfirm = {
                if outcome == "disabled" {
                    settings.snippetsEnabled = false
                    coordinator.applySnippetsEnabled()
                }
                if outcome == "cancelled" { withUnsafeCurrentTask { $0?.cancel() } }
                return outcome != "declined"
            }
            let offered = Snippet(name: "Imported", text: "New body")
            let task = Task { await coordinator.importSnippets(offered: [offered]) }
            await task.value
            let expected = outcome == "enabled" ? [original, offered] : [original]
            expect(
                Set(try repository.load().records.map(\.snippet)) == Set(expected),
                "a \(outcome) batch import persists only permitted changes")
            if outcome != "disabled" {
                expect(
                    Set(store.snippets.map(\.snippet)) == Set(expected),
                    "a \(outcome) batch import publishes only permitted changes")
            }
            expect(core.confirmations == 1, "a \(outcome) batch asks once")
        }
        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    static func expect(_ condition: Bool, _ message: String) {
        if condition {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }
}

// Platform collaborators are inert so the shipped coordinator never takes input or opens windows.
@MainActor
final class AppSettings {
    var snippetsEnabled = true
    var snippetsShowInLauncher = true
    var snippetsFolder: String?
}

@MainActor
final class AppCore {
    enum ConfirmRole { case standard, destructive }
    var isShowingDialog = false
    var confirmations = 0
    var onConfirm: (() async -> Bool)?
    func confirm(
        title: String, message: String, symbol: String, confirmTitle: String,
        tone: DialogTone = .danger, confirmRole: ConfirmRole = .destructive
    ) async -> Bool {
        confirmations += 1
        return await onConfirm?() ?? false
    }
    func showMessage(_ message: String, tone: DialogTone = .success) {}
    func showNotice(title: String, message: String, symbol: String, tone: DialogTone) async {}
    func fillSnippetArguments(
        snippetName: String, arguments: [SnippetTemplateEngine.MissingArgument]
    ) async -> [String: String]? { nil }
}

enum DialogTone { case neutral, success, danger }
enum CommandID { case searchSnippets, createSnippet }
enum PaletteMode { case launcher, snippets, snippetEditor }

@MainActor
final class PaletteState {
    var mode: PaletteMode = .launcher
    func pop(preservingSelection: Bool) -> Bool { false }
    func prepare(mode: PaletteMode) { self.mode = mode }
}

@MainActor
final class PaletteCoordinator {
    var targetApp: NSRunningApplication?
    func showPalette(mode: PaletteMode) {}
    func togglePalette(mode: PaletteMode, seeding: String? = nil) {}
    func hidePalette(restoreFocus: Bool = true) {}
}

@MainActor
final class PaletteWindowController {
    var isVisible = false
    var previousTarget: InjectionTarget?
}

@MainActor
final class AppIndex {
    func setCommandsVisible(_ commands: Set<CommandID>, _ visible: Bool) {}
    func setCommandsListed(_ commands: Set<CommandID>, _ listed: Bool) {}
    func updateSnippets(_ snippets: [StoredSnippet]) {}
}

@MainActor
final class ClipboardStore {
    struct Item {
        enum Kind { case text }
        var kind: Kind
        var createdAt: Date
        var text: String?
    }
    var items: [Item] = []
}

@MainActor
final class SnippetKeywordListener {
    var isPromptingForArguments = false
    func stop() {}
    func start(
        onUserActivity: @escaping () -> Void,
        onMatch: @escaping (StoredSnippet.ID, String, Int, InjectionTarget) -> Void
    ) {}
}

@MainActor
struct InjectionTarget {
    var ownEditor: Bool?
    var externalApp: NSRunningApplication?
    static func current() -> InjectionTarget? { nil }
}

struct InjectedText {
    init(_ text: String, cursorOffsetFromEnd: Int?) {}
}

@MainActor
final class TextInjector {
    func cancelAutomaticExpansion() {}
    func beginAutomaticExpansion(target: InjectionTarget) -> UInt? { nil }
    func cancelArgumentPrompt(automaticGeneration: UInt?, target: InjectionTarget?) {}
    func prepareInteractiveExpansion(target: InjectionTarget?) -> Bool { false }
    func captureExpansionContext(
        target: InjectionTarget?, clipboardHistory: [String]
    ) -> SnippetTemplateEngine.ExpansionContext { fatalError("No expansion is exercised") }
    func copySelection(from app: NSRunningApplication) async -> String? { nil }
    func deliver(
        _ text: InjectedText, target: InjectionTarget?, expectedKeyword: String?, keywordLength: Int,
        automaticGeneration: UInt?, onDelivered: @escaping () -> Void
    ) {}
}

@MainActor
enum Permissions {
    static func ensureAccessibility() {}
}

@MainActor
enum AccessibilityText {
    static func selection(in app: NSRunningApplication) -> String? { nil }
}

enum FolderPicker {
    static func choose(message: String, startingAt: URL) -> URL? { nil }
}

enum AppPaths {
    static func contentFolderSetting(for url: URL, named: String) -> String? { nil }
}

enum AppLauncher {
    static func showInFinder(_ url: URL) {}
}
