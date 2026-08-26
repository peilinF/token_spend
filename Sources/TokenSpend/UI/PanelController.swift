import AppKit
import Combine
import SwiftUI

final class PanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelController: ObservableObject {
    static let shared = PanelController()

    private(set) var circlePanel: PanelWindow!
    private(set) var detailPanel: PanelWindow!
    private(set) var settingsPanel: PanelWindow!
    private(set) var quotaPanel: PanelWindow!
    private var quotaHostingView: NSHostingView<QuotaStripView>!
    private var monitors: [AnyObject] = []
    private var moveObserver: NSObjectProtocol?
    private var occlusionObserver: NSObjectProtocol?
    private var fitCancellable: AnyCancellable?
    @Published private(set) var circleOccluded = false

    var state: AppState { AppState.shared }

    init() {
        setupCircle()
        setupDetail()
        setupSettings()
        setupQuota()
        installClickMonitors()
        observeMove()
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: circlePanel, queue: .main
        ) { [weak self] note in
            guard let self, let window = note.object as? NSWindow else { return }
            let occluded = !window.occlusionState.contains(.visible)
            Task { @MainActor in self.circleOccluded = occluded }
        }
        fitCancellable = AppState.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refitCircle() }
    }

    private func makePanel(_ content: NSView, size: NSSize, activating: Bool = false) -> PanelWindow {
        var mask: NSWindow.StyleMask = [.borderless]
        // The settings panel must activate the app, otherwise the system color
        // picker refuses to pop up from its ColorPicker swatches.
        if !activating { mask.insert(.nonactivatingPanel) }
        let panel = PanelWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: mask,
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = content
        return panel
    }

    private func setupCircle() {
        let view = NSHostingView(rootView: CircleView(state: state, panel: self))
        let size = view.fittingSize
        view.setFrameSize(size)
        circlePanel = makePanel(view, size: size)
        if let saved = loadOrigin(key: "circle_origin") {
            circlePanel.setFrameTopLeftPoint(saved)
            ensureOnScreen()
        } else {
            placeDefault()
        }
    }

    private func ensureOnScreen() {
        let frame = circlePanel.frame
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let stillVisible = screens.contains { screen in
            screen.visibleFrame.insetBy(dx: -40, dy: -40).intersects(frame)
        }
        guard !stillVisible else { return }

        let mouseLocation = NSEvent.mouseLocation
        let target = screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main ?? screens[0]
        let visible = target.visibleFrame
        var x = frame.minX
        var topY = frame.maxY
        x = max(visible.minX + 8, min(x, visible.maxX - frame.width - 8))
        topY = max(visible.minY + frame.height + 8, min(topY, visible.maxY - 8))
        circlePanel.setFrameTopLeftPoint(NSPoint(x: x, y: topY))
    }

    func showCircle() {
        ensureOnScreen()
        circlePanel.orderFrontRegardless()
        circleOccluded = false
        UserDefaults.standard.set(true, forKey: "show_circle")
    }

    private func placeDefault() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let frame = circlePanel.frame
        let topLeft = NSPoint(x: visible.maxX - frame.width - 24, y: visible.maxY - 8)
        circlePanel.setFrameTopLeftPoint(topLeft)
    }

    private func setupDetail() {
        let view = NSHostingView(rootView: DetailView(state: state))
        let size = view.fittingSize
        view.setFrameSize(size)
        detailPanel = makePanel(view, size: size)
    }

    private func setupSettings() {
        let view = NSHostingView(rootView: SettingsView(state: state))
        let size = view.fittingSize
        view.setFrameSize(size)
        settingsPanel = makePanel(view, size: size, activating: true)
    }

    private func setupQuota() {
        let view = NSHostingView(rootView: QuotaStripView(state: state))
        let size = view.fittingSize
        view.setFrameSize(size)
        quotaHostingView = view
        let panel = makePanel(view, size: size)
        panel.ignoresMouseEvents = true
        quotaPanel = panel
    }

    // Hover mode target: a click-through readout under the circle. It never
    // intercepts input, so it cannot get in the way of apps underneath.
    func setQuotaHover(_ hovering: Bool) {
        guard AppState.shared.quotaDisplayMode == .hover else { return }
        if hovering {
            positionQuota()
            quotaPanel.orderFrontRegardless()
        } else {
            quotaPanel.orderOut(nil)
        }
    }

    private func positionQuota() {
        let size = quotaHostingView.fittingSize
        quotaHostingView.setFrameSize(size)
        quotaPanel.setContentSize(size)
        let circle = circlePanel.frame
        guard let screen = circlePanel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame

        var x = circle.midX - size.width / 2
        x = max(visible.minX + 4, min(x, visible.maxX - size.width - 4))

        var y = circle.minY - size.height - 6
        y = max(visible.minY + 4, min(y, visible.maxY - size.height - 4))
        quotaPanel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func refitCircle() {
        if AppState.shared.quotaDisplayMode != .hover {
            quotaPanel.orderOut(nil)
        }
        guard let view = circlePanel.contentView as? NSHostingView<CircleView> else { return }
        let size = view.fittingSize
        guard abs(size.height - circlePanel.frame.height) > 0.5
                || abs(size.width - circlePanel.frame.width) > 0.5 else { return }
        let topLeft = NSPoint(x: circlePanel.frame.minX, y: circlePanel.frame.maxY)
        circlePanel.setContentSize(size)
        circlePanel.setFrameTopLeftPoint(topLeft)
    }

    func toggleSettings() {
        if settingsPanel.isVisible {
            hideSettings()
        } else {
            positionSettings()
            settingsPanel.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func hideSettings() {
        settingsPanel.orderOut(nil)
    }

    private func positionSettings() {
        let circle = circlePanel.frame
        let size = settingsPanel.frame.size
        guard let screen = circlePanel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame

        var x = circle.minX - size.width - 10
        if x < visible.minX + 4 {
            x = circle.maxX + 10
        }
        x = max(visible.minX + 4, min(x, visible.maxX - size.width - 4))

        var y = circle.midY + size.height / 2
        y = max(visible.minY + 4, min(y, visible.maxY - 4))
        settingsPanel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func hideCircle() {
        circlePanel.orderOut(nil)
        circleOccluded = true
        hideDetail()
        quotaPanel?.orderOut(nil)
        UserDefaults.standard.set(false, forKey: "show_circle")
    }

    var isCircleVisible: Bool { circlePanel.isVisible }

    func toggleDetail() {
        if detailPanel.isVisible {
            hideDetail()
        } else {
            positionDetail()
            detailPanel.orderFrontRegardless()
            Task { await state.refreshLocal() }
        }
    }

    func hideDetail() {
        detailPanel.orderOut(nil)
    }

    private func positionDetail() {
        let circle = circlePanel.frame
        let size = detailPanel.frame.size
        guard let screen = circlePanel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame

        var x = circle.maxX + 10
        if x + size.width > visible.maxX {
            x = circle.minX - size.width - 10
        }
        x = max(visible.minX + 4, min(x, visible.maxX - size.width - 4))

        var y = circle.midY + size.height / 2
        y = max(visible.minY + 4, min(y, visible.maxY - 4))
        detailPanel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func installClickMonitors() {
        let handler: (NSEvent) -> Void = { [weak self] _ in
            guard let self else { return }
            let location = NSEvent.mouseLocation
            let inCircle = self.circlePanel.isVisible && self.circlePanel.frame.contains(location)
            let inDetail = self.detailPanel.isVisible && self.detailPanel.frame.contains(location)
            let inSettings = self.settingsPanel.isVisible && self.settingsPanel.frame.contains(location)
            let colorPanel = NSColorPanel.shared
            let inColorPanel = colorPanel.isVisible && colorPanel.frame.contains(location)
            if !inCircle && !inDetail && !inSettings && !inColorPanel {
                self.hideDetail()
                self.hideSettings()
            }
        }
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler) as AnyObject)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { event in
            handler(event)
            return event
        }) as AnyObject)
    }

    private func observeMove() {
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: circlePanel, queue: .main
        ) { [weak self] _ in
            guard let self, let panel = self.circlePanel else { return }
            let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
            UserDefaults.standard.set("\(topLeft.x),\(topLeft.y)", forKey: "circle_origin")
        }
    }

    private func loadOrigin(key: String) -> NSPoint? {
        guard let raw = UserDefaults.standard.string(forKey: key) else { return nil }
        let parts = raw.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return NSPoint(x: parts[0], y: parts[1])
    }
}
