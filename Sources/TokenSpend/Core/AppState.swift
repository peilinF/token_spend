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
            recompute()
        }
    }
    @Published var mode: UsageMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "mode")
            samples.removeAll()
            recompute()
        }
    }
    @Published private(set) var summary: PeriodSummary?
    @Published private(set) var cursorAuth: CursorAuthState = CursorSource.lastAuthState
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var liveRates: [Tool: Int64] = [:]
    @Published private(set) var activeTools: Set<Tool> = []
    @Published var isDetailVisible = false

    private let store = UsageStore.shared
    private var localTimer: Timer?
    private var cursorTimer: Timer?
    private var liveTimer: Timer?
    private var reconcileTimer: Timer?
    private var samples: [(date: Date, totals: [Tool: Int64])] = []
    private var isPolling = false
    private var cursorFailures = 0
    private var cursorNextAttempt = Date.distantPast
    private var lastWakeRefresh = Date.distantPast

    init() {
        period = Period(rawValue: UserDefaults.standard.string(forKey: "period") ?? "") ?? .day
        mode = UsageMode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .full
        recompute()
    }

    func startEngine() {
        localTimer?.invalidate()
        cursorTimer?.invalidate()
        liveTimer?.invalidate()
        reconcileTimer?.invalidate()
        localTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { await AppState.shared.refreshLocal() }
        }
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { await AppState.shared.refreshCursor() }
        }
        liveTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { await AppState.shared.pollLive() }
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
            try OpenCodeSource.refresh(store: store)
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
        if let activity, activity != activeTools {
            activeTools = activity
        }

        try? await Task.detached(priority: .utility) {
            try OpenCodeSource.refresh(store: store)
            try CodexSource.refresh(store: store)
        }.value
        recompute()

        let now = Date()
        let range = PeriodMath.range(of: period, now: now)
        let totals = store.dailyTotals(sinceDay: Fmt.day(range.start))
        var current: [Tool: Int64] = [:]
        for tool in Tool.allCases {
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
        if rates != liveRates {
            liveRates = rates
        }
    }

    func refreshCursor(force: Bool = false) async {
        if !force && Date() < cursorNextAttempt { return }
        let store = self.store
        do {
            let state = try await Task.detached(priority: .utility) {
                try await CursorSource.refresh(store: store)
            }.value
            cursorAuth = state
            cursorFailures = 0
            cursorNextAttempt = .distantPast
        } catch KeychainError.denied {
            cursorAuth = .keychainDenied
            applyCursorBackoff(seconds: 1800)
        } catch CursorSource.CursorAPIError.unauthorized {
            cursorAuth = .needsRelogin
            applyCursorBackoff(seconds: 900)
        } catch CursorSource.CursorAPIError.noCookie {
            cursorAuth = .needsRelogin
            applyCursorBackoff(seconds: 900)
        } catch {
            cursorFailures += 1
            cursorAuth = .error("网络错误，\(Int(min(300 * pow(2, Double(cursorFailures - 1)), 3600)) / 60) 分钟后重试")
            applyCursorBackoff(seconds: min(300 * pow(2, Double(cursorFailures - 1)), 3600))
        }
        recompute()
        lastUpdated = Date()
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
