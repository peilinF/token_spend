import Foundation

enum Fmt {
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let fmtLock = NSLock()

    static func day(_ date: Date) -> String {
        fmtLock.lock()
        defer { fmtLock.unlock() }
        return dayFormatter.string(from: date)
    }

    static func tokens(_ n: Int64) -> String {
        let v = Double(n)
        if v < 1000 { return "\(n)" }
        if v < 1_000_000 { return trim(v / 1_000) + "k" }
        if v < 1_000_000_000 { return trim(v / 1_000_000) + "M" }
        return trim(v / 1_000_000_000) + "B"
    }

    private static func trim(_ v: Double) -> String {
        if v >= 100 { return String(format: "%.0f", v) }
        if v >= 10 { return String(format: "%.1f", v) }
        return String(format: "%.2f", v)
    }

    static func money(_ v: Double) -> String {
        if v <= 0 { return "" }
        if v < 1 { return "$" + String(format: "%.2f", v) }
        return "$" + String(format: "%.2f", v)
    }

    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    static func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd"
        return f.string(from: date)
    }
}

enum PeriodMath {
    static func range(of period: Period, now: Date = Date(), calendar: Calendar = .current) -> (start: Date, end: Date, progress: Double) {
        let dayStart = calendar.startOfDay(for: now)
        switch period {
        case .day:
            let end = nextDayStart(from: dayStart, calendar: calendar)
            return (dayStart, end, fraction(now, dayStart, end))
        case .week:
            let weekday = calendar.component(.weekday, from: dayStart)
            let daysSinceMonday = (weekday + 5) % 7
            let start = calendar.date(byAdding: .day, value: -daysSinceMonday, to: dayStart)!
            let end = calendar.date(byAdding: .day, value: 7, to: start)!
            return (start, end, fraction(now, start, end))
        case .month:
            let comps = calendar.dateComponents([.year, .month], from: now)
            let start = calendar.date(from: comps)!
            let end = nextDayStart(from: calendar.date(byAdding: DateComponents(month: 1, day: 0), to: start)!, calendar: calendar)
            let monthEnd = calendar.date(byAdding: DateComponents(month: 1), to: start)!
            return (start, monthEnd, fraction(now, start, monthEnd))
        case .year:
            let comps = calendar.dateComponents([.year], from: now)
            let start = calendar.date(from: comps)!
            let end = calendar.date(byAdding: DateComponents(year: 1), to: start)!
            return (start, end, fraction(now, start, end))
        }
    }

    static func nextDayStart(from date: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))!
    }

    private static func fraction(_ now: Date, _ start: Date, _ end: Date) -> Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return min(1, max(0, now.timeIntervalSince(start) / total))
    }
}
