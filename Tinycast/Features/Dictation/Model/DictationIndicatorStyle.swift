import Foundation

enum DictationIndicatorStyle: String, CaseIterable, Identifiable, Sendable {
    case compact
    case lightCompact
    case grayCompact
    case lightGrayCompact
    case lightCapsule
    case darkCapsule
    case outlinedCapsule
    case lightRounded
    case darkRounded
    case outlinedRounded
    case lightOutlinedCapsule
    case lightOutlinedRounded

    var id: Self { self }

    var isCompact: Bool { shape == .compact }

    var isDark: Bool {
        switch self {
        case .lightCompact, .lightGrayCompact, .lightCapsule, .lightRounded,
            .lightOutlinedCapsule, .lightOutlinedRounded: false
        default: true
        }
    }

    var usesGrayBackground: Bool {
        switch self {
        case .grayCompact, .lightGrayCompact, .darkCapsule, .lightCapsule, .darkRounded, .lightRounded: true
        default: false
        }
    }

    var shape: Shape {
        switch self {
        case .compact, .lightCompact, .grayCompact, .lightGrayCompact: .compact
        case .lightCapsule, .darkCapsule, .outlinedCapsule, .lightOutlinedCapsule: .capsule
        case .lightRounded, .darkRounded, .outlinedRounded, .lightOutlinedRounded: .rounded
        }
    }

    init(shape: Shape, isDark: Bool, usesGrayBackground: Bool) {
        self = switch (shape, isDark, usesGrayBackground) {
        case (.compact, true, false): .compact
        case (.compact, true, true): .grayCompact
        case (.compact, false, false): .lightCompact
        case (.compact, false, true): .lightGrayCompact
        case (.capsule, true, false): .outlinedCapsule
        case (.capsule, true, true): .darkCapsule
        case (.capsule, false, false): .lightOutlinedCapsule
        case (.capsule, false, true): .lightCapsule
        case (.rounded, true, false): .outlinedRounded
        case (.rounded, true, true): .darkRounded
        case (.rounded, false, false): .lightOutlinedRounded
        case (.rounded, false, true): .lightRounded
        }
    }

    enum Shape: CaseIterable, Identifiable, Sendable {
        case compact, capsule, rounded

        var id: Self { self }

        var title: LocalizedStringResource {
            switch self {
            case .compact: "Compact"
            case .capsule: "Capsule"
            case .rounded: "Rounded rectangle"
            }
        }
    }
}
