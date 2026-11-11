import Foundation

enum DictationIdleRelease: Int, CaseIterable, Identifiable, Sendable {
    case afterDictation = -1
    case never = 0
    case oneMinute = 1
    case twoMinutes = 2
    case fiveMinutes = 5
    case tenMinutes = 10
    case fifteenMinutes = 15
    case twentyMinutes = 20
    case thirtyMinutes = 30
    case oneHour = 60

    var id: Self { self }

    var delay: Duration? {
        switch self {
        case .afterDictation: .zero
        case .never: nil
        default: .seconds(rawValue * 60)
        }
    }

    func title(locale: Locale) -> String {
        switch self {
        case .afterDictation: String(localized: "After each dictation", locale: locale)
        case .never: String(localized: "Never", locale: locale)
        default:
            Duration.seconds(rawValue * 60).formatted(
                .units(allowed: [.hours, .minutes], width: .wide).locale(locale))
        }
    }
}
