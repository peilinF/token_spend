import AppKit

@MainActor
final class StatusBarController {
    static let shared = StatusBarController()

    private var statusItem: NSStatusItem?

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "chart.donut.fill", accessibilityDescription: "TokenSpend")
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let state = AppState.shared
        let menu = NSMenu()

        for period in Period.allCases {
            let item = NSMenuItem(title: period.displayName, action: #selector(selectPeriod(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = period.rawValue
            item.state = state.period == period ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())

        for mode in UsageMode.allCases {
            let item = NSMenuItem(title: "口径：" + mode.displayName, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = state.mode == mode ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let showItem = NSMenuItem(title: "显示悬浮窗", action: #selector(toggleCircle(_:)), keyEquivalent: "")
        showItem.target = self
        showItem.state = PanelController.shared.isCircleVisible ? .on : .off
        menu.addItem(showItem)

        let loginItem = NSMenuItem(title: "开机自启", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(loginItem)

        let refreshItem = NSMenuItem(title: "立即刷新", action: #selector(refreshNow(_:)), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 TokenSpend", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        menu.autoenablesItems = false
        return menu
    }

    func rebuild() {
        statusItem?.menu = buildMenu()
    }

    @objc private func selectPeriod(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let period = Period(rawValue: raw) {
            AppState.shared.period = period
        }
        rebuild()
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = UsageMode(rawValue: raw) {
            AppState.shared.mode = mode
        }
        rebuild()
    }

    @objc private func toggleCircle(_ sender: NSMenuItem) {
        if PanelController.shared.isCircleVisible {
            PanelController.shared.hideCircle()
        } else {
            PanelController.shared.showCircle()
        }
        rebuild()
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        LaunchAtLogin.isEnabled.toggle()
        rebuild()
    }

    @objc private func refreshNow(_ sender: NSMenuItem) {
        Task { await AppState.shared.refreshAll(force: true) }
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }
}
