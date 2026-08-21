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

if arguments.contains("--print-live") {    var done = false
    Task { @MainActor in
        let state = AppState.shared
        await state.pollLive()
        try? await Task.sleep(nanoseconds: 8_000_000_000)
        await state.pollLive()
        print("active: \(state.activeTools.sorted(by: { $0.rawValue < $1.rawValue }).map(\.rawValue).joined(separator: ","))")
        for (tool, rate) in state.liveRates.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            print("live \(tool.rawValue): +\(rate)/min")
        }
        if state.liveRates.isEmpty { print("live: idle") }
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
