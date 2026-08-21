import Foundation
import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "launch_at_login") }
        set {
            UserDefaults.standard.set(newValue, forKey: "launch_at_login")
            apply(newValue)
        }
    }

    private static func apply(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("TokenSpend launch-at-login failed: \(error.localizedDescription)")
        }
    }
}
