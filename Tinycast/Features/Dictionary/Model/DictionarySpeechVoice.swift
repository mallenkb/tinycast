import Foundation

struct DictionarySpeechVoice: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let language: String
    let quality: Int

    static func preferred(from voices: [Self]) -> [Self] {
        let english = voices.filter { voice in
            // Standard voices avoid the large helper-process models used by premium speech.
            guard voice.quality == 1 else { return false }
            let parts = voice.language.lowercased().split(separator: "-", omittingEmptySubsequences: false)
            return parts.first == "en" && parts.allSatisfy { !$0.isEmpty }
        }
        let grouped = Dictionary(grouping: english) { $0.language.lowercased() }
        let preferred = ["en-us", "en-gb"].filter { grouped[$0] != nil }
        let languages = preferred.isEmpty ? grouped.keys.sorted() : preferred
        // A shared public voice family can reuse its synthesis helper across accents.
        let sharedNames = Set(grouped["en-us", default: []].map { $0.name.lowercased() })
            .intersection(grouped["en-gb", default: []].map { $0.name.lowercased() })
        let sharedName = sharedNames.sorted().first
        var identifiers: Set<String> = []
        return languages.compactMap { language in
            guard let voice = grouped[language]?.sorted(by: {
                precedes($0, $1, sharedName: sharedName)
            }).first(where: {
                !identifiers.contains($0.id)
            }) else { return nil }
            identifiers.insert(voice.id)
            return voice
        }
    }

    private static func precedes(_ lhs: Self, _ rhs: Self, sharedName: String?) -> Bool {
        let leftName = lhs.name.lowercased()
        let rightName = rhs.name.lowercased()
        if let sharedName, (leftName == sharedName) != (rightName == sharedName) {
            return leftName == sharedName
        }
        if leftName != rightName { return leftName < rightName }
        if lhs.id != rhs.id { return lhs.id < rhs.id }
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        return lhs.language < rhs.language
    }
}
