import Foundation

enum CursorLogs {
    private static let lock = NSLock()
    private static var caches: [String: CacheBox] = [:]

    private struct CacheBox {
        var signature: String
        var entries: [(url: URL, mtime: TimeInterval)]
    }

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

        let signature = directorySignature(in: logsDir)
        let entries: [(url: URL, mtime: TimeInterval)]
        if let box = caches[fileName], box.signature == signature {
            entries = restat(box.entries)
            caches[fileName] = CacheBox(signature: signature, entries: entries)
        } else {
            entries = scan(fileName: fileName, in: logsDir)
            caches[fileName] = CacheBox(signature: signature, entries: entries)
        }

        return entries
            .filter { Date(timeIntervalSince1970: $0.mtime) > cutoff }
            .sorted { $0.mtime > $1.mtime }
            .map { ($0.url, Date(timeIntervalSince1970: $0.mtime)) }
    }

    private static func restat(_ entries: [(url: URL, mtime: TimeInterval)]) -> [(url: URL, mtime: TimeInterval)] {
        let fm = FileManager.default
        var refreshed: [(url: URL, mtime: TimeInterval)] = []
        refreshed.reserveCapacity(entries.count)
        for (url, _) in entries {
            guard fm.fileExists(atPath: url.path) else { continue }
            let mtime = ((try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)?
                .timeIntervalSince1970 ?? 0
            refreshed.append((url, mtime))
        }
        return refreshed
    }

    private static func scan(fileName: String, in logsDir: URL) -> [(url: URL, mtime: TimeInterval)] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: logsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [(url: URL, mtime: TimeInterval)] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.lastPathComponent == fileName else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }
            let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            found.append((url, mtime))
        }
        return found
    }

    private static func directorySignature(in logsDir: URL) -> String {
        let fm = FileManager.default
        guard let sessions = try? fm.contentsOfDirectory(
            at: logsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return "" }

        var parts: [String] = []
        for session in sessions.sorted(by: { $0.path < $1.path }) {
            let sessionMtime = (try? session.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?.timeIntervalSince1970 ?? 0
            parts.append("\(session.lastPathComponent):\(sessionMtime)")
            guard let windows = try? fm.contentsOfDirectory(
                at: session,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for window in windows where window.lastPathComponent.hasPrefix("window") {
                let windowMtime = (try? window.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate?.timeIntervalSince1970 ?? 0
                parts.append("\(window.lastPathComponent):\(windowMtime)")
            }
        }
        return parts.joined(separator: "|")
    }
}
