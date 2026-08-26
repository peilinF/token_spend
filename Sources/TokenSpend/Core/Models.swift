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

enum WaitingKind: Equatable {
    case question
    case stalled

    var label: String {
        switch self {
        case .question: return "等你回答"
        case .stalled: return "疑似等待确认"
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
        guard let minutes = windowMinutes, minutes > 0 else { return "5h" }
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
    var primary: QuotaWindow?
    var secondary: QuotaWindow?
    var planType: String?
    var creditsBalance: String?

    // Snapshots arrive per limit family ("codex", "premium", model-specific
    // ones). Prefer the main plan family, then any family with real windows.
    static func decode(fromJSON raw: String?) -> CodexQuota? {
        guard let raw, let data = raw.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let snapshots = o.values.compactMap { $0 as? [String: Any] }
        let ordered = snapshots.sorted { rank($0) < rank($1) }
        for snapshot in ordered {
            if let quota = decodeSnapshot(snapshot) { return quota }
        }
        return nil
    }

    private static func rank(_ snapshot: [String: Any]) -> Int {
        (snapshot["limit_id"] as? String)?.lowercased() == "codex" ? 0 : 1
    }

    private static func decodeSnapshot(_ o: [String: Any]) -> CodexQuota? {
        func window(_ value: Any?) -> QuotaWindow? {
            guard let d = value as? [String: Any],
                  let used = (d["used_percent"] as? NSNumber)?.doubleValue else { return nil }
            return QuotaWindow(
                usedPercent: used,
                windowMinutes: (d["window_minutes"] as? NSNumber)?.intValue,
                resetsAt: (d["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            )
        }
        let quota = CodexQuota(
            primary: window(o["primary"]),
            secondary: window(o["secondary"]),
            planType: o["plan_type"] as? String,
            creditsBalance: (o["credits"] as? [String: Any])?["balance"] as? String
        )
        return quota.primary != nil || quota.secondary != nil ? quota : nil
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
