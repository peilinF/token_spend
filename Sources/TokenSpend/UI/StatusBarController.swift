import AppKit
import Combine

@MainActor
final class StatusBarController {
    static let shared = StatusBarController()

    private var statusItem: NSStatusItem?
    private var cancellable: AnyCancellable?

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "chart.donut.fill", accessibilityDescription: "TokenSpend")
        item.menu = buildMenu()
        statusItem = item

        cancellable = AppState.shared.$waiting
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshIcon()
                self?.rebuild()
            }
    }

    private func refreshIcon() {
        guard let button = statusItem?.button else { return }
        if AppState.shared.waiting.isEmpty {
            button.image = NSImage(systemSymbolName: "chart.donut.fill", accessibilityDescription: "TokenSpend")
            button.contentTintColor = nil
        } else {
            let asking = AppState.shared.waiting.values.contains { $0.kind == .question }
            button.image = NSImage(
                systemSymbolName: "exclamationmark.circle.fill",
                accessibilityDescription: asking ? "TokenSpend 等你回答" : "TokenSpend 等待确认"
            )
            button.contentTintColor = .systemOrange
        }
    }

    private func buildMenu() -> NSMenu {
        let state = AppState.shared
        let menu = NSMenu()

        let waiting = state.waiting
        if !waiting.isEmpty {
            let summary = waiting
                .sorted(by: { $0.key.rawValue < $1.key.rawValue })
                .map { tool, info in "\(tool.displayName)·\(info.kind == .question ? "答" : "疑")" }
                .joined(separator: " / ")
            let statusLine = NSMenuItem(
                title: "⏳ \(waiting.count) 个在等：\(summary)",
                action: nil, keyEquivalent: ""
            )
            statusLine.isEnabled = false
            menu.addItem(statusLine)
            menu.addItem(.separator())
        }

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

        let thresholdItem = NSMenuItem(title: "等待检测阈值", action: nil, keyEquivalent: "")
        let thresholdMenu = NSMenu()
        for seconds in [30.0, 60.0, 120.0] {
            let sub = NSMenuItem(
                title: AppState.shared.waitThreshold == seconds ? "✓ \(Int(seconds))s" : "\(Int(seconds))s",
                action: #selector(selectThreshold(_:)), keyEquivalent: ""
            )
            sub.target = self
            sub.representedObject = seconds
            thresholdMenu.addItem(sub)
        }
        thresholdItem.submenu = thresholdMenu
        menu.addItem(thresholdItem)

        let syncItem = NSMenuItem(title: "Cursor 活跃同步间隔", action: nil, keyEquivalent: "")
        let syncMenu = NSMenu()
        for seconds in [3.0, 8.0, 15.0, 30.0] {
            let sub = NSMenuItem(
                title: AppState.shared.cursorActiveInterval == seconds ? "✓ \(Int(seconds))s" : "\(Int(seconds))s",
                action: #selector(selectCursorInterval(_:)), keyEquivalent: ""
            )
            sub.target = self
            sub.representedObject = seconds
            syncMenu.addItem(sub)
        }
        syncItem.submenu = syncMenu
        menu.addItem(syncItem)

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

    @objc private func selectThreshold(_ sender: NSMenuItem) {
        if let seconds = sender.representedObject as? Double {
            AppState.shared.waitThreshold = seconds
        }
        rebuild()
    }

    @objc private func selectCursorInterval(_ sender: NSMenuItem) {
        if let seconds = sender.representedObject as? Double {
            AppState.shared.cursorActiveInterval = seconds
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
