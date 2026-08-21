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
