import SwiftUI

struct SettingsRootView: View {
    @Environment(SettingsNavigationState.self) private var navigation
    @State private var detailWidth: CGFloat = 0

    var body: some View {
        NavigationSplitView {
            SettingsSidebarView()
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(
                    min: Theme.Size.settingsSidebar, ideal: Theme.Size.settingsSidebar,
                    max: Theme.Size.settingsSidebar)
        } detail: {
            SettingsDetailView()
                .frame(minWidth: Theme.Size.settingsDetailMinimum)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { detailWidth = $0 }
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Color.clear
                            .frame(width: navigationInset, height: 1)
                            .accessibilityHidden(true)
                    }
                    .sharedBackgroundVisibility(.hidden)
                    ToolbarItem(placement: .navigation) {
                        navigationButtons
                    }
                    ToolbarSpacer(.fixed, placement: .navigation)
                    ToolbarItem(placement: .navigation) {
                        SettingsBreadcrumbs(titles: breadcrumbTitles) { index in
                            if index == 0 { navigation.select(navigation.tab) }
                            if index == 1, navigation.detail != nil { navigation.goBack() }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
        }
        .navigationTitle("")
    }

    private var navigationInset: CGFloat {
        max(0, (detailWidth - Theme.Size.settingsPageWidth) / 2) + Theme.Spacing.xl
    }

    private var navigationButtons: some View {
        ControlGroup {
            Button("Back", systemImage: "chevron.backward") { navigation.goBack() }
                .disabled(!navigation.canGoBack)
            Button("Forward", systemImage: "chevron.forward") { navigation.goForward() }
                .disabled(!navigation.canGoForward)
        }
        .controlGroupStyle(.navigation)
    }

    private var breadcrumbTitles: [String] {
        let title = navigation.tab.title
        guard navigation.tab == .dictation, let target = navigation.target else { return [title] }
        let page = DictationSettingsPage.page(for: target)
        guard page != .home else { return [title] }
        let titles = [title, page.title.resolved()]
        if case .dictationTransform(let id) = navigation.detail {
            return titles + [id == nil ? String(localized: "Create transform") : String(localized: "Edit transform")]
        }
        return titles
    }
}
