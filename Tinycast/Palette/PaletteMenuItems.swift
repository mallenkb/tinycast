import SwiftUI

/// The rows of the palette's own header and footer menus; activating one is how its value changes.
@MainActor
enum PaletteMenuItems {
    static func clipboardFilter(_ palette: PaletteState) -> PopoverMenuContent {
        PopoverMenuContent(
            items: ClipboardFilter.allCases.enumerated().map { index, filter in
                PopoverMenuItem(
                    title: filter.title, systemImage: filter.systemImage,
                    startsSection: index == 1
                ) {
                    palette.clipboardFilter = filter
                }
            })
    }

    static func fileSearchFilter(_ palette: PaletteState) -> PopoverMenuContent {
        PopoverMenuContent(
            items: FileSearchFilter.allCases.map { filter in
                PopoverMenuItem(title: filter.title, systemImage: filter.systemImage) {
                    palette.fileSearchFilter = filter
                }
            })
    }

    /// All Categories stays above the divider; the remaining rows match their section order.
    static func emojiCategory(_ palette: PaletteState) -> PopoverMenuContent {
        PopoverMenuContent(
            items: EmojiCategoryFilter.allCases.enumerated().map { index, filter in
                PopoverMenuItem(
                    title: filter.title, systemImage: filter.systemImage,
                    startsSection: index == 1
                ) {
                    palette.emojiCategoryFilter = filter
                }
            })
    }

    static func app(core: AppCore, openURL: OpenURLAction) -> PopoverMenuContent {
        let appName = Bundle.main.appDisplayName
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let title = version.map { "\(appName) v\($0)" } ?? appName
        return PopoverMenuContent(
            header: title,
            items: [
                PopoverMenuItem(
                    title: String(localized: "Changelog"),
                    systemImage: "clock.arrow.trianglehead.2.counterclockwise.rotate.90"
                ) {
                    if let url = URL(string: "https://github.com/\(ReleaseFeed.repository)/releases") {
                        openURL(url)
                    }
                },
                PopoverMenuItem(title: String(localized: "About Tinycast"), systemImage: "info.circle") {
                    core.settingsCoordinator.showAbout()
                },
                PopoverMenuItem(title: String(localized: "Support Tinycast"), systemImage: "heart") {
                    core.supportCoordinator.showSupport()
                },
                PopoverMenuItem(
                    title: String(localized: "Settings"), systemImage: "gearshape", shortcut: "⌘,"
                ) {
                    core.settingsCoordinator.showSettings()
                },
                PopoverMenuItem(
                    title: String(localized: "Quit \(appName)"),
                    systemImage: "rectangle.portrait.and.arrow.right",
                    isDestructive: true
                ) {
                    NSApp.terminate(nil)
                }
            ])
    }
}
