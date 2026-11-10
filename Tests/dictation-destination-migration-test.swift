import Foundation

@main
struct DictationDestinationMigrationTest {
    static func main() throws {
        let suite = "tinycast.dictation-destination-migration-test.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("copy", forKey: "dictationDestination")
        defaults.set(true, forKey: "dictationLiveInsertion")
        defaults.set(true, forKey: "dictationLivePreview")
        defaults.set(50, forKey: "dictationHistoryLimit")
        defaults.set(true, forKey: "dictationEnabled")
        DictationDestinationMigration.apply(defaults: defaults)
        precondition(defaults.object(forKey: "dictationDestination") == nil)
        precondition(defaults.object(forKey: "dictationLiveInsertion") == nil)
        precondition(defaults.object(forKey: "dictationLivePreview") == nil)
        precondition(defaults.object(forKey: "dictationHistoryLimit") == nil)
        precondition(defaults.bool(forKey: "dictationEnabled"))

        let parsed = try SettingsFileFormat.parse(Data("""
            {"dictation":{"destination":"copy","livePreview":true,"liveInsertion":true,
            "historyLimit":50,"adaptsCapitalization":false,"unknown":false}}
            """.utf8))
        precondition(parsed.issues == [.unknownSetting("dictation.unknown")])
        precondition(parsed.values == [.dictationAdaptsCapitalization: .bool(false)])
    }
}
