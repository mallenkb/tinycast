import Foundation

@main struct DictionarySpeechVoiceTests {
    static func main() {
        let usDefault = voice("us-default", "Samantha", "en-US", 1)
        let usEnhanced = voice("us-enhanced", "Samantha", "en-US", 2)
        let usPremium = voice("us-premium", "Zoe", "en-US", 3)
        let gbDefault = voice("gb-default", "Daniel", "en-GB", 1)
        let gbEnhanced = voice("gb-enhanced", "Serena", "en-GB", 2)
        let australia = voice("au", "Karen", "en-AU", 3)
        let france = voice("fr", "Thomas", "fr-FR", 3)

        expect([], [])
        expect([france], [])
        expect([usDefault], [usDefault])
        expect([gbDefault], [gbDefault])
        expect([gbEnhanced, usDefault, usPremium, gbDefault, usEnhanced], [usDefault, gbDefault])
        expect([usEnhanced, usPremium, gbEnhanced], [])
        expect([australia, usDefault, france], [usDefault])
        expect([australia, gbDefault, france], [gbDefault])
        expect([usDefault, usDefault, gbDefault, gbDefault], [usDefault, gbDefault])

        let alex = voice("alex", "alex", "en-US", 1)
        let zoe = voice("zoe", "Zoe", "en-US", 1)
        expect([zoe, alex], [alex])
        expect([alex, zoe], [alex])
        let sameNameFirst = voice("a", "SAMANTHA", "en-US", 1)
        let sameNameLast = voice("z", "Samantha", "en-US", 1)
        expect([sameNameLast, sameNameFirst], [sameNameFirst])
        expect([sameNameFirst, sameNameLast], [sameNameFirst])

        let caseVariant = voice("case", "Alex", "EN-us", 1)
        expect([usDefault, caseVariant], [caseVariant])
        expect([caseVariant], [caseVariant])
        let canada = voice("ca", "Samantha", "en-CA", 1)
        let india = voice("in", "Rishi", "en-IN", 1)
        let general = voice("en", "English", "en", 1)
        let australiaDefault = voice("au-default", "Karen", "en-AU", 1)
        expect([usPremium, australiaDefault], [australiaDefault])
        expect([india, australiaDefault, canada, australia, general, france],
               [general, australiaDefault, canada, india])
        expect([india, australiaDefault, canada, australia, general, france, gbDefault, usDefault],
               [usDefault, gbDefault])

        let sharedUS = voice("shared", "Alex", "en-US", 1)
        let sharedGB = voice("shared", "Alex", "en-GB", 1)
        expect([sharedGB, sharedUS, gbDefault], [sharedUS, gbDefault])
        expect([sharedUS, sharedGB], [sharedUS])

        let eddyUS = voice("eddy-us", "Eddy", "en-US", 1)
        let eddyGB = voice("eddy-gb", "EDDY", "en-GB", 1)
        expect([alex, eddyUS, gbDefault, eddyGB], [eddyUS, eddyGB])
        let alexGB = voice("alex-gb", "Alex", "en-GB", 1)
        expect([eddyUS, eddyGB, alexGB, alex], [alex, alexGB])
        let premiumFamilyGB = voice("premium-family", "alex", "en-GB", 3)
        expect([alex, usDefault, gbDefault, premiumFamilyGB], [alex, gbDefault])
        expect([alex, eddyUS, eddyUS, eddyGB, eddyGB, gbDefault], [eddyUS, eddyGB])
        expect([eddyUS, eddyGB, voice("enhanced-family", "alex", "en-GB", 2), alex],
               [eddyUS, eddyGB])

        let malformed = [
            "", "english", "eng-US", "enochian", "en-", "en--US", "-en", "en_US", " en-US",
            "de-DE", "fr-EN", "den-US", "en-US-"
        ].map { voice($0, $0, $0, 100) }
        expect(malformed, [])
        expect(malformed + [usDefault], [usDefault])

        let candidates = [usDefault, usEnhanced, usPremium, gbDefault, gbEnhanced, australia, france]
        for offset in candidates.indices {
            let rotated = Array(candidates[offset...]) + Array(candidates[..<offset])
            expect(rotated, [usDefault, gbDefault])
            expect(Array(rotated.reversed()), [usDefault, gbDefault])
        }
        let families = [alex, eddyUS, gbDefault, eddyGB, usPremium, gbEnhanced]
        for offset in families.indices {
            let rotated = Array(families[offset...]) + Array(families[..<offset])
            expect(rotated, [eddyUS, eddyGB])
            expect(Array(rotated.reversed()), [eddyUS, eddyGB])
        }
        print("Dictionary speech voices passed standard-only families, locale ordering and identity checks")
    }

    private static func voice(_ id: String, _ name: String, _ language: String, _ quality: Int)
        -> DictionarySpeechVoice {
        DictionarySpeechVoice(id: id, name: name, language: language, quality: quality)
    }

    private static func expect(_ voices: [DictionarySpeechVoice], _ expected: [DictionarySpeechVoice]) {
        let selected = DictionarySpeechVoice.preferred(from: voices)
        precondition(selected == expected, "Selected \(selected.map(\.id)); expected \(expected.map(\.id))")
        precondition(Set(selected.map(\.id)).count == selected.count)
    }
}
