import ServiceManagement

enum LaunchAtLogin {
    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    static func set(_ enabled: Bool) -> SMAppService.Status {
        let service = SMAppService.mainApp
        do {
            switch (enabled, service.status) {
            case (true, .notRegistered), (true, .notFound):
                try service.register()
            case (false, .enabled), (false, .requiresApproval):
                try service.unregister()
            case (_, let status):
                return status
            }
        } catch {
            NSLog("Tinycast: launch-at-login change failed: \(error.localizedDescription)")
        }
        return service.status
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
