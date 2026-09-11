import Foundation

enum Tool: String, CaseIterable, Codable {
    case opencode
    case codex
    case cursor

    var displayName: String {
        switch self {
        case .opencode: return "opencode"
        case .codex: return "codex"
        case .cursor: return "cursor"
        }
    }
}

enum UsageMode: String, CaseIterable, Codable {
    case lean
    case full

    var displayName: String {
        switch self {
        case .lean: return "精简"
        case .full: return "全量"
        }
    }

    var explanation: String {
        switch self {
        case .lean: return "input(不含cache) + output"
        case .full: return "含 cache read/write"
        }
    }
}

enum Period: String, CaseIterable, Codable {
    case day
    case week
    case month
    case year

    var displayName: String {
        switch self {
        case .day: return "今日"
        case .week: return "本周"
        case .month: return "本月"
        case .year: return "今年"
        }
    }

    var shortName: String {
        switch self {
        case .day: return "日"
        case .week: return "周"
        case .month: return "月"
        case .year: return "年"
        }
    }
}

struct UsageAmount: AdditiveArithmetic {
    var input: Int64 = 0
    var output: Int64 = 0
    var cacheRead: Int64 = 0
    var cacheWrite: Int64 = 0
    var cost: Double = 0

    static var zero: UsageAmount { UsageAmount() }

    static func + (lhs: UsageAmount, rhs: UsageAmount) -> UsageAmount {
        var r = lhs
        r.input += rhs.input
        r.output += rhs.output
        r.cacheRead += rhs.cacheRead
        r.cacheWrite += rhs.cacheWrite
        r.cost += rhs.cost
        return r
    }

    static func - (lhs: UsageAmount, rhs: UsageAmount) -> UsageAmount {
        var r = lhs
        r.input -= rhs.input
        r.output -= rhs.output
        r.cacheRead -= rhs.cacheRead
        r.cacheWrite -= rhs.cacheWrite
        r.cost -= rhs.cost
        return r
    }

    static func * (lhs: UsageAmount, rhs: Double) -> UsageAmount {
        var r = lhs
        r.input = Int64(Double(r.input) * rhs)
        r.output = Int64(Double(r.output) * rhs)
        r.cacheRead = Int64(Double(r.cacheRead) * rhs)
        r.cacheWrite = Int64(Double(r.cacheWrite) * rhs)
        r.cost *= rhs
        return r
    }

    func total(mode: UsageMode) -> Int64 {
        switch mode {
        case .lean: return input + output
        case .full: return input + output + cacheRead + cacheWrite
        }
    }
}

enum Pricing {
    /// USD per 1M tokens. Set via `defaults write com.peilin.tokenspend
    /// price_input_per_1m -float 1.5`. Zero (default) = off.
    static var inputPer1M: Double {
        UserDefaults.standard.object(forKey: PrefKeys.priceInputPer1M) as? Double ?? 0
    }
    static var outputPer1M: Double {
        UserDefaults.standard.object(forKey: PrefKeys.priceOutputPer1M) as? Double ?? 0
    }
    static var isConfigured: Bool { inputPer1M > 0 || outputPer1M > 0 }

    /// Codex token_count events carry no cost field, so codex rows always
    /// total $0 without this display-only estimate. Never touches the store.
    static func codexEstimate(for amount: UsageAmount) -> UsageAmount {
        guard amount.cost == 0, isConfigured else { return amount }
        var estimated = amount
        estimated.cost = Double(amount.input) / 1_000_000 * inputPer1M
            + Double(amount.output) / 1_000_000 * outputPer1M
        return estimated
    }
}

enum WaitingKind: Equatable {
    case question
    case permission
    case stalled

    var label: String {
        switch self {
        case .question: return "等你回答"
        case .permission: return "等你授权"
        case .stalled: return "疑似等待确认"
        }
    }

    var priority: Int {
        switch self {
        case .question: return 0
        case .permission: return 1
        case .stalled: return 2
        }
    }
}

struct WaitingInfo: Equatable {
    let kind: WaitingKind
    let since: Date
}

struct ToolSummary: Identifiable {
    let tool: Tool
    let amount: UsageAmount
    var id: String { tool.rawValue }
}

struct DayBucket: Identifiable {
    let date: Date
    let dayString: String
    let amounts: [Tool: UsageAmount]
    var id: String { dayString }
}

struct PeriodSummary {
    let period: Period
    let start: Date
    let end: Date
    let progress: Double
    let perTool: [ToolSummary]
    let daily: [DayBucket]

    func amount(for tool: Tool) -> UsageAmount {
        perTool.first { $0.tool == tool }?.amount ?? .zero
    }

    var total: UsageAmount {
        perTool.reduce(.zero) { $0 + $1.amount }
    }
}

enum QuotaDisplayMode: String {
    case always
    case hover
    case hidden
}

struct QuotaWindow: Equatable {
    var usedPercent: Double
    var windowMinutes: Int?
    var resetsAt: Date?

    var leftPercent: Double {
        min(100, max(0, 100 - usedPercent))
    }

    var shortLabel: String {
        guard let minutes = windowMinutes, minutes > 0 else { return "额度" }
        if minutes < 1440 { return "\(minutes / 60)h" }
        return "\(minutes / 1440)d"
    }

    var resetText: String {
        guard let resetsAt else { return "" }
        if (windowMinutes ?? 0) < 1440 {
            return Fmt.time(resetsAt) + " 重置"
        }
        return Fmt.shortDate(resetsAt) + " 重置"
    }
}

struct CodexQuota: Equatable {
    /// Short window (5h when the plan has it). Nil on plans without one.
    var primary: QuotaWindow?
    /// Long window (weekly when the plan has it).
    var secondary: QuotaWindow?
    var planType: String?
    var creditsBalance: String?

    // Snapshots arrive per limit family ("codex", "premium", model-specific
    // ones), and their shape drifts: primary sometimes carries the 5h window
    // and sometimes the weekly one, secondary is sometimes absent, and Pro+
    // plans may never have the 5h window. So decode classifies windows by
    // duration (short < 1 day, long otherwise) instead of trusting position.
    static func decode(fromJSON raw: String?) -> CodexQuota? {
        guard let raw, let data = raw.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let now = Date().timeIntervalSince1970
        let records = o.values.compactMap { $0 as? [String: Any] }
            .sorted {
                let r0 = rank($0), r1 = rank($1)
                if r0 != r1 { return r0 < r1 }
                // Deterministic pick among equal families: prefer more windows.
                return windowCount($0) > windowCount($1)
            }
        for record in records {
            let (short, long) = slots(of: record)
            let observed = (record["observed_ts"] as? NSNumber)?.doubleValue ?? 0
            // A window whose reset passed AND the server has spoken since is
            // definitively stale (e.g. the plan dropped the 5h window).
            // Without a newer observation we keep showing it (offline case).
            func fresh(_ w: [String: Any]?) -> QuotaWindow? {
                guard let w, let q = decodeWindow(w) else { return nil }
                if let r = q.resetsAt, observed > 0,
                   r.timeIntervalSince1970 < now, observed > r.timeIntervalSince1970 {
                    return nil
                }
                return q
            }
            let quota = CodexQuota(
                primary: fresh(short), secondary: fresh(long),
                planType: record["plan_type"] as? String,
                creditsBalance: (record["credits"] as? [String: Any])?["balance"] as? String
            )
            if quota.primary != nil || quota.secondary != nil { return quota }
        }
        return nil
    }

    /// Merge an incoming server snapshot into a stored per-family record.
    /// Windows merge per kind (short/long) with monotonic resets_at, so a
    /// late-arriving older-shaped event can never clobber a fresher window,
    /// and a missing kind keeps the stored value until it goes stale.
    /// Pure function (no I/O) so it stays unit-testable.
    static func mergeRateSnapshot(stored record: [String: Any], with incoming: [String: Any], observedTs: Double) -> [String: Any] {
        let (sShort, sLong) = slots(of: record)
        let (iShort, iLong) = slots(of: incoming)
        func pick(_ s: [String: Any]?, _ i: [String: Any]?) -> [String: Any]? {
            guard let i else { return s }
            guard let s else { return i }
            let ri = resetsAt(i), rs = resetsAt(s)
            // The server re-emits one logical window with resets_at jitter
            // of a few seconds (observed up to ~8s). A strictly-monotonic
            // compare lets a single outlier with resets_at seconds higher
            // block every fresher update for the whole window, so near-equal
            // resets count as the same window and the newer observation
            // wins; only a clearly later resets_at (the next window) also
            // wins, keeping the old anti-clobber guarantee.
            if abs(ri - rs) <= 120 { return i }
            return ri > rs ? i : s
        }
        var out: [String: Any] = [
            "observed_ts": max((record["observed_ts"] as? NSNumber)?.doubleValue ?? 0, observedTs)
        ]
        if let w = pick(sShort, iShort) { out["short"] = w }
        if let w = pick(sLong, iLong) { out["long"] = w }
        for key in ["limit_id", "limit_name", "plan_type", "credits"] {
            if let v = incoming[key] ?? record[key] { out[key] = v }
        }
        return out
    }

    private static func windowCount(_ record: [String: Any]) -> Int {
        let (s, l) = slots(of: record)
        return (s == nil ? 0 : 1) + (l == nil ? 0 : 1)
    }

    /// Normalize either stored form into (short, long): merged records use
    /// "short"/"long" slots; legacy raw server payloads use
    /// "primary"/"secondary" (classified by duration, not position).
    static func slots(of record: [String: Any]) -> (short: [String: Any]?, long: [String: Any]?) {
        if record["observed_ts"] != nil || record["short"] != nil || record["long"] != nil {
            return (asWindowDict(record["short"]), asWindowDict(record["long"]))
        }
        var short: [String: Any]?, long: [String: Any]?
        func place(_ w: [String: Any], positionalShort: Bool) {
            if isShort(w, positionalShort: positionalShort) {
                if short == nil { short = w }
            } else if long == nil {
                long = w
            }
        }
        if let w = asWindowDict(record["primary"]) { place(w, positionalShort: true) }
        if let w = asWindowDict(record["secondary"]) { place(w, positionalShort: false) }
        // Future-proof: any other dict values carrying usage windows.
        for (key, value) in record where key != "primary" && key != "secondary" {
            guard let w = asWindowDict(value), windowMinutes(w) != nil else { continue }
            place(w, positionalShort: true)
        }
        return (short, long)
    }

    private static func asWindowDict(_ value: Any?) -> [String: Any]? {
        guard let d = value as? [String: Any],
              (d["used_percent"] as? NSNumber) != nil else { return nil }
        return d
    }

    private static func windowMinutes(_ w: [String: Any]) -> Int? {
        (w["window_minutes"] as? NSNumber)?.intValue
    }

    private static func resetsAt(_ w: [String: Any]) -> Double {
        (w["resets_at"] as? NSNumber)?.doubleValue ?? 0
    }

    /// Short = sub-day window; unknown durations fall back to position.
    private static func isShort(_ w: [String: Any], positionalShort: Bool) -> Bool {
        if let m = windowMinutes(w) { return m < 1440 }
        return positionalShort
    }

    private static func rank(_ snapshot: [String: Any]) -> Int {
        (snapshot["limit_id"] as? String)?.lowercased() == "codex" ? 0 : 1
    }

    private static func decodeWindow(_ d: [String: Any]) -> QuotaWindow? {
        guard let used = (d["used_percent"] as? NSNumber)?.doubleValue else { return nil }
        return QuotaWindow(
            usedPercent: used,
            windowMinutes: (d["window_minutes"] as? NSNumber)?.intValue,
            resetsAt: (d["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        )
    }
}

struct CursorQuota: Equatable {
    var cycleStart: Date?
    var cycleEnd: Date?
    var totalPercentUsed: Double?
    var autoPercentUsed: Double?
    var apiPercentUsed: Double?
    var used: Int64?
    var limit: Int64?
    var bonus: Int64?

    static func decode(fromJSON raw: String?) -> CursorQuota? {
        guard let raw, let data = raw.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        guard let plan = (o["individualUsage"] as? [String: Any])?["plan"] as? [String: Any] else { return nil }
        let breakdown = plan["breakdown"] as? [String: Any]

        func pct(_ key: String) -> Double? {
            (plan[key] as? NSNumber)?.doubleValue
        }
        func date(_ key: String) -> Date? {
            (o[key] as? String).flatMap { Formatters.isoFractional.date(from: $0) }
        }
        var quota = CursorQuota(
            cycleStart: date("billingCycleStart"),
            cycleEnd: date("billingCycleEnd"),
            totalPercentUsed: pct("totalPercentUsed"),
            autoPercentUsed: pct("autoPercentUsed"),
            apiPercentUsed: pct("apiPercentUsed"),
            used: (plan["used"] as? NSNumber)?.int64Value,
            limit: (plan["limit"] as? NSNumber)?.int64Value,
            bonus: (breakdown?["bonus"] as? NSNumber)?.int64Value
        )
        if quota.totalPercentUsed == nil, quota.autoPercentUsed == nil, quota.apiPercentUsed == nil {
            return nil
        }
        if quota.totalPercentUsed == nil, let a = quota.autoPercentUsed ?? quota.apiPercentUsed {
            quota.totalPercentUsed = a
        }
        return quota
    }
}
