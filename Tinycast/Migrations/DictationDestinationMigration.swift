import Foundation

enum DictationDestinationMigration {
    static let retiredSettingsFileKeys: Set<String> = [
        "dictation.destination", "dictation.liveInsertion", "dictation.livePreview", "dictation.historyLimit"
    ]

    static func apply(defaults: UserDefaults) {
        defaults.removeObject(forKey: "dictationDestination")
        defaults.removeObject(forKey: "dictationLiveInsertion")
        defaults.removeObject(forKey: "dictationLivePreview")
        defaults.removeObject(forKey: "dictationHistoryLimit")
    }
}
