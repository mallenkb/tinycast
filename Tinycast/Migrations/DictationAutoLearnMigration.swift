import Foundation

enum DictationAutoLearnMigration {
    static func run(defaults: UserDefaults) {
        defaults.removeObject(forKey: "dictationAutoLearnsWords")
    }
}
