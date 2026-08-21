import AppKit
import Foundation
import Combine

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var period: Period {
        didSet {
            UserDefaults.standard.set(period.rawValue, forKey: "period")
            samples.removeAll()
            cursorSyncSamples.removeAll()
            cursorHeldRate = nil
            recompute()
        }
    }
    @Published var mode: UsageMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "mode")
            samples.removeAll()
            cursorSyncSamples.removeAll()
            cursorHeldRate = nil
            recompute()
        }
    }
    @Published private(set) var summary: PeriodSummary?
    @Published private(set) var cursorAuth: CursorAuthState = CursorSource.lastAuthState
    @Published private(set) var cursorLastSync: Date?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var liveRates: [Tool: Int64] = [:]
    @Published private(set) var activeTools: Set<Tool> = []
    @Published private(set) var waiting: [Tool: WaitingInfo] = [:]
    @Published var isDetailVisible = false

    var waitThreshold: TimeInterval {
        get { UserDefaults.standard.object(forKey: "wait_threshold") as? TimeInterval ?? 60 }
        set { UserDefaults.standard.set(newValue, forKey: "wait_threshold") }
    }

    var cursorActiveInterval: TimeInterval {
        get { UserDefaults.standard.object(forKey: "cursor_active_interval") as? TimeInterval ?? 8 }
        set { UserDefaults.standard.set(newValue, forKey: "cursor_active_interval") }
    }

    private let store = UsageStore.shared
    private let waitMonitor = WaitingMonitor()
    private var localTimer: Timer?
    private var cursorTimer: Timer?
    private var liveTimer: Timer?
    private var waitTimer: Timer?
    private var reconcileTimer: Timer?
    private var samples: [(date: Date, totals: [Tool: Int64])] = []
    private var isPolling = false
    private var isWaitingPolling = false
    private var waitingSince: [Tool: Date] = [:]
    private var cursorFailures = 0
    private var cursorNextAttempt = Date.distantPast
    private var lastCursorRefresh = Date.distantPast
    private var isRefreshingCursor = false
    private var cursorSyncSamples: [(date: Date, total: Int64)] = []
    private var cursorHeldRate: Int64?
    private var lastWakeRefresh = Date.distantPast

    init() {
        period = Period(rawValue: UserDefaults.standard.string(forKey: "period") ?? "") ?? .day
        mode = UsageMode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .full
        if let raw = store.meta("cursor_last_sync"), let ts = Double(raw) {
            cursorLastSync = Date(timeIntervalSince1970: ts)
        }
        recompute()
    }

    func startEngine() {
        localTimer?.invalidate()
        cursorTimer?.invalidate()
        liveTimer?.invalidate()
        waitTimer?.invalidate()
        reconcileTimer?.invalidate()
        localTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { await AppState.shared.refreshLocal() }
        }
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { await AppState.shared.refreshCursor() }
        }
        liveTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { await AppState.shared.pollLive() }
        }
        waitTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { await AppState.shared.pollWaiting() }
        }
        reconcileTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { await AppState.shared.runReconcile() }
        }
        Task { await refreshAll() }
        Task {
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            await AppState.shared.runReconcile()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { await AppState.shared.handleWake() }
        }
    }

    func pollWaiting() async {
        guard !isWaitingPolling else { return }
        isWaitingPolling = true
        defer { isWaitingPolling = false }

        let monitor = self.waitMonitor
        let threshold = waitThreshold
        let detected = try? await Task.detached(priority: .utility) { () -> [Tool: WaitingKind] in
            monitor.poll(threshold: threshold)
        }.value
        applyWaiting(detected ?? [:])
    }

    func handleWake() async {
        guard Date().timeIntervalSince(lastWakeRefresh) > 60 else { return }
        lastWakeRefresh = Date()
        await refreshAll()
    }

    func runReconcile() async {
        let store = self.store
        try? await Task.detached(priority: .utility) {
            OpenCodeSource.reconcile(store: store)
            CodexSource.reconcile(store: store)
        }.value
        recompute()
    }

    func refreshAll(force: Bool = false) async {
        await refreshLocal()
        await refreshCursor(force: force)
    }

    func refreshLocal() async {
        let store = self.store
        try? await Task.detached(priority: .utility) {
            try OpenCodeSource.refresh(store: store, overlapMS: 120_000)
            try CodexSource.refresh(store: store)
        }.value
        recompute()
        lastUpdated = Date()
    }

    func pollLive() async {
        guard !isPolling else { return }
        isPolling = true
        defer { isPolling = false }

        let store = self.store
        let activity = try? await Task.detached(priority: .utility) { () -> Set<Tool> in
            var active: Set<Tool> = []
            if OpenCodeSource.isActive(within: 12) { active.insert(.opencode) }
            if CodexSource.isActive(within: 12) { active.insert(.codex) }
            if CursorSource.isActive(within: 12) { active.insert(.cursor) }
            return active
        }.value
        if let activity {
            if activity != activeTools {
                activeTools = activity
            }
            if activity.contains(.cursor),
               Date().timeIntervalSince(lastCursorRefresh) >= cursorActiveInterval,
               Date() >= cursorNextAttempt {
                lastCursorRefresh = Date()
                Task { await AppState.shared.refreshCursor() }
            }
        }

        try? await Task.detached(priority: .utility) {
            try OpenCodeSource.refresh(store: store, overlapMS: 15_000)
            try CodexSource.refresh(store: store)
        }.value
        recompute()
        recordLiveSample()
    }

    func refreshCursor(force: Bool = false) async {
        if !force && Date() < cursorNextAttempt { return }
        if isRefreshingCursor && !force { return }
        isRefreshingCursor = true
        lastCursorRefresh = Date()
        defer { isRefreshingCursor = false }

        let store = self.store
        do {
            let state = try await Task.detached(priority: .utility) {
                try await CursorSource.refresh(store: store)
            }.value
            cursorAuth = state
            cursorLastSync = Date()
            cursorFailures = 0
            cursorNextAttempt = .distantPast
            recordCursorSnapshot()
        } catch KeychainError.denied {
            cursorAuth = .keychainDenied
            applyCursorBackoff(seconds: 1800)
        } catch CursorSource.CursorAPIError.unauthorized {
            cursorAuth = .needsRelogin
            applyCursorBackoff(seconds: 900)
        } catch CursorSource.CursorAPIError.noCookie {
            cursorAuth = CursorSource.lastAuthState == .noChrome ? .noChrome : .needsRelogin
            applyCursorBackoff(seconds: 900)
        } catch CursorSource.CursorAPIError.unsupportedCookie {
            cursorAuth = .unsupportedCookie
            applyCursorBackoff(seconds: 900)
        } catch {
            cursorFailures += 1
            cursorAuth = .error("网络错误，\(Int(min(300 * pow(2, Double(cursorFailures - 1)), 3600)) / 60) 分钟后重试")
            applyCursorBackoff(seconds: min(300 * pow(2, Double(cursorFailures - 1)), 3600))
        }
        recompute()
        lastUpdated = Date()
        recordLiveSample()
    }

    private func recordLiveSample() {
        let now = Date()
        let range = PeriodMath.range(of: period, now: now)
        let totals = store.dailyTotals(sinceDay: Fmt.day(range.start))
        var current: [Tool: Int64] = [:]
        for tool in Tool.allCases where tool != .cursor {
            let sum = (totals[tool]?.values.reduce(.zero, +) ?? .zero).total(mode: mode)
            current[tool] = sum
        }

        samples.append((now, current))
        samples = samples.filter { now.timeIntervalSince($0.date) < 90 }

        var rates: [Tool: Int64] = [:]
        if let oldest = samples.first, now.timeIntervalSince(oldest.date) >= 8 {
            let minutes = now.timeIntervalSince(oldest.date) / 60
            for (tool, value) in current {
                let delta = value - (oldest.totals[tool] ?? 0)
                if delta > 0 {
                    rates[tool] = Int64(Double(delta) / minutes)
                }
            }
        }
        if let held = cursorHeldRate, held > 0 {
            rates[.cursor] = held
        }
        if rates != liveRates {
            liveRates = rates
        }
    }

    private func recordCursorSnapshot() {
        let now = Date()
        let range = PeriodMath.range(of: period, now: now)
        let totals = store.dailyTotals(sinceDay: Fmt.day(range.start))
        let total = (totals[.cursor]?.values.reduce(.zero, +) ?? .zero).total(mode: mode)

        cursorSyncSamples.append((now, total))
        cursorSyncSamples = cursorSyncSamples.filter { now.timeIntervalSince($0.date) < 300 }

        guard let oldest = cursorSyncSamples.first else { return }
        let elapsed = now.timeIntervalSince(oldest.date)
        guard elapsed >= 8 else { return }
        let delta = total - oldest.total

        if delta < 0 {
            cursorSyncSamples = [(now, total)]
            cursorHeldRate = nil
        } else if delta > 0 {
            cursorHeldRate = Int64(Double(delta) / (elapsed / 60))
        } else if !activeTools.contains(.cursor) {
            cursorHeldRate = nil
        }
    }

    private func applyWaiting(_ detected: [Tool: WaitingKind]) {
        var result: [Tool: WaitingInfo] = [:]
        for (tool, kind) in detected {
            let since = waitingSince[tool] ?? Date()
            waitingSince[tool] = since
            result[tool] = WaitingInfo(kind: kind, since: since)
        }
        for tool in waitingSince.keys where detected[tool] == nil {
            waitingSince.removeValue(forKey: tool)
        }
        if result != waiting {
            waiting = result
        }
    }

    private func applyCursorBackoff(seconds: TimeInterval) {
        cursorNextAttempt = Date().addingTimeInterval(seconds)
    }

    func recompute() {
        let now = Date()
        let range = PeriodMath.range(of: period, now: now)
        let calendar = Calendar.current

        guard var cursor = calendar.dateComponents([.day], from: range.start, to: now).day, cursor >= 0 else {
            summary = nil
            return
        }
        cursor += 1

        let totals = store.dailyTotals(sinceDay: Fmt.day(range.start))
        var perToolAmounts: [Tool: UsageAmount] = [:]
        var buckets: [DayBucket] = []

        for offset in 0..<cursor {
            guard let date = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: range.start)) else { continue }
            let key = Fmt.day(date)
            var amounts: [Tool: UsageAmount] = [:]
            for tool in Tool.allCases {
                let amount = totals[tool]?[key] ?? .zero
                amounts[tool] = amount
                perToolAmounts[tool, default: .zero] = perToolAmounts[tool, default: .zero] + amount
            }
            buckets.append(DayBucket(date: date, dayString: key, amounts: amounts))
        }

        let summaries = Tool.allCases.map { ToolSummary(tool: $0, amount: perToolAmounts[$0] ?? .zero) }
        summary = PeriodSummary(period: period, start: range.start, end: range.end, progress: range.progress, perTool: summaries, daily: buckets)
    }

    func toggleDetail(circleFrame: NSRect, place: (NSRect) -> Void) {
        isDetailVisible.toggle()
    }
}
