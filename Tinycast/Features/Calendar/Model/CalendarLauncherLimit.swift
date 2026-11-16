import Foundation

enum CalendarLauncherLimit: Int, CaseIterable, Identifiable, Sendable {
    case one = 1
    case three = 3
    case five = 5
    case all = 0

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .one, .three, .five: String(localized: "\(rawValue) next")
        case .all: String(localized: "All")
        }
    }

    var maximum: Int? { self == .all ? nil : rawValue }
}
