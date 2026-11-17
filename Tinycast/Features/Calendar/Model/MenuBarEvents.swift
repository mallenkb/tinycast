import Foundation

/// How early the calendar item picks the next event up; zero keeps it for the rest of today.
enum MenuBarEvents: Int, CaseIterable, Identifiable, Sendable {
    case today = 0
    case two = 2
    case five = 5
    case ten = 10
    case thirty = 30

    var id: Int { rawValue }

    var title: String {
        self == .today ? String(localized: "Today") : String(localized: "\(rawValue) minutes before")
    }
}
