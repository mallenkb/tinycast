import Foundation
import Observation

/// Not on `AppCore`: one window's session, released in `windowWillClose` so history never survives.
@MainActor
@Observable
final class SettingsNavigationState {
    enum Detail: Hashable {
        case dictationTransform(UUID?)
    }

    private struct Destination: Equatable {
        let tab: SettingsTab
        let target: SettingsTarget?
        var detail: Detail? = nil
    }

    private var history: SettingsHistory<Destination>
    private var requests = 0

    init(tab: SettingsTab) {
        history = SettingsHistory(current: Destination(tab: tab, target: nil))
    }

    var tab: SettingsTab { history.current.tab }
    var target: SettingsTarget? { history.current.target }
    var detail: Detail? { history.current.detail }
    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }

    /// Consumed by the pane that scrolls to the destination.
    private(set) var scrollRequest: SettingsScrollRequest?
    /// The section lit right now. One source for the whole window, so a pane swap can't lose it.
    private(set) var flashing: SettingsTarget?

    /// A search result navigates and asks the pane to reveal one section; a sidebar row just navigates.
    func select(_ tab: SettingsTab, revealing target: SettingsTarget? = nil, highlight: Bool = true) {
        history.select(Destination(tab: tab, target: target))
        revealCurrent(highlight: highlight)
    }

    func openDetail(_ detail: Detail) {
        guard self.detail == nil else { return }
        history.select(Destination(tab: tab, target: target, detail: detail))
        revealCurrent(highlight: false)
    }

    func dismissDetail() {
        guard detail != nil else { return }
        history.discardCurrent()
        revealCurrent(highlight: false)
    }

    private func revealCurrent(highlight: Bool) {
        flashing = nil
        scrollRequest = nil
        guard detail == nil, let target = history.current.target else { return }
        requests += 1
        scrollRequest = SettingsScrollRequest(target: target, token: requests, highlight: highlight)
    }

    func beginFlash(_ target: SettingsTarget) {
        flashing = target
    }

    /// Ends the pulse, unless a later jump has already lit something else.
    func endFlash(_ target: SettingsTarget) {
        guard flashing == target else { return }
        flashing = nil
    }

    /// Released only once the pulse is over: it keys the pane's task, so clearing it early would
    /// cancel the very task doing the revealing.
    func clear(_ request: SettingsScrollRequest) {
        guard scrollRequest == request else { return }
        scrollRequest = nil
    }

    func goBack() {
        guard canGoBack else { return }
        history.goBack()
        revealCurrent(highlight: false)
    }
    func goForward() {
        guard canGoForward else { return }
        history.goForward()
        revealCurrent(highlight: false)
    }
}
