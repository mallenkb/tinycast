import Foundation

/// The calendar's independent menu-bar presence. Zero matches an unset preference.
enum CalendarMenuBarDisplay: Int, CaseIterable, Identifiable, Sendable {
    case disabled = 0
    case meetingIcon = 1
    case meetingTitle = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .disabled: String(localized: "Disabled")
        case .meetingIcon: String(localized: "Meeting Icon")
        case .meetingTitle: String(localized: "Meeting Title")
        }
    }
}
