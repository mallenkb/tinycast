import SwiftUI
import OSLog

@main
enum TinycastLaunch {
    @MainActor static func main() {
        guard let storageLease = acquireStorageLease() else { return }
        defer { close(storageLease) }
        AppSettings.pinLanguage()
        TinycastApp.main()
    }

    @MainActor private static func acquireStorageLease() -> Int32? {
        let path = AppPaths.applicationSupport().appending(path: ".instance.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }
        var requested: Set<pid_t> = []
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            let peers = NSWorkspace.shared.runningApplications.filter {
                $0.processIdentifier != getpid()
                    && AppPaths.storageIdentifier(for: $0.bundleIdentifier ?? "") == AppPaths.storageIdentifier
            }
            let acquired = flock(descriptor, LOCK_EX | LOCK_NB) == 0
            if acquired, peers.isEmpty { return descriptor }
            if !acquired, peers.allSatisfy({ !$0.isFinishedLaunching }) {
                close(descriptor)
                return nil
            }
            for peer in peers where peer.isFinishedLaunching && !requested.contains(peer.processIdentifier) {
                requested.insert(peer.processIdentifier)
                peer.terminate()
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        close(descriptor)
        Logger(subsystem: "com.tinycast.app", category: "Launch")
            .error("Shared storage is still in use; leaving the running app open.")
        return nil
    }
}

struct TinycastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    private let appName = Bundle.main.appDisplayName

    /// Two independent items: one preference each, no state either can read off the other.
    var body: some Scene {
        MenuBarExtra(isInserted: menuBarInsertion) {
            MenuBarMenu(appName: appName)
        } label: {
            MenuBarLabel(appName: appName)
        }
        .commands { menuBarCommands }

        MenuBarExtra(isInserted: calendarMenuBarInsertion) {
            CalendarMenuBarMenu()
        } label: {
            CalendarMenuBarLabel(appName: appName)
        }
    }

    /// Read in `body` for Observation; SwiftUI echoes the binding back, so only a change writes.
    private var menuBarInsertion: Binding<Bool> {
        let settings = AppCore.shared.settings
        let isInserted = settings.showInMenuBar
        return Binding(
            get: { isInserted },
            set: { inserted in
                guard inserted != settings.showInMenuBar else { return }
                settings.showInMenuBar = inserted
            })
    }

    /// Writes through `AppSettings`: dragging the item out must stop the clock and move the picker.
    private var calendarMenuBarInsertion: Binding<Bool> {
        let settings = AppCore.shared.settings
        let isInserted = settings.calendarMenuBarDisplay != .disabled && !isCalendarMenuBarHiddenWhenEmpty
        return Binding(
            get: { isInserted },
            set: { inserted in
                if inserted {
                    guard settings.calendarMenuBarDisplay == .disabled else { return }
                    settings.calendarMenuBarDisplay = .meetingIcon
                } else {
                    // SwiftUI echoes our own removal back; only a drag-out means "turn it off".
                    guard !isCalendarMenuBarHiddenWhenEmpty, settings.calendarMenuBarDisplay != .disabled
                    else { return }
                    settings.calendarMenuBarDisplay = .disabled
                }
            })
    }

    /// Read in `body`, so Observation re-runs the scene when the coordinator's flag flips.
    private var isCalendarMenuBarHiddenWhenEmpty: Bool {
        AppCore.shared.settings.calendarMenuBarHidesWhenEmpty
            && !AppCore.shared.calendarCoordinator.hasMenuBarEvent
    }

    /// Declared, not assigned to `NSApp.mainMenu`: SwiftUI rebuilds the menu on any scene change.
    @CommandsBuilder
    private var menuBarCommands: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About \(appName)") { AppCore.shared.settingsCoordinator.showAbout() }
            Button("Check for Updates…") { AppCore.shared.updateCoordinator.checkForUpdates() }
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { AppCore.shared.settingsCoordinator.showSettings() }
                .keyboardShortcut(",")
        }
        CommandGroup(replacing: .appTermination) {
            Button("Close Window") {
                // The chat window closes itself when it is in front; otherwise ⌘Q is Settings'.
                guard !AppCore.shared.aiChatCoordinator.closeWindowIfKey() else { return }
                AppCore.shared.settingsCoordinator.closeSettings()
            }
            .keyboardShortcut("q")
        }
    }
}
