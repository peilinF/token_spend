import AppKit
import Darwin
import Foundation

let arguments = CommandLine.arguments

if arguments.contains("--print-summary") {
    CliMain.run()
    exit(0)
}

if let idx = arguments.firstIndex(of: "--export-csv") {
    let store = UsageStore.shared
    let csv = store.exportCSV(sinceDay: "2000-01-01")
    let next = arguments.index(after: idx)
    if next < arguments.endIndex, !arguments[next].hasPrefix("-") {
        do {
            try csv.write(toFile: arguments[next], atomically: true, encoding: .utf8)
            print("exported \(arguments[next])")
        } catch {
            fputs("export failed: \(error)\n", stderr)
            exit(1)
        }
    } else {
        print(csv, terminator: "")
    }
    exit(0)
}

if arguments.contains("--reconcile") {
    let store = UsageStore.shared
    do {
        try OpenCodeSource.reconcile(store: store)
        try CodexSource.reconcile(store: store)
        print("reconcile done")
    } catch {
        fputs("reconcile failed: \(error)\n", stderr)
        exit(1)
    }
    exit(0)
}

if arguments.contains("--print-waiting") {
    let threshold = UserDefaults.standard.object(forKey: PrefKeys.waitThreshold) as? TimeInterval ?? 60
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
        if let quota = CodexQuota.decode(fromJSON: store.meta(StoreKeys.codexRateLimits)) {
            var windows: [String] = []
            if let w = quota.primary { windows.append("\(w.shortLabel)剩\(Int(w.leftPercent))%") }
            if let w = quota.secondary { windows.append("\(w.shortLabel)剩\(Int(w.leftPercent))%") }
        print("codex:", windows.joined(separator: " | "), quota.planType.map { "[\($0)]" } ?? "")
    } else {
        print("codex: none")
    }
    if let quota = CursorQuota.decode(fromJSON: store.meta(StoreKeys.cursorQuota)) {
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

// Single-instance guard (placed after the --print-* CLI early-exits so
// diagnostics keep working while the app runs). A second copy (debug build
// next to the installed app, double-clicked .app, …) would otherwise
// double-sync, double-poll and show two menu icons — and quitting one
// leaves the other running, looking like "quit doesn't work".
do {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TokenSpend", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let lockPath = dir.appendingPathComponent("instance.lock").path
    let fd = open(lockPath, O_RDWR | O_CREAT, 0o600)
    // fd intentionally leaked: the lock lives as long as the process.
    // flock auto-releases on crash, so no stale-lock cleanup is needed.
    guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
        if fd >= 0 { close(fd) }
        NSLog("TokenSpend: another instance is already running, exiting")
        exit(0)
    }
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

enum CliMain {
    static func run() {
        let store = UsageStore.shared
        do {
            try OpenCodeSource.refresh(store: store)
        } catch {
            fputs("opencode refresh failed: \(error)\n", stderr)
        }
        do {
            try CodexSource.refresh(store: store)
        } catch {
            fputs("codex refresh failed: \(error)\n", stderr)
        }

        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                _ = try await CursorSource.refresh(store: store)
            } catch {
                fputs("cursor refresh failed: \(error)\n", stderr)
            }
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
