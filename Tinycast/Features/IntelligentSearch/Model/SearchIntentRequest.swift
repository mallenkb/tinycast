import Foundation

struct SearchIntentRequest: Sendable, Codable {
    let query: String
    let context: SearchIntent.Context
    let commands: [SearchIntent.Command]
    let websites: [String]
    let now: Date
    let calendar: Calendar
}
