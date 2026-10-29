import Foundation

enum AppTypography: String, CaseIterable, Identifiable, Sendable {
    case system
    case interVariable

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: String(localized: "Default")
        case .interVariable: "Inter Variable"
        }
    }
}
