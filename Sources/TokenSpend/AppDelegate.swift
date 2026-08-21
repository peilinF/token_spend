import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        _ = PanelController.shared
        if UserDefaults.standard.object(forKey: "show_circle") as? Bool ?? true {
            PanelController.shared.showCircle()
        }
        StatusBarController.shared.install()
        AppState.shared.startEngine()
    }
}
