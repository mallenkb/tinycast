import Foundation

/// A brief dismissal preserves the current screen before the idle timeout returns to root.
enum PopToRootTimeout: Int, CaseIterable, Identifiable, Sendable {
    case immediately = 0
    case afterFive = 5
    case afterFifteen = 15
    case afterThirty = 30
    case afterSixty = 60
    case afterNinety = 90

    var id: Int { rawValue }

    var title: String {
        self == .immediately
            ? String(localized: "Immediately") : String(localized: "After \(rawValue) seconds")
    }

    var interval: TimeInterval { TimeInterval(rawValue) }
}
