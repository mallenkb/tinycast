import Observation

/// The palette's in-window menus. One optional of these is the whole "only one is open" invariant.
enum PaletteMenu: Equatable {
    case actions
    case extensionAccessory
    case argumentOptions
    case inputOptions(MenuPanelCorner)
    case app
    case clipboardFilter
    case fileSearchFilter
    case emojiCategory
    case aiModel
    case aiReasoning
    case aiAttachments

    var corner: MenuPanelCorner {
        switch self {
        case .app: .bottomLeading
        case .actions: .bottomTrailing
        case .inputOptions(let corner): corner
        case .argumentOptions, .clipboardFilter, .fileSearchFilter, .emojiCategory, .aiModel,
            .aiReasoning, .aiAttachments, .extensionAccessory:
            .belowHeaderTrailing
        }
    }
}

/// What the state machine reads of an open menu's rows; `PaletteMenuContent` is the shipped one.
@MainActor protocol PaletteMenuRows {
    var rowCount: Int { get }
    var preferredSelection: Int? { get }
    var isSelectable: (Int) -> Bool { get }
}

/// Which menu is open and what it highlights; the view only builds rows and presents the panel.
@MainActor
@Observable
final class PaletteMenuState<InputOptions> {
    private(set) var openMenu: PaletteMenu?
    var selection = 0
    /// The argument field whose choices are up, so the view can rebuild the same menu.
    private(set) var argumentOptionsField: String?
    private(set) var inputOptions: InputOptions?
    /// Sampled once by `openActions`, so the running-only rows can't appear while the menu is up.
    private(set) var selectionIsRunning = false
    @ObservationIgnored private let palette: PaletteState

    init(palette: PaletteState) {
        self.palette = palette
    }

    var isOpen: Bool { openMenu != nil }

    /// Every open path lands here, so the highlight is always stated rather than left behind.
    func open(_ menu: PaletteMenu, highlighting row: Int) {
        palette.menuQuery = ""
        selection = row
        palette.noteMenuPresentation()
        openMenu = menu
        palette.menuOpen = true
    }

    func openActions(selectionIsRunning: Bool) {
        self.selectionIsRunning = selectionIsRunning
        open(.actions, highlighting: 0)
    }

    func openArgumentOptions(for field: String) {
        argumentOptionsField = field
        open(.argumentOptions, highlighting: 0)
    }

    func openInputOptions(_ content: InputOptions, corner: MenuPanelCorner, selection: Int) {
        inputOptions = content
        open(.inputOptions(corner), highlighting: selection)
    }

    func close() {
        openMenu = nil
        argumentOptionsField = nil
        inputOptions = nil
        palette.menuQuery = ""
        // Stated here rather than mirrored later: the window delegate reads it during this turn.
        palette.menuOpen = false
    }

    /// The view that owned these ended without a hide; nothing it presented may outlive it.
    func discard() {
        openMenu = nil
        argumentOptionsField = nil
        inputOptions = nil
    }

    /// True when Escape should close the menu; a typed menu query is cleared first instead.
    func escapeCloses() -> Bool {
        guard palette.menuQuery.isEmpty else {
            palette.menuQuery = ""
            return false
        }
        return true
    }

    /// Steps over rows that can't take the highlight, and stays put at either end.
    func move(_ delta: Int, in rows: (any PaletteMenuRows)?) {
        guard let rows else { return }
        var row = selection + delta
        while (0..<rows.rowCount).contains(row) {
            if rows.isSelectable(row) {
                selection = row
                return
            }
            row += delta
        }
    }

    /// True when the open menu should be re-presented with the new highlight.
    func menuQueryDidChange(rows: (any PaletteMenuRows)?) -> Bool {
        guard isOpen, let rows else { return false }
        let next =
            rows.preferredSelection
            ?? (0..<rows.rowCount).first(where: rows.isSelectable) ?? 0
        if next != selection { selection = next }
        return true
    }

    func canActivate(_ index: Int, in rows: (any PaletteMenuRows)?) -> Bool {
        guard let rows, (0..<rows.rowCount).contains(index) else { return false }
        return rows.isSelectable(index)
    }

    /// A row is addressed by index, so a menu that lost rows keeps its highlight on one it has.
    func clampSelection(rowCount: Int) {
        selection = min(selection, max(rowCount - 1, 0))
    }
}
