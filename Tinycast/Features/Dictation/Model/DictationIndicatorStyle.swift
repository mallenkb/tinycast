import Foundation

enum DictationIndicatorStyle: String, CaseIterable, Identifiable, Sendable {
    case compact
    case lightCompact
    case lightCapsule
    case darkCapsule
    case outlinedCapsule
    case lightRounded
    case darkRounded
    case outlinedRounded

    var id: Self { self }

    var isCompact: Bool { self == .compact || self == .lightCompact }

    var title: LocalizedStringResource {
        switch self {
        case .compact: "Dark compact"
        case .lightCompact: "Light compact"
        case .lightCapsule: "Light capsule"
        case .darkCapsule: "Dark capsule"
        case .outlinedCapsule: "Outlined capsule"
        case .lightRounded: "Light rounded rectangle"
        case .darkRounded: "Dark rounded rectangle"
        case .outlinedRounded: "Outlined rounded rectangle"
        }
    }
}
