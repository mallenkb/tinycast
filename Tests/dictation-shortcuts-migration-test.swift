import Foundation

@main
struct DictationShortcutsMigrationTest {
    static func main() throws {
        let suite = "tinycast.dictation-shortcuts-migration-test.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let hold = "test.hold"
        let toggle = "test.toggle"

        defaults.set("old hold binding", forKey: "hotkey.dictation")
        defaults.set("pushToTalk", forKey: "dictationMode")
        DictationShortcutsMigration.apply(defaults: defaults, holdKey: hold, toggleKey: toggle)
        precondition(defaults.string(forKey: hold) == "old hold binding")
        precondition(defaults.object(forKey: toggle) == nil)
        precondition(defaults.object(forKey: "hotkey.dictation") == nil)
        precondition(defaults.object(forKey: "dictationMode") == nil)

        defaults.set("old toggle binding", forKey: "hotkey.dictation")
        DictationShortcutsMigration.apply(defaults: defaults, holdKey: hold, toggleKey: toggle)
        precondition(defaults.string(forKey: toggle) == "old toggle binding")
        defaults.set("stale toggle binding", forKey: "hotkey.dictation")
        DictationShortcutsMigration.apply(defaults: defaults, holdKey: hold, toggleKey: toggle)
        precondition(defaults.string(forKey: toggle) == "old toggle binding")
        precondition(defaults.string(forKey: hold) == "old hold binding")

        let parsed = try SettingsFileFormat.parse(
            Data(#"{"dictation":{"mode":"pushToTalk","shortcut":"rightCommand","toggleShortcut":"ctrl+k"}}"#.utf8))
        precondition(parsed.issues.isEmpty)
        precondition(parsed.values[.dictationHoldShortcut] == .string("rightCommand"))
        precondition(parsed.values[.dictationToggleShortcut] == .string("ctrl+k"))

        let mixed = try SettingsFileFormat.parse(
            Data(#"{"dictation":{"shortcut":"ctrl+k","toggleShortcut":null}}"#.utf8))
        precondition(mixed.issues.isEmpty)
        precondition(mixed.values[.dictationToggleShortcut] == .some(.null))
    }
}
