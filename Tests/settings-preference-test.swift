import Foundation

private enum Span: Int {
    case all = 0
    case five = 5
}

private enum Cycle: String {
    case off
    case sizes
}

@main
struct SettingsPreferenceTest {
    static func main() {
        var failures = 0
        func check(_ description: String, _ condition: @autoclosure () -> Bool) {
            print("\(condition() ? "PASS" : "FAIL")  \(description)")
            if !condition() { failures += 1 }
        }

        let suite = "tinycast-preference-test-\(ProcessInfo.processInfo.processIdentifier)"
        guard let defaults = UserDefaults(suiteName: suite) else { fatalError("no suite") }
        defer { defaults.removePersistentDomain(forName: suite) }

        let on = Preference<Bool>("on", default: true)
        check("an unset switch reads its default", on.load(from: defaults))
        on.store(false, in: defaults)
        check("a stored false outranks a true default", !on.load(from: defaults))
        let stored = defaults.object(forKey: "on") as CFTypeRef?
        check(
            "a Bool is stored as a plist boolean",
            stored.map { CFGetTypeID($0) == CFBooleanGetTypeID() } == true)

        let span = Preference<Span>("span", default: .five)
        check("an unset Int enum reads its default, not its zero case", span.load(from: defaults) == .five)
        span.store(.all, in: defaults)
        check("a stored zero case reads back", span.load(from: defaults) == .all)
        check("an Int enum is stored as its raw Int", defaults.object(forKey: "span") as? Int == 0)
        defaults.set(42, forKey: "span")
        check("an unknown Int raw value reads the default", span.load(from: defaults) == .five)

        let cycle = Preference<Cycle>("cycle", default: .off)
        cycle.store(.sizes, in: defaults)
        check("a String enum is stored as its raw String", defaults.string(forKey: "cycle") == "sizes")
        defaults.set("retired", forKey: "cycle")
        check("an unknown String raw value reads the default", cycle.load(from: defaults) == .off)

        let folder = Preference<String?>("folder")
        check("an unset optional reads nil", folder.load(from: defaults) == nil)
        folder.store("~/Notes", in: defaults)
        check("an optional stores its string", defaults.string(forKey: "folder") == "~/Notes")
        folder.store(nil, in: defaults)
        check("storing nil removes the key", defaults.object(forKey: "folder") == nil)

        let list = Preference<[String]>("list", default: ["seed"])
        check("an unset list reads its seed", list.load(from: defaults) == ["seed"])
        list.store([], in: defaults)
        check("a cleared list stays cleared", list.load(from: defaults).isEmpty)

        let gap = Preference<Int>("gap", default: 0)
        gap.store(12, in: defaults)
        check("an Int round-trips", gap.load(from: defaults) == 12)

        let positions = Preference<[String: [Double]]>("positions", default: [:])
        positions.store(["main": [1, 2]], in: defaults)
        check("a position map round-trips", positions.load(from: defaults) == ["main": [1, 2]])

        print(failures == 0 ? "\nAll passed." : "\n\(failures) failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
