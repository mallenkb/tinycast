import Foundation

/// A background refusal is asked again once a menu session turns interactive; the others stand.
enum ExtensionProcessAccess: Sendable, Equatable {
    case allowed
    case denied
    case deniedInBackground
}
