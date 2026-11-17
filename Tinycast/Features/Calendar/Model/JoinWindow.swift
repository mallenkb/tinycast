import Foundation

/// How early the join card appears, and how long past the start it stays. See UpcomingWindow.
enum JoinWindow: Int, CaseIterable, Identifiable, Sendable {
    case one = 1
    case two = 2
    case five = 5
    case ten = 10
    case fifteen = 15

    var id: Int { rawValue }

    var title: String { String(localized: "\(rawValue) minutes") }
}
