import Foundation

enum DictationShortcutsMigration {
    static func apply(defaults: UserDefaults, holdKey: String, toggleKey: String) {
        let legacyShortcut = "hotkey.dictation"
        let legacyMode = "dictationMode"
        let destination = defaults.string(forKey: legacyMode) == "pushToTalk" ? holdKey : toggleKey
        if let shortcut = defaults.string(forKey: legacyShortcut),
            defaults.object(forKey: destination) == nil
        {
            defaults.set(shortcut, forKey: destination)
        }
        defaults.removeObject(forKey: legacyShortcut)
        defaults.removeObject(forKey: legacyMode)
    }

    static func settingsMembers(_ members: [SettingsFileJSON.Member]) -> [SettingsFileJSON.Member] {
        let mode = members.first { $0.key == "mode" }?.value
        let shortcut = members.first { $0.key == "shortcut" }?.value
        guard mode != nil || shortcut != nil else { return members }
        let key: SettingsFileKey = mode == .string("pushToTalk") ? .dictationHoldShortcut : .dictationToggleShortcut
        var updated = members.filter { $0.key != "mode" && $0.key != "shortcut" }
        if let shortcut, !updated.contains(where: { $0.key == key.name }) {
            updated.append(.init(key: key.name, value: shortcut))
        }
        return updated
    }
}
