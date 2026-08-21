import AppKit
import SwiftUI

final class PanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelController {
    static let shared = PanelController()

    private(set) var circlePanel: PanelWindow!
    private(set) var detailPanel: PanelWindow!
    private var monitors: [AnyObject] = []
    private var moveObserver: NSObjectProtocol?

    var state: AppState { AppState.shared }

    init() {
        setupCircle()
        setupDetail()
        installClickMonitors()
        observeMove()
    }

    private func makePanel(_ content: NSView, size: NSSize) -> PanelWindow {
        let panel = PanelWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
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
        let view = NSHostingView(rootView: CircleView(state: state))
        view.setFrameSize(NSSize(width: 92, height: 92))
        circlePanel = makePanel(view, size: NSSize(width: 92, height: 92))
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

    func hideCircle() {
        circlePanel.orderOut(nil)
        hideDetail()
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
            if !inCircle && !inDetail {
                self.hideDetail()
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
