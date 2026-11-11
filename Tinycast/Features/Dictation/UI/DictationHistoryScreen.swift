import SwiftUI

struct DictationHistoryScreen: PaletteScreen {
    let history: DictationHistoryStore
    let core: AppCore
    let vm: PaletteState
    let openActions: () -> Void

    var rows: [DictationHistoryEntry] { history.search(vm.query) }

    var primaryActionTitle: String {
        core.settings.clipboardDefaultAction.title(pastingInto: vm.pasteTarget)
    }

    func activate(at selection: Int) {
        _ = perform(.return, at: selection)
    }

    func secondary(at selection: Int) -> Bool { perform(.command, at: selection) }

    func tertiary(at selection: Int) -> Bool { perform(.controlCommand, at: selection) }

    func pasteKeepingWindowOpen(at selection: Int) -> Bool {
        guard let text = item(at: selection)?.text else { return false }
        Paster.pasteStringInPlace(text, into: core.paletteCoordinator.targetApp)
        return true
    }

    func perform(_ shortcut: PaletteShortcut, at selection: Int) -> Bool {
        switch shortcut {
        case .commandDelete, .delete:
            guard let item = item(at: selection) else { return false }
            history.remove(id: item.id)
            return true
        default: return false
        }
    }

    func actions(at selection: Int) -> PopoverMenuContent? {
        guard let item = item(at: selection), let text = item.text else { return nil }
        var actions = ClipboardChord.allCases.compactMap { chord in
            core.settings.clipboardDefaultAction.action(for: chord, on: item).map { action in
                PopoverMenuItem(
                    title: action.title(pastingInto: vm.pasteTarget),
                    systemImage: action == .copy ? "doc.on.doc" : "doc.on.clipboard",
                    shortcut: chord.label
                ) {
                    deliver(text, action: action)
                }
            }
        }
        let entry = rows[selection]
        if let original = entry.originalText {
            actions += [
                PopoverMenuItem(title: String(localized: "Copy original"), systemImage: "doc.on.doc") {
                    Paster.copyPlainText(original)
                },
                PopoverMenuItem(title: String(localized: "Restore original"), systemImage: "arrow.uturn.backward") {
                    core.dictationWriting.cancel()
                    history.restore(id: entry.id)
                }
            ]
        }
        actions += core.dictationTransforms.transforms.map { transform in
            PopoverMenuItem(
                title: transform.name, systemImage: "sparkles",
                isEnabled: core.dictationWriting.workingEntry == nil && core.dictationWriting.unavailableReason == nil
            ) {
                core.dictationWriting.apply(transform, to: entry)
            }
        }
        if core.dictationWriting.workingEntry == entry.id {
            actions.append(PopoverMenuItem(title: String(localized: "Cancel"), systemImage: "xmark") {
                core.dictationWriting.cancel()
            })
        }
        return PopoverMenuContent(items: actions + [
            PopoverMenuItem(
                title: String(localized: "Delete"), systemImage: "trash", shortcut: "⌘⌫",
                isDestructive: true
            ) {
                history.remove(id: item.id)
            }
        ])
    }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        let entries = rows
        let rows = entries.map(clipboardItem)
        let selected = rows.indices.contains(selection) ? rows[selection] : nil
        let metrics = core.settings.interfaceMetrics
        if rows.isEmpty {
            return AnyView(EmptyResults(text: history.entries.isEmpty
                ? String(localized: "No dictations yet") : String(localized: "No Results")))
        }
        return AnyView(
            HStack(spacing: 0) {
                ClipboardList(
                    results: rows, selectedID: selected?.id, scroll: scroll,
                    onSelect: { vm.selection = rows.firstIndex(of: $0) ?? 0 },
                    onActivate: { activate(at: vm.selection) },
                    onActions: {
                        vm.selection = rows.firstIndex(of: $0) ?? 0
                        openActions()
                    },
                    onDragPayload: { $0.dragPayload }, onDropped: core.paletteCoordinator.dragLanded,
                    rowSymbolName: "mic")
                    .frame(width: metrics.size.clipboardListWidth)
                Rectangle()
                    .fill(Theme.Colors.separator)
                    .frame(width: 1)
                if let selected {
                    VStack(alignment: .leading, spacing: 0) {
                        ScrollView {
                            Text(verbatim: selected.text ?? "")
                                .font(metrics.typography.menuRow)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(.vertical, metrics.spacing.lg)
                        }
                        if core.dictationWriting.workingEntry == entries[selection].id {
                            ProgressView().controlSize(.small)
                        }
                        ClipboardInfoSection(
                            item: selected, imageURL: nil,
                            context: .dictation(pastedAppName: entries[selection].pastedAppName))
                    }
                    .padding(.horizontal, metrics.spacing.lg)
                    .id(selected.id)
                }
            })
    }

    private func item(at selection: Int) -> ClipboardItem? {
        let entries = rows
        return entries.indices.contains(selection) ? clipboardItem(entries[selection]) : nil
    }

    private func clipboardItem(_ entry: DictationHistoryEntry) -> ClipboardItem {
        ClipboardItem(
            id: entry.id, kind: .text, text: entry.text, imagePath: nil, createdAt: entry.createdAt,
            sourceBundleID: entry.pastedAppBundleID)
    }

    private func perform(_ chord: ClipboardChord, at selection: Int) -> Bool {
        guard let item = item(at: selection), let text = item.text,
            let action = core.settings.clipboardDefaultAction.action(for: chord, on: item)
        else { return false }
        deliver(text, action: action)
        return true
    }

    private func deliver(_ text: String, action: ClipboardDefaultAction) {
        let previousApp = core.paletteCoordinator.targetApp
        core.paletteCoordinator.hidePalette(restoreFocus: false)
        if action == .copy {
            Paster.copyPlainText(text)
        } else {
            Paster.pasteString(text, previousApp: previousApp)
        }
    }
}
