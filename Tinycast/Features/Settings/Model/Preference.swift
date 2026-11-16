import Foundation

/// One `UserDefaults` key, its default and its stored form, so a read and a write cannot disagree.
struct Preference<Value> {
    let key: String
    let defaultValue: Value
    /// nil when the key is absent or holds nothing this preference can read.
    private let read: (UserDefaults, String) -> Value?
    private let write: (UserDefaults, String, Value) -> Void

    init(
        _ key: String, default defaultValue: Value,
        read: @escaping (UserDefaults, String) -> Value?,
        write: @escaping (UserDefaults, String, Value) -> Void
    ) {
        self.key = key
        self.defaultValue = defaultValue
        self.read = read
        self.write = write
    }

    func load(from defaults: UserDefaults) -> Value {
        read(defaults, key) ?? defaultValue
    }

    func store(_ value: Value, in defaults: UserDefaults) {
        write(defaults, key, value)
    }
}

extension Preference where Value == Bool {
    /// Absence outranks a stored `false`, so a switch that ships on stays on until turned off.
    init(_ key: String, default defaultValue: Bool) {
        self.init(
            key, default: defaultValue,
            read: { $0.object(forKey: $1) == nil ? nil : $0.bool(forKey: $1) },
            write: { $0.set($2, forKey: $1) })
    }
}

extension Preference where Value == Int {
    init(_ key: String, default defaultValue: Int) {
        self.init(
            key, default: defaultValue,
            read: { $0.object(forKey: $1) == nil ? nil : $0.integer(forKey: $1) },
            write: { $0.set($2, forKey: $1) })
    }
}

extension Preference where Value == String {
    init(_ key: String, default defaultValue: String) {
        self.init(
            key, default: defaultValue, read: { $0.string(forKey: $1) },
            write: { $0.set($2, forKey: $1) })
    }
}

extension Preference where Value == String? {
    /// Writing nil removes the key rather than storing a placeholder.
    init(_ key: String) {
        self.init(
            key, default: nil, read: { $0.string(forKey: $1).map(Optional.some) },
            write: { defaults, key, value in
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            })
    }
}

extension Preference where Value == [String] {
    /// A stored empty array is a deliberately cleared list, distinct from the unset default.
    init(_ key: String, default defaultValue: [String]) {
        self.init(
            key, default: defaultValue, read: { $0.stringArray(forKey: $1) },
            write: { $0.set($2, forKey: $1) })
    }
}

extension Preference where Value == [String: [Double]] {
    init(_ key: String, default defaultValue: [String: [Double]]) {
        self.init(
            key, default: defaultValue, read: { $0.dictionary(forKey: $1) as? [String: [Double]] },
            write: { $0.set($2, forKey: $1) })
    }
}

extension Preference where Value == [String: [String: String]] {
    init(_ key: String, default defaultValue: [String: [String: String]]) {
        self.init(
            key, default: defaultValue, read: { $0.dictionary(forKey: $1) as? [String: [String: String]] },
            write: { $0.set($2, forKey: $1) })
    }
}

extension Preference where Value: RawRepresentable, Value.RawValue == String {
    /// An unknown raw value reads as the default, so a retired case never fails a launch.
    init(_ key: String, default defaultValue: Value) {
        self.init(
            key, default: defaultValue, read: { $0.string(forKey: $1).flatMap(Value.init(rawValue:)) },
            write: { $0.set($2.rawValue, forKey: $1) })
    }
}

extension Preference where Value: RawRepresentable, Value.RawValue == Int {
    /// Presence is checked first: an unset key reads as 0, which can be a real case.
    init(_ key: String, default defaultValue: Value) {
        self.init(
            key, default: defaultValue,
            read: {
                $0.object(forKey: $1) == nil ? nil : Value(rawValue: $0.integer(forKey: $1))
            },
            write: { $0.set($2.rawValue, forKey: $1) })
    }
}
