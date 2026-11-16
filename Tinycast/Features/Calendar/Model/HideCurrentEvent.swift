import Foundation

/// Whether a started event remains in the menu bar long enough to show its time left.
enum HideCurrentEvent: Int, CaseIterable, Identifiable, Sendable {
    case dontHide = -1
    case automatically = 0
    case afterFive = 5
    case afterTen = 10
    case afterThirty = 30

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .dontHide: String(localized: "Keep visible — show time left")
        case .automatically: String(localized: "Automatically")
        default: String(localized: "After \(rawValue) minutes")
        }
    }

    var hidesAtStart: Bool { self == .automatically }
    var minutes: Int? { rawValue > 0 ? rawValue : nil }
}
