import Foundation

enum CursorLogs {
    private static let lock = NSLock()
    private static var lastScanAt = Date.distantPast
    private static var scanned: [String: [(url: URL, mtime: TimeInterval)]] = [:]

    static var logsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/logs")
    }

    static func requestTraceLogs(newerThan cutoff: Date) -> [(url: URL, mtime: Date)] {
        files(named: "cursor.requestTraces.log", newerThan: cutoff)
    }

    static func rendererLogs(newerThan cutoff: Date) -> [(url: URL, mtime: Date)] {
        files(named: "renderer.log", newerThan: cutoff)
    }

    static func newestRequestTrace() -> (url: URL, mtime: Date)? {
        requestTraceLogs(newerThan: Date.distantPast).first
    }

    private static func files(named fileName: String, newerThan cutoff: Date) -> [(url: URL, mtime: Date)] {
        lock.lock()
        defer { lock.unlock() }

        let logsDir = logsDirectory
        guard FileManager.default.fileExists(atPath: logsDir.path) else { return [] }

        let now = Date()
        if now.timeIntervalSince(lastScanAt) > 5 {
            scanned = [:]
            for name in ["cursor.requestTraces.log", "renderer.log"] {
                scanned[name] = scan(fileName: name, in: logsDir)
            }
            lastScanAt = now
        }

        let entries = scanned[fileName] ?? []
        return entries
            .filter { Date(timeIntervalSince1970: $0.mtime) > cutoff }
            .sorted { $0.mtime > $1.mtime }
            .map { ($0.url, Date(timeIntervalSince1970: $0.mtime)) }
    }

    private static func scan(fileName: String, in logsDir: URL) -> [(url: URL, mtime: TimeInterval)] {
        let fm = FileManager.default
        guard let sessions = try? fm.contentsOfDirectory(
            at: logsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let recentSessions = sessions
            .sorted { a, b in
                let am = ((try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)?
                    .timeIntervalSince1970 ?? 0
                let bm = ((try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)?
                    .timeIntervalSince1970 ?? 0
                return am > bm
            }
            .prefix(3)

        var found: [(url: URL, mtime: TimeInterval)] = []
        for session in recentSessions {
            guard let windows = try? fm.contentsOfDirectory(
                at: session,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for window in windows where window.lastPathComponent.hasPrefix("window") {
                guard let outputs = try? fm.contentsOfDirectory(
                    at: window,
                    includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for out in outputs {
                    let candidate = out.appendingPathComponent(fileName)
                    let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
                    guard values?.isRegularFile == true else { continue }
                    let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
                    found.append((candidate, mtime))
                }
            }
        }
        return found
    }
}
