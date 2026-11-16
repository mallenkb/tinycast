import Foundation

/// The one session a query edit feeds; modes are exclusive, so at most one listens.
enum PaletteQueryRoute: Equatable {
    case fileSearch
    case launcherFiles
    case dictionary
    case menuSearch
    case windowSwitch
    case extensionSearchText

    static func resolve(mode: PaletteMode, extensionHandlesSearchText: Bool) -> Self? {
        switch mode {
        case .fileSearch: .fileSearch
        case .launcher: .launcherFiles
        case .dictionary: .dictionary
        case .menuSearch: .menuSearch
        case .switchWindows: .windowSwitch
        // A command that took over the search text filters its own list.
        case .extensionCommand: extensionHandlesSearchText ? .extensionSearchText : nil
        default: nil
        }
    }
}

/// What entering `mode` does to every mode-scoped session, so leaving a screen always ends its work.
struct PaletteModeTransition: Equatable {
    enum FileSearch: Equatable {
        case search
        case searchFromLauncher
        case cancel
    }

    enum Dictionary: Equatable {
        case lookUp
        case reset
    }

    let cancelsUninstall: Bool
    let fileSearch: FileSearch
    let dictionary: Dictionary
    let resetsMenuSearch: Bool
    let resetsWindowSwitch: Bool
    let clearsMeetingDetails: Bool
    let closesRooms: Bool
    /// Applied only while a command runs; leaving any way but Escape still ends its session.
    let stopsExtension: Bool

    init(entering mode: PaletteMode) {
        cancelsUninstall = mode != .uninstall
        // Entering with no query is the blank screen's own request for recents.
        fileSearch =
            switch mode {
            case .fileSearch: .search
            case .launcher: .searchFromLauncher
            default: .cancel
            }
        dictionary = mode == .dictionary ? .lookUp : .reset
        resetsMenuSearch = mode != .menuSearch
        resetsWindowSwitch = mode != .switchWindows
        clearsMeetingDetails = mode != .meetingDetails
        closesRooms = mode != .rooms && mode != .roomWindows
        stopsExtension = mode != .extensionCommand
    }
}
