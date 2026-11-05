import Foundation

struct DictionaryPronunciation: Equatable, Sendable {
    var recordings: [Recording] = []

    struct Recording: Equatable, Identifiable, Sendable {
        let id: String
        let title: String
        let ipa: String?
        let audioURL: URL
        let sourceURL: URL
        let author: String
        let licenseName: String
        let licenseURL: URL?
        var phoneticsURL: URL?
        var ipaVariants: [String] = []
    }
}
