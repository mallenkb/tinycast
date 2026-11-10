import Foundation

nonisolated struct SpotlightContentRequest: Codable, Sendable {
    let text: String?
    let filters: SearchFileConstraints?
    let scopes: [String]
}
