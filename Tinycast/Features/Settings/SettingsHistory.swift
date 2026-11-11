/// Browser semantics: choosing a pane truncates what was ahead, and re-choosing it is not a move.
struct SettingsHistory<Destination: Equatable> {
    private(set) var current: Destination
    private var back: [Destination] = []
    private var forward: [Destination] = []

    init(current: Destination) {
        self.current = current
    }

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    mutating func select(_ tab: Destination) {
        guard tab != current else { return }
        back.append(current)
        forward.removeAll()
        current = tab
    }

    mutating func goBack() {
        guard let previous = back.popLast() else { return }
        forward.append(current)
        current = previous
    }

    mutating func goForward() {
        guard let next = forward.popLast() else { return }
        back.append(current)
        current = next
    }

    mutating func discardCurrent() {
        guard let previous = back.popLast() else { return }
        forward.removeAll()
        current = previous
    }
}
