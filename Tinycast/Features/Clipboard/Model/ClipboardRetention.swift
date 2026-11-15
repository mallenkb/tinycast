import Foundation

/// Retention in days; `forever` is -1, so an unset key (0) falls through to the default.
enum ClipboardRetention: Int, CaseIterable, Identifiable, Sendable {
    case day = 1
    case week = 7
    case month = 30
    case threeMonths = 90
    case sixMonths = 180
    case year = 365
    case forever = -1

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .day: return String(localized: "1 Day")
        case .week: return String(localized: "1 Week")
        case .month: return String(localized: "1 Month")
        case .threeMonths: return String(localized: "3 Months")
        case .sixMonths: return String(localized: "6 Months")
        case .year: return String(localized: "1 Year")
        case .forever: return String(localized: "Forever")
        }
    }

    var maxAge: TimeInterval {
        self == .forever ? .greatestFiniteMagnitude : TimeInterval(rawValue) * 86_400
    }
}
