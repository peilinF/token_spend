import Foundation

final class FileResultCache {
    static let shared = FileResultCache()

    private let lock = NSLock()
    private var cache: [String: (sig: String, value: Any)] = [:]

    func value<T>(for url: URL, namespace: String = "", _ compute: () -> T) -> T {
        let fm = FileManager.default
        lock.lock()
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let sig = "\(mtime)|\(size)"
        let key = namespace.isEmpty ? url.path : url.path + "#" + namespace
        if let hit = cache[key], hit.sig == sig, let value = hit.value as? T {
            lock.unlock()
            return value
        }
        lock.unlock()

        let value = compute()

        lock.lock()
        cache[key] = (sig, value)
        if cache.count > 128 {
            cache.removeAll(keepingCapacity: true)
        }
        lock.unlock()
        return value
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }

    func clear() {
        lock.lock()
        cache.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}

final class WaitingMonitor {
    private let lock = NSLock()
    private var ocLastRowid: Int64 = 0
    private var ocPermLastRowid: Int64 = 0
    private var ocPrimed = false
    private var ocPendingQuestions: Set<Int64> = []
    private var ocPendingPermissions: Set<Int64> = []
    private var ocLastFullScan = Date.distantPast
    private var ocPermLastFullScan = Date.distantPast

    func poll(threshold: TimeInterval) -> [Tool: WaitingKind] {
        lock.lock()
        defer { lock.unlock() }
        var result: [Tool: WaitingKind] = [:]
        let now = Date()

        let hasQuestion = opencodeQuestionFastPath(now: now)
        let hasPermission = opencodePermissionFastPath(now: now)
        let hasStalled = opencodeStalledSlowPath(threshold: threshold, now: now)
        if hasQuestion {
            result[.opencode] = .question
        } else if hasPermission {
            result[.opencode] = .permission
        } else if hasStalled {
            result[.opencode] = .stalled
        }
        if let kind = WaitingDetector.codexWaitingKind(threshold: threshold, now: now) {
            result[.codex] = kind
        }
        if let kind = WaitingDetector.cursorWaitingKind(threshold: threshold, now: now) {
            result[.cursor] = kind
        }
        return result
    }

    // MARK: - opencode question (O(1) steady-state)

    private func opencodeQuestionFastPath(now: Date) -> Bool {
        guard WaitingDetector.processAlive(named: "opencode"),
              FileManager.default.fileExists(atPath: OpenCodeSource.dbPath),
              let db = try? SQLiteDatabase(path: OpenCodeSource.dbPath, readonly: true) else {
            ocPendingQuestions.removeAll()
            return false
        }

        if !ocPendingQuestions.isEmpty {
            for rowid in ocPendingQuestions {
                var status: String?
                try? db.query(
                    "SELECT json_extract(data,'$.state.status') FROM part WHERE rowid=?",
                    binds: [.int(rowid)]
                ) { row in status = row.text(0) }
                if status != "running" {
                    ocPendingQuestions.remove(rowid)
                }
            }
            if !ocPendingQuestions.isEmpty { return true }
        }

        var maxRowid: Int64 = 0
        try? db.query("SELECT MAX(rowid) FROM part", binds: []) { row in
            maxRowid = row.int(0)
        }
        if !ocPrimed {
            ocPrimed = true
            ocLastRowid = maxRowid
            ocLastFullScan = now
        }

        if maxRowid > ocLastRowid {
            try? db.query(
                "SELECT rowid FROM part WHERE rowid > ? AND rowid <= ? AND length(data) < 50000 " +
                "AND data LIKE '%\"tool\":\"question\"%' AND json_extract(data,'$.state.status')='running'",
                binds: [.int(ocLastRowid), .int(maxRowid)]
            ) { [weak self] row in
                self?.ocPendingQuestions.insert(row.int(0))
            }
            ocLastRowid = maxRowid
        }

        if now.timeIntervalSince(ocLastFullScan) > 60 {
            ocLastFullScan = now
            try? db.query(
                "SELECT rowid FROM part WHERE length(data) < 50000 " +
                "AND data LIKE '%\"tool\":\"question\"%' AND json_extract(data,'$.state.status')='running'",
                binds: []
            ) { row in
                ocPendingQuestions.insert(row.int(0))
            }
            ocPendingQuestions = ocPendingQuestions.filter { rowid in
                var status: String?
                try? db.query(
                    "SELECT json_extract(data,'$.state.status') FROM part WHERE rowid=?",
                    binds: [.int(rowid)]
                ) { row in status = row.text(0) }
                return status == "running"
            }
        }

        return !ocPendingQuestions.isEmpty
    }

    private func opencodePermissionFastPath(now: Date) -> Bool {
        guard WaitingDetector.processAlive(named: "opencode") else {
            ocPendingPermissions.removeAll()
            return false
        }
        // Primary signal: log file "asking id=per_..." with recent timestamp and a running part
        if hasRecentOpencodePermissionAsking(now: now) {
            if hasRunningOpencodePart(now: now) {
                return true
            }
        }
        // Fallback: legacy DB check for tool:"permission" (covers future opencode versions)
        guard FileManager.default.fileExists(atPath: OpenCodeSource.dbPath),
              let db = try? SQLiteDatabase(path: OpenCodeSource.dbPath, readonly: true) else {
            ocPendingPermissions.removeAll()
            return false
        }

        if !ocPendingPermissions.isEmpty {
            for rowid in ocPendingPermissions {
                var status: String?
                try? db.query(
                    "SELECT json_extract(data,'$.state.status') FROM part WHERE rowid=?",
                    binds: [.int(rowid)]
                ) { row in status = row.text(0) }
                if status != "running" {
                    ocPendingPermissions.remove(rowid)
                }
            }
            if !ocPendingPermissions.isEmpty { return true }
        }

        var maxRowid: Int64 = 0
        try? db.query("SELECT MAX(rowid) FROM part", binds: []) { row in
            maxRowid = row.int(0)
        }
        if !ocPrimed {
            ocPermLastRowid = maxRowid
            ocPermLastFullScan = now
        }
        if maxRowid > ocPermLastRowid {
            try? db.query(
                "SELECT rowid FROM part WHERE rowid > ? AND rowid <= ? AND length(data) < 60000 " +
                "AND data LIKE '%\"tool\":\"permission\"%' AND json_extract(data,'$.state.status')='running'",
                binds: [.int(ocPermLastRowid), .int(maxRowid)]
            ) { [weak self] row in
                self?.ocPendingPermissions.insert(row.int(0))
            }
            ocPermLastRowid = maxRowid
        }

        if now.timeIntervalSince(ocPermLastFullScan) > 60 {
            ocPermLastFullScan = now
            try? db.query(
                "SELECT rowid FROM part WHERE length(data) < 60000 " +
                "AND data LIKE '%\"tool\":\"permission\"%' AND json_extract(data,'$.state.status')='running'",
                binds: []
            ) { row in
                ocPendingPermissions.insert(row.int(0))
            }
            ocPendingPermissions = ocPendingPermissions.filter { rowid in
                var status: String?
                try? db.query(
                    "SELECT json_extract(data,'$.state.status') FROM part WHERE rowid=?",
                    binds: [.int(rowid)]
                ) { row in status = row.text(0) }
                return status == "running"
            }
            ocPendingPermissions = ocPendingPermissions.filter { rowid in
                var data: String?
                try? db.query("SELECT data FROM part WHERE rowid=?", binds: [.int(rowid)]) { row in data = row.text(0) }
                guard let d = data else { return false }
                return d.contains("\"type\":\"tool\"")
            }
        }

        return !ocPendingPermissions.isEmpty
    }

    private func hasRecentOpencodePermissionAsking(now: Date) -> Bool {
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/log/opencode.log")
        guard FileManager.default.fileExists(atPath: logURL.path) else { return false }
        let cutoff = now.addingTimeInterval(-120)
        return FileResultCache.shared.value(for: logURL, namespace: "opencode_perm_log") {
            guard let handle = try? FileHandle(forReadingFrom: logURL) else { return false }
            defer { try? handle.close() }
            let size = Int64((try? handle.seekToEnd()) ?? 0)
            let readStart = max(0, size - 262_144)
            try? handle.seek(toOffset: UInt64(readStart))
            guard let data = try? handle.readToEnd(),
                  let text = String(data: data, encoding: .utf8) else { return false }
            for line in text.split(separator: "\n") {
                guard line.contains("message=asking") && line.contains("per_") else { continue }
                // parse timestamp=2026-08-27T07:48:10.144Z
                if let tsRange = line.range(of: "timestamp=") {
                    let after = line[tsRange.upperBound...]
                    if let end = after.firstIndex(of: " ") {
                        let tsStr = String(after[..<end])
                        if let date = Formatters.isoFractional.date(from: tsStr) ?? Formatters.isoPlain.date(from: tsStr) {
                            if date < cutoff { continue }
                        }
                    }
                } else {
                    continue
                }
                return true
            }
            return false
        }
    }

    private func hasRunningOpencodePart(now: Date) -> Bool {
        guard FileManager.default.fileExists(atPath: OpenCodeSource.dbPath),
              let db = try? SQLiteDatabase(path: OpenCodeSource.dbPath, readonly: true) else { return false }
        let since = Int64(now.addingTimeInterval(-120).timeIntervalSince1970 * 1000)
        var found = false
        try? db.query(
            "SELECT 1 FROM part WHERE time_updated >= ? AND json_extract(data,'$.state.status')='running' LIMIT 1",
            binds: [.int(since)]
        ) { _ in found = true }
        return found
    }

    // MARK: - opencode stalled (slow path, full scan)

    private var ocLastStalledScan = Date.distantPast
    private func opencodeStalledSlowPath(threshold: TimeInterval, now: Date) -> Bool {
        guard !ocPendingQuestions.isEmpty || !ocPendingPermissions.isEmpty || now.timeIntervalSince(ocLastStalledScan) > 30 else { return false }
        ocLastStalledScan = now
        guard WaitingDetector.processAlive(named: "opencode"),
              FileManager.default.fileExists(atPath: OpenCodeSource.dbPath),
              let db = try? SQLiteDatabase(path: OpenCodeSource.dbPath, readonly: true) else { return false }

        var staleCount = 0
        let staleUpper = Int64((now.addingTimeInterval(-threshold)).timeIntervalSince1970 * 1000)
        let staleLower = Int64((now.addingTimeInterval(-1800)).timeIntervalSince1970 * 1000)
        try? db.query(
            "SELECT COUNT(*) FROM part WHERE time_updated < ? AND time_updated >= ? " +
            "AND length(data) < 200000 AND data LIKE '%\"status\":\"running\"%'",
            binds: [.int(staleUpper), .int(staleLower)]
        ) { row in staleCount = Int(row.int(0)) }
        return staleCount > 0
    }
}

enum WaitingDetector {
    static func detect(threshold: TimeInterval, monitor: WaitingMonitor? = nil) -> [Tool: WaitingKind] {
        if let monitor {
            return monitor.poll(threshold: threshold)
        }
        let now = Date()
        var result: [Tool: WaitingKind] = [:]
        if let kind = opencodeStalledOneShot(threshold: threshold, now: now) {
            result[.opencode] = kind
        }
        if let kind = codexWaitingKind(threshold: threshold, now: now) {
            result[.codex] = kind
        }
        if let kind = cursorWaitingKind(threshold: threshold, now: now) {
            result[.cursor] = kind
        }
        return result
    }

    private static func hasRecentOpencodePermissionLog(now: Date) -> Bool {
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/log/opencode.log")
        guard FileManager.default.fileExists(atPath: logURL.path) else { return false }
        let cutoff = now.addingTimeInterval(-120)
        return FileResultCache.shared.value(for: logURL, namespace: "opencode_perm_log") {
            guard let handle = try? FileHandle(forReadingFrom: logURL) else { return false }
            defer { try? handle.close() }
            let size = Int64((try? handle.seekToEnd()) ?? 0)
            let readStart = max(0, size - 262_144)
            try? handle.seek(toOffset: UInt64(readStart))
            guard let data = try? handle.readToEnd(),
                  let text = String(data: data, encoding: .utf8) else { return false }
            for line in text.split(separator: "\n") {
                guard line.contains("message=asking") && line.contains("per_") else { continue }
                if let tsRange = line.range(of: "timestamp=") {
                    let after = line[tsRange.upperBound...]
                    if let end = after.firstIndex(of: " ") {
                        let tsStr = String(after[..<end])
                        if let date = Formatters.isoFractional.date(from: tsStr) ?? Formatters.isoPlain.date(from: tsStr) {
                            if date < cutoff { continue }
                        }
                    }
                } else { continue }
                return true
            }
            return false
        }
    }

    private static func hasRunningOpencodePart(now: Date) -> Bool {
        guard FileManager.default.fileExists(atPath: OpenCodeSource.dbPath),
              let db = try? SQLiteDatabase(path: OpenCodeSource.dbPath, readonly: true) else { return false }
        let since = Int64(now.addingTimeInterval(-120).timeIntervalSince1970 * 1000)
        var found = false
        try? db.query(
            "SELECT 1 FROM part WHERE time_updated >= ? AND json_extract(data,'$.state.status')='running' LIMIT 1",
            binds: [.int(since)]
        ) { _ in found = true }
        return found
    }

    private static func opencodeStalledOneShot(threshold: TimeInterval, now: Date) -> WaitingKind? {
        guard processAlive(named: "opencode"),
              FileManager.default.fileExists(atPath: OpenCodeSource.dbPath),
              let db = try? SQLiteDatabase(path: OpenCodeSource.dbPath, readonly: true) else { return nil }

        var questionCount = 0
        try? db.query(
            "SELECT COUNT(*) FROM part WHERE length(data) < 50000 " +
            "AND data LIKE '%\"tool\":\"question\"%' AND json_extract(data,'$.state.status')='running'",
            binds: []
        ) { row in questionCount = Int(row.int(0)) }
        if questionCount > 0 { return .question }

        if hasRecentOpencodePermissionLog(now: now), hasRunningOpencodePart(now: now) {
            return .permission
        }
        var permCount = 0
        try? db.query(
            "SELECT COUNT(*) FROM part WHERE length(data) < 60000 " +
            "AND data LIKE '%\"tool\":\"permission\"%' AND json_extract(data,'$.state.status')='running'",
            binds: []
        ) { row in permCount = Int(row.int(0)) }
        if permCount > 0 { return .permission }

        var staleCount = 0
        let staleUpper = Int64((now.addingTimeInterval(-threshold)).timeIntervalSince1970 * 1000)
        let staleLower = Int64((now.addingTimeInterval(-1800)).timeIntervalSince1970 * 1000)
        try? db.query(
            "SELECT COUNT(*) FROM part WHERE time_updated < ? AND time_updated >= ? " +
            "AND length(data) < 200000 AND data LIKE '%\"status\":\"running\"%'",
            binds: [.int(staleUpper), .int(staleLower)]
        ) { row in staleCount = Int(row.int(0)) }
        if staleCount > 0 { return .stalled }
        return nil
    }

    private static let procCacheLock = NSLock()
    private static var procCacheAt = Date.distantPast
    private static var procNames: Set<String> = []

    static func processAlive(named name: String) -> Bool {
        procCacheLock.lock()
        let now = Date()
        if now.timeIntervalSince(procCacheAt) > 3 {
            procNames = scanProcessNames()
            procCacheAt = now
        }
        let hit = procNames.contains { $0.hasPrefix(name) }
        procCacheLock.unlock()
        return hit
    }

    private static func scanProcessNames() -> Set<String> {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        for _ in 0..<2 {
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
            var newSize = size
            guard sysctl(&mib, u_int(mib.count), &procs, &newSize, nil, 0) == 0 else { return [] }
            if newSize <= size {
                let count = newSize / MemoryLayout<kinfo_proc>.stride
                var names: Set<String> = []
                names.reserveCapacity(count / 2)
                for i in 0..<count {
                    let comm = withUnsafeBytes(of: procs[i].kp_proc.p_comm) { raw -> String in
                        String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
                    }
                    if !comm.isEmpty { names.insert(comm) }
                }
                return names
            }
            size = newSize
        }
        return []
    }

    // MARK: - codex

    private static let codexListLock = NSLock()
    private static var codexListAt = Date.distantPast
    private static var codexListFiles: [(URL, Date)] = []

    private static func recentCodexFiles(questionCutoff: Date) -> [(URL, Date)] {
        codexListLock.lock()
        defer { codexListLock.unlock() }
        let now = Date()
        if now.timeIntervalSince(codexListAt) > 5 {
            let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/sessions")
            var files: [(URL, Date)] = []
            if FileManager.default.fileExists(atPath: sessionsDir.path) {
                let enumerator = FileManager.default.enumerator(
                    at: sessionsDir, includingPropertiesForKeys: [.contentModificationDateKey]
                )
                while let next = enumerator?.nextObject() {
                    if let url = next as? URL, url.pathExtension == "jsonl",
                       let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                        files.append((url, mtime))
                    }
                }
            }
            files.sort { $0.1 > $1.1 }
            codexListFiles = files
            codexListAt = now
        }
        return codexListFiles.filter { $0.1 > questionCutoff }
    }

    static func codexWaitingKind(threshold: TimeInterval, now: Date) -> WaitingKind? {
        let questionCutoff = now.addingTimeInterval(-86_400)
        let activeCutoff = now.addingTimeInterval(-600)
        let recentFiles = recentCodexFiles(questionCutoff: questionCutoff)
        guard !recentFiles.isEmpty else { return nil }

        let candidates = recentFiles.prefix(8)
        if candidates.contains(where: { hasOpenRequestUserInput($0.0) }) {
            return .question
        }
        if candidates.contains(where: { hasOpenPermissionRequest($0.0) }) {
            return .permission
        }

        for (file, mtime) in candidates where mtime > activeCutoff {
            guard lastMarkerIsOpenTask(file) else { continue }
            if mtime < now.addingTimeInterval(-threshold) {
                return .stalled
            }
        }
        return nil
    }

    private static func hasOpenRequestUserInput(_ file: URL) -> Bool {
        FileResultCache.shared.value(for: file, namespace: "codex_question") {
            guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
            defer { try? handle.close() }
            let size = Int64((try? handle.seekToEnd()) ?? 0)
            let readStart = max(0, size - 262_144)
            try? handle.seek(toOffset: UInt64(readStart))
            guard let data = try? handle.readToEnd(), !data.isEmpty else { return false }

            let marker = Data("request_user_input".utf8)
            guard data.range(of: marker) != nil else { return false }

            let outputMarker = Data("\"type\":\"function_call_output\"".utf8)
            let taskEventMarker = Data("\"type\":\"task_".utf8)

            var pendingCallIDs: Set<String> = []
            for line in data.split(separator: 0x0A) {
                guard line.range(of: marker) != nil
                        || line.range(of: outputMarker) != nil
                        || line.range(of: taskEventMarker) != nil else { continue }
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                      let envelope = object as? [String: Any],
                      let payload = envelope["payload"] as? [String: Any] else { continue }

                if envelope["type"] as? String == "event_msg",
                   let eventType = payload["type"] as? String,
                   ["task_started", "task_complete", "turn_aborted", "thread_rolled_back"].contains(eventType) {
                    pendingCallIDs.removeAll()
                    continue
                }

                guard envelope["type"] as? String == "response_item",
                      let itemType = payload["type"] as? String,
                      let callID = payload["call_id"] as? String else { continue }

                if itemType == "function_call", payload["name"] as? String == "request_user_input" {
                    pendingCallIDs.insert(callID)
                } else if itemType == "function_call_output" {
                    pendingCallIDs.remove(callID)
                }
            }
            return !pendingCallIDs.isEmpty
        }
    }

    private static func hasOpenPermissionRequest(_ file: URL) -> Bool {
        FileResultCache.shared.value(for: file, namespace: "codex_permission") {
            guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
            defer { try? handle.close() }
            let size = Int64((try? handle.seekToEnd()) ?? 0)
            let readStart = max(0, size - 262_144)
            try? handle.seek(toOffset: UInt64(readStart))
            guard let data = try? handle.readToEnd(), !data.isEmpty else { return false }

            // Fast reject if no permission-like token
            let lower = String(data: data, encoding: .utf8)?.lowercased() ?? ""
            guard lower.contains("permission") || lower.contains("approval") || lower.contains("apply_patch") else { return false }

            let outputMarker = Data("\"type\":\"function_call_output\"".utf8)
            let taskEventMarker = Data("\"type\":\"task_".utf8)

            var pendingCallIDs: Set<String> = []
            for line in data.split(separator: 0x0A) {
                // keep lines that could be permission-related
                let lineLower = String(data: Data(line), encoding: .utf8)?.lowercased() ?? ""
                let isPermLine = lineLower.contains("permission") || lineLower.contains("approval") || lineLower.contains("apply_patch")
                guard isPermLine || line.range(of: outputMarker) != nil || line.range(of: taskEventMarker) != nil else { continue }
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                      let envelope = object as? [String: Any],
                      let payload = envelope["payload"] as? [String: Any] else { continue }

                if envelope["type"] as? String == "event_msg",
                   let eventType = payload["type"] as? String,
                   ["task_started", "task_complete", "turn_aborted", "thread_rolled_back"].contains(eventType) {
                    pendingCallIDs.removeAll()
                    continue
                }

                guard envelope["type"] as? String == "response_item",
                      let itemType = payload["type"] as? String,
                      let callID = payload["call_id"] as? String else { continue }

                if itemType == "function_call", let name = payload["name"] as? String {
                    let n = name.lowercased()
                    if n.contains("permission") || n.contains("approval") || n == "apply_patch" || n.contains("apply_patch") {
                        pendingCallIDs.insert(callID)
                    }
                } else if itemType == "function_call_output" {
                    pendingCallIDs.remove(callID)
                }
            }
            if !pendingCallIDs.isEmpty { return true }
            // Also detect explicit pending approval state markers without call_id pairing
            // e.g. codex may write a plain approval request object that stays open until answered
            return lower.contains("\"approval\"") && lower.contains("\"pending\"")
        }
    }

    private static func lastMarkerIsOpenTask(_ file: URL) -> Bool {
        FileResultCache.shared.value(for: file, namespace: "codex_task") {
            guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
            defer { try? handle.close() }
            let size = Int64((try? handle.seekToEnd()) ?? 0)
            let readStart = max(0, size - 131_072)
            try? handle.seek(toOffset: UInt64(readStart))
            guard let data = try? handle.readToEnd(), !data.isEmpty else { return false }

            func pos(_ marker: String) -> Range<Data.Index>? {
                data.range(of: Data(marker.utf8), options: [.backwards])
            }
            guard let started = pos("\"type\":\"task_started\"") else { return false }
            if let completed = pos("\"type\":\"task_complete\""), completed.lowerBound > started.lowerBound { return false }
            if let aborted = pos("\"type\":\"turn_aborted\""), aborted.lowerBound > started.lowerBound { return false }
            if let rolled = pos("\"type\":\"thread_rolled_back\""), rolled.lowerBound > started.lowerBound { return false }
            return true
        }
    }

    // MARK: - cursor

    static func cursorWaitingKind(threshold: TimeInterval, now: Date) -> WaitingKind? {
        guard processAlive(named: "Cursor") else { return nil }

        let questionCutoff = now.addingTimeInterval(-86_400)
        if hasOpenUserApproval(newerThan: questionCutoff) {
            return .question
        }
        if hasOpenPermissionApproval(newerThan: questionCutoff) {
            return .permission
        }

        let activeCutoff = now.addingTimeInterval(-1800)

        for (log, mtime) in CursorLogs.requestTraceLogs(newerThan: activeCutoff).prefix(3) {
            guard mtime < now.addingTimeInterval(-threshold) else { continue }
            if tailIndicatesStall(log) {
                return .stalled
            }
        }
        return nil
    }

    private static func hasOpenUserApproval(newerThan cutoff: Date) -> Bool {
        for (log, _) in CursorLogs.rendererLogs(newerThan: cutoff).prefix(8) {
            if lastWakelockReasons(log).values.contains("user-approval-requested") {
                return true
            }
        }
        return false
    }

    private static func hasOpenPermissionApproval(newerThan cutoff: Date) -> Bool {
        // renderer wakelock reason variants for permission gates; also covers approval-requested
        for (log, _) in CursorLogs.rendererLogs(newerThan: cutoff).prefix(8) {
            for reason in lastWakelockReasons(log).values {
                let r = reason.lowercased()
                if r.contains("permission") || r == "approval-requested" || r.contains("approval") {
                    // user-approval already handled; remaining are permission-like
                    if r != "user-approval-requested" { return true }
                }
            }
        }
        // fallback: Cursor Agent Exec log shows a pending approval gate without auto-approval
        for (log, _) in CursorLogs.agentExecLogs(newerThan: cutoff).prefix(6) {
            if hasPendingAgentApproval(log) { return true }
        }
        return false
    }

    private static func hasPendingAgentApproval(_ url: URL) -> Bool {
        FileResultCache.shared.value(for: url, namespace: "cursor_agent_approval") {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            let size = Int64((try? handle.seekToEnd()) ?? 0)
            let readStart = max(0, size - 262_144)
            try? handle.seek(toOffset: UInt64(readStart))
            guard let data = try? handle.readToEnd(),
                  let text = String(data: data, encoding: .utf8) else { return false }

            // track approval gates that were reached but not auto-approved/allowed
            var pending: Set<String> = []
            for line in text.split(separator: "\n") {
                guard line.contains("approval gate") else { continue }
                // extract toolCallId if present to pair reached vs allowed (handles both toolCallId=" and "toolCallId":")
                let tid: String
                if let r = line.range(of: "\"toolCallId\""), let colon = line[r.upperBound...].firstIndex(of: ":") {
                    let after = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    if after.first == "\"", let end = after.dropFirst().firstIndex(of: "\"") {
                        tid = String(after.dropFirst()[..<end])
                    } else if let q = line.range(of: "toolCallId=\""), let end = line[q.upperBound...].firstIndex(of: "\"") {
                        tid = String(line[q.upperBound..<end])
                    } else {
                        tid = String(line.prefix(80))
                    }
                } else if let q = line.range(of: "toolCallId=\""), let end = line[q.upperBound...].firstIndex(of: "\"") {
                    tid = String(line[q.upperBound..<end])
                } else {
                    tid = String(line.prefix(80))
                }
                if line.contains("approval gate reached") {
                    pending.insert(tid)
                } else if line.contains("approval gate allowed") || line.contains("auto-approved") {
                    pending.remove(tid)
                }
            }
            return !pending.isEmpty
        }
    }

    private static func lastWakelockReasons(_ url: URL) -> [String: String] {
        FileResultCache.shared.value(for: url, namespace: "cursor_wakelock") {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return [:] }
            defer { try? handle.close() }
            let size = Int64((try? handle.seekToEnd()) ?? 0)
            let readStart = max(0, size - 262_144)
            try? handle.seek(toOffset: UInt64(readStart))
            guard let data = try? handle.readToEnd(),
                  let text = String(data: data, encoding: .utf8) else { return [:] }

            let marker = "[ComposerWakelockManager]"
            var last: [String: String] = [:]
            for line in text.split(separator: "\n") {
                guard line.contains(marker),
                      let reason = field(named: "reason", in: line) else { continue }
                let composer = field(named: "composerId", in: line) ?? "_"
                last[composer] = reason
            }
            return last
        }
    }

    private static func field(named name: String, in line: Substring) -> String? {
        let prefix = name + "=\""
        guard let range = line.range(of: prefix) else { return nil }
        let rest = line[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    // Shell-executor spans stay open for the whole lifetime of a terminal
    // command. One still open means a command is running, not a stall.
    private static let terminalSpanNames = [
        "LazyTerminalExecutor.execute",
        "LocalShellStreamExecutor.execute",
        "ShellCoreExecutor.execute",
        "ZshState.execute",
    ]

    private static func tailIndicatesStall(_ url: URL) -> Bool {
        FileResultCache.shared.value(for: url, namespace: "cursor_stall") {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            let size = Int64((try? handle.seekToEnd()) ?? 0)
            let readStart = max(0, size - 65_536)
            try? handle.seek(toOffset: UInt64(readStart))
            guard let data = try? handle.readToEnd(),
                  let text = String(data: data, encoding: .utf8) else { return false }

            var openTerminalSpans: Set<String> = []
            for line in text.split(separator: "\n") {
                guard line.contains("span_"),
                      terminalSpanNames.contains(where: { line.contains("name=\"\($0)\"") }),
                      let sidRange = line.range(of: "spanId=") else { continue }
                let sid = line[sidRange.upperBound...].prefix(while: { $0 != " " })
                if line.contains("span_started") {
                    openTerminalSpans.insert(String(sid))
                } else if line.contains("span_completed") {
                    openTerminalSpans.remove(String(sid))
                }
            }
            if !openTerminalSpans.isEmpty { return false }

            let inProgressMarkers = ["AgentResponseAdapter.toolCallStarted", "processPartialToolCall"]
            let doneMarkers = ["AgentResponseAdapter.toolCallCompleted"]

            for line in text.split(separator: "\n").reversed() {
                let containsInProgress = inProgressMarkers.contains { line.contains($0) }
                let containsDone = doneMarkers.contains { line.contains($0) }
                guard containsInProgress || containsDone else { continue }
                return containsInProgress
            }
            return false
        }
    }
}
