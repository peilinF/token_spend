import AppKit
import Foundation
import Combine

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var period: Period {
        didSet {
            UserDefaults.standard.set(period.rawValue, forKey: "period")
            lastSummaryVersion = -1
            recompute()
        }
    }
    @Published var mode: UsageMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "mode")
            lastSummaryVersion = -1
            recompute()
        }
    }
    @Published private(set) var summary: PeriodSummary?
    @Published private(set) var cursorAuth: CursorAuthState = CursorSource.lastAuthState
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var cursorLastSync: Date?
    // Do not add liveRates / +xx/m. Product decision: no per-minute token rate.
    @Published private(set) var activeTools: Set<Tool> = []
    @Published private(set) var activeSince: [Tool: Date] = [:]
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
    private let activityWatcher = ActivityWatcher()
    private var localTimer: Timer?
    private var cursorTimer: Timer?
    private var liveTimer: Timer?
    private var waitTimer: Timer?
    private var reconcileTimer: Timer?
    private var expiryTimer: Timer?
    private var isPolling = false
    private var isWaitingPolling = false
    private var waitingSince: [Tool: Date] = [:]
    private var lastSeenActivity: [Tool: Date] = [:]
    private var opencodeIdleStrikes = 0
    // Must outlast the 3s live poll. 1.8s caused the green arc to blink off
    // between polls whenever the WAL was quiet during thinking.
    private let quietTimeout: TimeInterval = 14
    private var cursorFailures = 0
    private var cursorNextAttempt = Date.distantPast
    private var lastCursorRefresh = Date.distantPast
    private var isRefreshingCursor = false
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
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                AppState.shared.recomputeActiveTools()
            }
        }
        activityWatcher.onActivity = { tool in
            Task { @MainActor in AppState.shared.markSeen(tool) }
        }
        activityWatcher.start()
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
        await refreshLocalSources(overlapMS: 120_000)
        lastUpdated = Date()
    }

    private func refreshLocalSources(overlapMS: Int64) async {
        let store = self.store
        try? await Task.detached(priority: .utility) {
            try OpenCodeSource.refresh(store: store, overlapMS: overlapMS)
            try CodexSource.refresh(store: store)
        }.value
        recompute()
    }

    func markSeen(_ tool: Tool) {
        // Coalesce bursts: WAL writes can fire dozens of events per second.
        if let last = lastSeenActivity[tool], Date().timeIntervalSince(last) < 0.3 { return }
        lastSeenActivity[tool] = Date()
        recomputeActiveTools()
    }

    private func recomputeActiveTools() {
        let now = Date()
        let effective = Set(lastSeenActivity.filter { now.timeIntervalSince($0.value) < quietTimeout }.map(\.key))
        guard effective != activeTools else { return }
        for tool in effective where activeSince[tool] == nil {
            activeSince[tool] = now
        }
        for tool in activeSince.keys where !effective.contains(tool) {
            activeSince.removeValue(forKey: tool)
        }
        activeTools = effective
    }

    func pollLive() async {
        guard !isPolling else { return }
        isPolling = true
        defer { isPolling = false }

        let store = self.store
        let activity = try? await Task.detached(priority: .utility) { () -> Set<Tool> in
            var active: Set<Tool> = []
            if OpenCodeSource.isActive(within: 4) { active.insert(.opencode) }
            if CodexSource.isActive(within: 4) { active.insert(.codex) }
            // 12s only guards the legacy fallback for cursor logs without
            // streamFromAgentBackend spans; turn spans decide otherwise.
            if CursorSource.isActive(within: 12) { active.insert(.cursor) }
            return active
        }.value
        if let activity {
            let now = Date()
            for tool in activity {
                lastSeenActivity[tool] = now
            }
            // Turn-level completion is definitive: drop the tool now instead of
            // letting quietTimeout keep the arc lit for another 14s.
            if !activity.contains(.codex) { lastSeenActivity.removeValue(forKey: .codex) }
            if !activity.contains(.cursor) { lastSeenActivity.removeValue(forKey: .cursor) }
            if activity.contains(.opencode) {
                opencodeIdleStrikes = 0
            } else {
                // "No running part" is heuristic, so confirm idle twice.
                opencodeIdleStrikes += 1
                if opencodeIdleStrikes >= 2 { lastSeenActivity.removeValue(forKey: .opencode) }
            }
            recomputeActiveTools()
            if activeTools.contains(.cursor),
               Date().timeIntervalSince(lastCursorRefresh) >= cursorActiveInterval,
               Date() >= cursorNextAttempt {
                lastCursorRefresh = Date()
                Task { await AppState.shared.refreshCursor() }
            }
        }

        await refreshLocalSources(overlapMS: 15_000)
        // No recordLiveSample / +xx/m. Rate UI was removed on purpose.
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
        // No per-minute rate sampling. Do not restore liveRates / +xx/m.
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

    private var lastSummaryVersion = -1
    private var lastSummaryDay = ""
    private var lastRecomputeAt = Date.distantPast

    func recompute() {
        let now = Date()
        let day = Fmt.day(now)
        let version = store.dataVersion
        // Skip the SQL + summary rebuild when usage data is unchanged; still
        // refresh time-based bits (ring progress, day rollover) once a minute.
        if version == lastSummaryVersion, day == lastSummaryDay,
           now.timeIntervalSince(lastRecomputeAt) < 60, summary != nil { return }
        lastSummaryVersion = version
        lastSummaryDay = day
        lastRecomputeAt = now
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
