import AppKit
import SwiftUI

/// A real split view, as Settings has, so the sidebar collapses and resizes like a native one.
final class AIChatSplitViewController: NSSplitViewController {
    private let defaults = AppPaths.preferences
    private static let widthKey = "aiChatSidebarWidth"
    private static let collapsedKey = "aiChatSidebarCollapsed"
    private var restoredSidebar = false
    private var restoringSidebar = false

    init(sidebar: some View, detail: some View) {
        super.init(nibName: nil, bundle: nil)

        let sidebarItem = NSSplitViewItem(
            sidebarWithViewController: NSHostingController(rootView: sidebar.motionScope()))
        sidebarItem.minimumThickness = Theme.Size.aiChatSidebarMinimum
        sidebarItem.maximumThickness = Theme.Size.aiChatSidebarMaximum
        sidebarItem.canCollapse = true

        let detailItem = NSSplitViewItem(
            viewController: NSHostingController(rootView: detail.motionScope()))
        detailItem.minimumThickness = Theme.Size.aiChatDetailMinimum

        addSplitViewItem(sidebarItem)
        addSplitViewItem(detailItem)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard view.window != nil, !restoringSidebar, let sidebar = splitViewItems.first else { return }
        if !restoredSidebar {
            restoredSidebar = true
            restoringSidebar = true
            let width = defaults.double(forKey: Self.widthKey)
            if width.isFinite, width > 0 {
                splitView.setPosition(
                    min(max(width, Theme.Size.aiChatSidebarMinimum), Theme.Size.aiChatSidebarMaximum),
                    ofDividerAt: 0)
            }
            sidebar.isCollapsed = defaults.bool(forKey: Self.collapsedKey)
            restoringSidebar = false
        }
        saveSidebar()
    }

    override func viewWillDisappear() {
        saveSidebar()
        super.viewWillDisappear()
    }

    private func saveSidebar() {
        guard restoredSidebar, !restoringSidebar, let sidebar = splitViewItems.first else { return }
        if defaults.object(forKey: Self.collapsedKey) as? Bool != sidebar.isCollapsed {
            defaults.set(sidebar.isCollapsed, forKey: Self.collapsedKey)
        }
        let width = sidebar.viewController.view.frame.width
        if !sidebar.isCollapsed, width.isFinite, width >= Theme.Size.aiChatSidebarMinimum,
           defaults.double(forKey: Self.widthKey) != width {
            defaults.set(min(width, Theme.Size.aiChatSidebarMaximum), forKey: Self.widthKey)
        }
    }
}
