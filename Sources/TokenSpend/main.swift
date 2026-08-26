import AppKit
import Foundation

let arguments = CommandLine.arguments

if arguments.contains("--print-summary") {
    CliMain.run()
    exit(0)
}

if arguments.contains("--reconcile") {
    let store = UsageStore.shared
    OpenCodeSource.reconcile(store: store)
    CodexSource.reconcile(store: store)
    print("reconcile done")
    exit(0)
}

if arguments.contains("--print-waiting") {
    let threshold = UserDefaults.standard.object(forKey: "wait_threshold") as? TimeInterval ?? 60
    let detected = WaitingDetector.detect(threshold: threshold)
    if detected.isEmpty {
        print("waiting: none")
    } else {
        for (tool, kind) in detected.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            print("waiting \(tool.rawValue): \(kind.label)")
        }
    }
    exit(0)
}

if arguments.contains("--print-quota") {
    let store = UsageStore.shared
    if let quota = CodexQuota.decode(fromJSON: store.meta("codex_rate_limits")) {
        var windows: [String] = []
        if let w = quota.primary { windows.append("5h剩\(Int(w.leftPercent))%(window \(w.windowMinutes ?? 0)min)") }
        if let w = quota.secondary { windows.append("周剩\(Int(w.leftPercent))%") }
        print("codex:", windows.joined(separator: " | "), quota.planType.map { "[\($0)]" } ?? "")
    } else {
        print("codex: none")
    }
    if let quota = CursorQuota.decode(fromJSON: store.meta("cursor_quota")) {
        func pct(_ v: Double?) -> String { v.map { String(format: "%.0f%%", $0) } ?? "-" }
        print("cursor: total used \(pct(quota.totalPercentUsed)), auto \(pct(quota.autoPercentUsed)), api \(pct(quota.apiPercentUsed)), cycle \(quota.cycleStart.map(Fmt.shortDate) ?? "?")~\(quota.cycleEnd.map(Fmt.shortDate) ?? "?"), used \(quota.used ?? -1)/\(quota.limit ?? -1), bonus \(quota.bonus ?? 0)")
    } else {
        print("cursor: none")
    }
    exit(0)
}

if arguments.contains("--print-live") {    var done = false
    Task { @MainActor in
        let state = AppState.shared
        await state.pollLive()
        try? await Task.sleep(nanoseconds: 8_000_000_000)
        await state.pollLive()
        if state.activeTools.isEmpty {
            print("idle")
        } else {
            for tool in state.activeTools.sorted(by: { $0.rawValue < $1.rawValue }) {
                let secs = Int(Date().timeIntervalSince(state.activeSince[tool] ?? Date()))
                print("consuming \(tool.rawValue) \(secs)s")
            }
            // No +xx/m in --print-live. Rate UI was removed on purpose; do not restore.
        }
        done = true
    }
    while !done {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

enum CliMain {
    static func run() {
        let store = UsageStore.shared
        try? OpenCodeSource.refresh(store: store)
        try? CodexSource.refresh(store: store)

        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            _ = try? await CursorSource.refresh(store: store)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 90)

        print("== TokenSpend summary ==")
        for period in Period.allCases {
            let range = PeriodMath.range(of: period)
            let totals = store.dailyTotals(sinceDay: Fmt.day(range.start))
            var perTool: [Tool: UsageAmount] = [:]
            for tool in Tool.allCases {
                guard let days = totals[tool] else { continue }
                perTool[tool] = days.values.reduce(.zero, +)
            }
            for mode in UsageMode.allCases {
                let parts = Tool.allCases.map { tool -> String in
                    let amount = perTool[tool] ?? .zero
                    return "\(tool.rawValue)=\(Fmt.tokens(amount.total(mode: mode)))"
                }
                let total = perTool.values.reduce(.zero, +).total(mode: mode)
                print("\(period.rawValue)(\(mode.rawValue)): \(parts.joined(separator: " ")) total=\(Fmt.tokens(total))")
            }
        }
    }
}
