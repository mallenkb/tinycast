import CoreGraphics
import Foundation

/// A query edit reaches exactly one session, a mode change ends every other, and menus stay single.
@main
@MainActor
struct PaletteCoordinatorTests {
    static var failures = 0
    static var passes = 0

    static func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        if actual == expected {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message) — got \(actual), want \(expected)")
        }
    }

    struct Rows: PaletteMenuRows {
        let rowCount: Int
        var preferredSelection: Int?
        var isSelectable: (Int) -> Bool = { _ in true }
    }

    static func main() {
        queryRouting()
        modeTransitions()
        menuOpenAndClose()
        menuNavigation()
        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    static func queryRouting() {
        let routed: [PaletteMode: PaletteQueryRoute] = [
            .fileSearch: .fileSearch, .launcher: .launcherFiles, .dictionary: .dictionary,
            .menuSearch: .menuSearch, .switchWindows: .windowSwitch,
        ]
        for mode in PaletteMode.allCases where mode != .extensionCommand {
            expect(
                PaletteQueryRoute.resolve(mode: mode, extensionHandlesSearchText: true), routed[mode],
                "\(mode) routes its query to its own session only")
        }
        expect(
            PaletteQueryRoute.resolve(mode: .extensionCommand, extensionHandlesSearchText: true),
            .extensionSearchText, "a command that took over the search text hears every edit")
        expect(
            PaletteQueryRoute.resolve(mode: .extensionCommand, extensionHandlesSearchText: false),
            nil, "a command filtering locally is not dispatched to")
    }

    static func modeTransitions() {
        for mode in PaletteMode.allCases {
            let transition = PaletteModeTransition(entering: mode)
            expect(transition.cancelsUninstall, mode != .uninstall, "\(mode) uninstall session")
            expect(transition.resetsMenuSearch, mode != .menuSearch, "\(mode) menu search session")
            expect(transition.resetsWindowSwitch, mode != .switchWindows, "\(mode) window switch session")
            expect(transition.clearsMeetingDetails, mode != .meetingDetails, "\(mode) meeting details")
            expect(transition.closesRooms, mode != .rooms && mode != .roomWindows, "\(mode) rooms")
            expect(transition.stopsExtension, mode != .extensionCommand, "\(mode) extension session")
            let fileSearch: PaletteModeTransition.FileSearch =
                mode == .fileSearch ? .search : mode == .launcher ? .searchFromLauncher : .cancel
            expect(transition.fileSearch, fileSearch, "\(mode) file search session")
            expect(transition.dictionary, mode == .dictionary ? .lookUp : .reset, "\(mode) dictionary")
        }

        let palette = PaletteState()
        palette.clipboardFilter = .image
        palette.fileSearchFilter = .folders
        palette.emojiCategoryFilter = EmojiCategoryFilter.allCases.last ?? .all
        palette.emojiGridColumnsOverride = .six
        palette.resetScreenFilters()
        expect(palette.clipboardFilter, .all, "a new screen opens with every clipboard type")
        expect(palette.fileSearchFilter, .all, "a new screen opens with every file type")
        expect(palette.emojiCategoryFilter, .all, "a new screen opens on all categories")
        expect(palette.emojiGridColumnsOverride, nil, "a zoom lasts one picker session")
    }

    static func menuOpenAndClose() {
        let palette = PaletteState()
        let menus = PaletteMenuState<String>(palette: palette)
        palette.menuQuery = "left over"
        menus.open(.clipboardFilter, highlighting: 3)
        expect(menus.openMenu, .clipboardFilter, "open states the menu")
        expect(menus.selection, 3, "open states the highlight")
        expect(palette.menuOpen, true, "the panel learns a menu owns input in the same turn")
        expect(palette.menuQuery, "", "a menu never opens on another menu's query")

        menus.openActions(selectionIsRunning: true)
        expect(menus.openMenu, .actions, "opening another menu replaces the first")
        expect(menus.selectionIsRunning, true, "the running state is sampled once at open")
        expect(menus.selection, 0, "Actions opens on its first row")

        menus.openInputOptions("choices", corner: .bottomLeading, selection: 2)
        expect(menus.openMenu, .inputOptions(.bottomLeading), "input options open at their corner")
        expect(menus.inputOptions, "choices", "input options keep their rows")
        expect(menus.openMenu?.corner, .bottomLeading, "the corner comes from the control")

        palette.menuQuery = "pa"
        expect(menus.escapeCloses(), false, "Escape clears a typed menu query first")
        expect(palette.menuQuery, "", "the cleared query")
        expect(menus.escapeCloses(), true, "Escape on an empty query closes the menu")

        menus.close()
        expect(menus.openMenu, nil, "close leaves nothing open")
        expect(menus.inputOptions, nil, "close drops the input rows")
        expect(palette.menuOpen, false, "close tells the panel in the same turn")

        menus.openArgumentOptions(for: "size")
        expect(menus.argumentOptionsField, "size", "an options field remembers its field")
        expect(menus.openMenu?.corner, .belowHeaderTrailing, "argument options hang below the header")
        menus.discard()
        expect(menus.openMenu, nil, "a torn-down view leaves no menu behind")
        expect(menus.argumentOptionsField, nil, "nor its field")

        expect(PaletteMenu.app.corner, .bottomLeading, "the app menu hangs off the footer's left")
        expect(PaletteMenu.actions.corner, .bottomTrailing, "Actions hangs off the footer's right")
    }

    static func menuNavigation() {
        let palette = PaletteState()
        let menus = PaletteMenuState<String>(palette: palette)
        let rows = Rows(rowCount: 5, isSelectable: { $0 != 1 && $0 != 4 })
        menus.open(.app, highlighting: 0)
        menus.move(1, in: rows)
        expect(menus.selection, 2, "Down skips a row that can't take the highlight")
        menus.move(1, in: rows)
        expect(menus.selection, 3, "Down steps onto the next selectable row")
        menus.move(1, in: rows)
        expect(menus.selection, 3, "Down at the last selectable row stays put")
        menus.move(-1, in: rows)
        menus.move(-1, in: rows)
        expect(menus.selection, 0, "Up skips back over the disabled row")
        menus.move(1, in: nil)
        expect(menus.selection, 0, "a menu with no rows ignores the arrows")

        expect(menus.canActivate(2, in: rows), true, "a selectable row activates")
        expect(menus.canActivate(1, in: rows), false, "a disabled row does not")
        expect(menus.canActivate(5, in: rows), false, "an index past the rows does not")
        expect(menus.canActivate(0, in: nil), false, "nothing activates without rows")

        expect(menus.menuQueryDidChange(rows: Rows(rowCount: 4, preferredSelection: 2)), true, "re-present")
        expect(menus.selection, 2, "a query's best match takes the highlight")
        let firstOff = Rows(rowCount: 3, isSelectable: { $0 > 0 })
        expect(menus.menuQueryDidChange(rows: firstOff), true, "re-present again")
        expect(menus.selection, 1, "without a best match the first selectable row leads")
        expect(menus.menuQueryDidChange(rows: nil), false, "no rows, nothing to present")

        menus.selection = 6
        menus.clampSelection(rowCount: 2)
        expect(menus.selection, 1, "a menu that lost rows keeps the highlight on its last")
        menus.clampSelection(rowCount: 0)
        expect(menus.selection, 0, "an emptied menu highlights row zero")

        menus.close()
        expect(menus.menuQueryDidChange(rows: rows), false, "a closed menu ignores its query")
    }
}
