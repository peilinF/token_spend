import Foundation
import SQLite3

struct CodexAuditDay: Codable, Equatable {
    var input: Int64
    var output: Int64
    var cacheRead: Int64
    var cacheWrite: Int64

    var lean: Int64 { input + output }
    var full: Int64 { input + output + cacheRead + cacheWrite }

    private enum CodingKeys: String, CodingKey {
        case input, output, cacheRead, cacheWrite, lean, full
    }

    init(_ amount: UsageAmount = .zero) {
        input = amount.input
        output = amount.output
        cacheRead = amount.cacheRead
        cacheWrite = amount.cacheWrite
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        input = try values.decode(Int64.self, forKey: .input)
        output = try values.decode(Int64.self, forKey: .output)
        cacheRead = try values.decode(Int64.self, forKey: .cacheRead)
        cacheWrite = try values.decode(Int64.self, forKey: .cacheWrite)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(input, forKey: .input)
        try values.encode(output, forKey: .output)
        try values.encode(cacheRead, forKey: .cacheRead)
        try values.encode(cacheWrite, forKey: .cacheWrite)
        try values.encode(lean, forKey: .lean)
        try values.encode(full, forKey: .full)
    }

    static func - (lhs: CodexAuditDay, rhs: CodexAuditDay) -> CodexAuditDay {
        CodexAuditDay(UsageAmount(
            input: lhs.input - rhs.input, output: lhs.output - rhs.output,
            cacheRead: lhs.cacheRead - rhs.cacheRead, cacheWrite: lhs.cacheWrite - rhs.cacheWrite
        ))
    }
}

struct CodexAuditFork: Codable {
    let path: String
    let sessionID: String?
    let forkedFromID: String
    let matchedPrefixEvents: Int
    let childTokenEvents: Int
    let addedUsage: CodexAuditDay
    let matchedPrefixSHA256: String
}

struct CodexAuditReport: Codable {
    let generatedAt: String
    let timeZone: String
    let parserVersion: String?
    let status: String?
    let retentionStartDay: String
    let expectedByDay: [String: CodexAuditDay]
    let databaseByDay: [String: CodexAuditDay]
    let differenceByDay: [String: CodexAuditDay]
    let forks: [CodexAuditFork]
    let pendingTailBytes: Int64
    let warnings: [String]
    let blockers: [String]
    let consistent: Bool
}

enum CodexAudit {
    private static let cursorPrefix = "codex_cursor:"
    private static let versionKey = StoreKeys.codexUsageVersion
    private static let statusKey = StoreKeys.codexUsageStatus

    private struct Snapshot {
        var metadata: [String: String] = [:]
        var rows: [String: UsageAmount] = [:]
    }

    private struct IndexedFile {
        let path: String
        let cursor: CodexFileCursor
        let scan: CodexScannedFile
    }

    static func makeReport(
        databaseURL: URL = UsageStore.databaseURL,
        sessionsDirectory suppliedDirectory: URL? = nil,
        now: Date = Date()
    ) throws -> CodexAuditReport {
        let directory = suppliedDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        let database = try SQLiteDatabase(path: databaseURL.path, readonly: true)
        let snapshot = try readSnapshot(database)
        let version = snapshot.metadata[versionKey]
        let status = snapshot.metadata[statusKey]
        var blockers: [String] = []
        var warnings: [String] = []
        if version != "4" { blockers.append("Codex parser version is not 4") }
        if status != "ready" { blockers.append("Codex source status is not ready") }

        var cursors: [String: CodexFileCursor] = [:]
        let decoder = JSONDecoder()
        for (key, value) in snapshot.metadata where key.hasPrefix(cursorPrefix) {
            let path = String(key.dropFirst(cursorPrefix.count))
            guard let data = value.data(using: .utf8) else {
                blockers.append("cursor is not UTF-8 for \(path)")
                continue
            }
            do { cursors[path] = try decoder.decode(CodexFileCursor.self, from: data) }
            catch { blockers.append("cursor cannot be decoded for \(path): \(error)") }
        }

        let listedPaths = try enumerateSessionPaths(directory)
        let cursorPaths = Set(cursors.keys)
        for path in listedPaths.subtracting(cursorPaths).sorted() {
            blockers.append("session has no committed cursor: \(path)")
        }
        for path in cursorPaths.subtracting(listedPaths).sorted() {
            blockers.append("committed session file is missing: \(path)")
        }

        let captured = try Dictionary(uniqueKeysWithValues: cursors.keys.compactMap { path -> (String, CodexFileIdentity)? in
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return (path, try CodexIndex.identity(at: URL(fileURLWithPath: path)))
        })
        var indexed: [String: IndexedFile] = [:]
        var pendingTailBytes: Int64 = 0
        for (path, cursor) in cursors.sorted(by: { $0.key < $1.key }) {
            guard let identity = captured[path] else { continue }
            let url = URL(fileURLWithPath: path)
            if identity.inode != cursor.identity.inode || identity.size < cursor.offset {
                blockers.append("session identity changed or was truncated: \(path)")
                continue
            }
            let scan: CodexScannedFile
            do { scan = try CodexIndex.scan(url, through: cursor.offset, fixedIdentity: identity) }
            catch {
                blockers.append("session cannot be read through its committed offset: \(path): \(error)")
                continue
            }
            guard scan.offset == cursor.offset,
                  scan.committedRawSHA256 == cursor.committedRawSHA256 else {
                blockers.append("committed raw prefix does not match its cursor: \(path)")
                continue
            }
            indexed[path] = IndexedFile(path: path, cursor: cursor, scan: scan)
            pendingTailBytes += max(0, identity.size - cursor.offset)
            if identity.size > cursor.offset {
                warnings.append("uncommitted appended bytes: \(path) (\(identity.size - cursor.offset))")
            }
        }

        let finalListedPaths = try enumerateSessionPaths(directory)
        if finalListedPaths != listedPaths {
            blockers.append("sessions directory changed during audit")
        }
        for (path, identity) in captured {
            let current = try CodexIndex.identity(at: URL(fileURLWithPath: path))
            guard current.inode == identity.inode, current.size >= identity.size else {
                blockers.append("session was replaced or truncated during audit: \(path)")
                continue
            }
            if current.size == identity.size,
               current.modifiedMilliseconds != identity.modifiedMilliseconds {
                blockers.append("session changed during audit: \(path)")
            }
        }

        var bySessionID: [String: [String]] = [:]
        var declaredParentsBySession: [String: Set<String?>] = [:]
        for (path, file) in indexed {
            if let id = file.scan.sessionID {
                if id.hasPrefix("!conflict:") {
                    blockers.append("conflicting session IDs in \(path): \(id)")
                } else {
                    bySessionID[id, default: []].append(path)
                    declaredParentsBySession[id, default: []].insert(file.scan.forkedFromID)
                }
            }
            if let parentID = file.scan.forkedFromID, parentID.hasPrefix("!conflict:") {
                blockers.append("conflicting fork parent IDs in \(path): \(parentID)")
            }
        }
        for (sessionID, parents) in declaredParentsBySession where parents.count > 1 {
            let labels = parents.map { $0 ?? "<none>" }.sorted().joined(separator: ", ")
            blockers.append("conflicting parent relationships for session \(sessionID): \(labels)")
        }
        var parentGraph: [String: Set<String>] = [:]
        for (sessionID, parents) in declaredParentsBySession {
            var edges: Set<String> = []
            for parent in parents {
                if let parent, bySessionID[parent] != nil { edges.insert(parent) }
            }
            parentGraph[sessionID] = edges
        }
        for cycle in findForkCycles(parentGraph) {
            blockers.append("fork cycle: \(cycle.joined(separator: " -> "))")
        }
        var expectedByKey: [String: UsageAmount] = [:]
        var forks: [CodexAuditFork] = []
        for (path, file) in indexed.sorted(by: { $0.key < $1.key }) {
            let parentID = file.scan.forkedFromID
            var matched = 0
            if let parentID {
                let parentPaths = bySessionID[parentID] ?? []
                if parentPaths.isEmpty {
                    blockers.append("fork parent is missing for \(path): \(parentID)")
                } else {
                    for parentPath in parentPaths {
                        guard let parent = indexed[parentPath] else { continue }
                        var common = 0
                        while common < min(file.scan.events.count, parent.scan.events.count),
                              file.scan.events[common].fingerprint == parent.scan.events[common].fingerprint {
                            common += 1
                        }
                        matched = max(matched, common)
                    }
                }
            }
            let accumulation = independentlyAccumulate(
                file.scan.events, matchedPrefixCount: matched,
                fallbackDay: Fmt.day(Date(timeIntervalSince1970: Double(file.scan.identity.modifiedMilliseconds) / 1000)),
                fallbackSegments: file.cursor.fallbackSegments, path: path
            )
            blockers.append(contentsOf: accumulation.blockers)
            let days = accumulation.days
            for (day, amount) in days where day >= retentionStartDay(now: now) {
                expectedByKey[path + "|" + day] = amount
            }
            if let parentID {
                let added = days.values.reduce(.zero, +)
                forks.append(CodexAuditFork(
                    path: path, sessionID: file.scan.sessionID, forkedFromID: parentID,
                    matchedPrefixEvents: matched, childTokenEvents: file.scan.events.count,
                    addedUsage: CodexAuditDay(added),
                    matchedPrefixSHA256: try CodexIndex.prefixSHA256(file.scan.events, count: matched)
                ))
            }
        }

        let cutoff = retentionStartDay(now: now)
        let actualByKey = snapshot.rows.filter { _, amount in amount.input != 0 || amount.output != 0 || amount.cacheRead != 0 || amount.cacheWrite != 0 }
            .filter { key, _ in
                guard let delimiter = key.lastIndex(of: "|") else { return true }
                return String(key[key.index(after: delimiter)...]) >= cutoff
            }
        let allKeys = Set(expectedByKey.keys).union(actualByKey.keys)
        var differenceByDay: [String: UsageAmount] = [:]
        for key in allKeys {
            let difference = (expectedByKey[key] ?? .zero) - (actualByKey[key] ?? .zero)
            guard difference.input != 0 || difference.output != 0 || difference.cacheRead != 0 || difference.cacheWrite != 0 else { continue }
            guard let delimiter = key.lastIndex(of: "|") else {
                blockers.append("contribution key has no day delimiter: \(key)")
                continue
            }
            let day = String(key[key.index(after: delimiter)...])
            differenceByDay[day, default: .zero] = differenceByDay[day, default: .zero] + difference
        }
        let expectedByDay = aggregateByDay(expectedByKey)
        let databaseByDay = aggregateByDay(actualByKey)
        let differences = differenceByDay.mapValues(CodexAuditDay.init)
        let report = CodexAuditReport(
            generatedAt: ISO8601DateFormatter().string(from: now),
            timeZone: TimeZone.current.identifier, parserVersion: version, status: status,
            retentionStartDay: cutoff,
            expectedByDay: expectedByDay.mapValues(CodexAuditDay.init),
            databaseByDay: databaseByDay.mapValues(CodexAuditDay.init),
            differenceByDay: differences, forks: forks.sorted { $0.path < $1.path },
            pendingTailBytes: pendingTailBytes, warnings: warnings.sorted(),
            blockers: blockers.sorted(), consistent: blockers.isEmpty && differences.isEmpty
        )
        return report
    }

    @discardableResult
    static func run(
        databaseURL: URL = UsageStore.databaseURL,
        sessionsDirectory: URL? = nil,
        reportURL: URL? = nil
    ) -> Int32 {
        let report: CodexAuditReport
        do {
            report = try makeReport(databaseURL: databaseURL, sessionsDirectory: sessionsDirectory)
        } catch let auditError {
            let errorData = errorReportData(auditError)
            if let reportURL {
                do {
                    try errorData.write(to: reportURL, options: .atomic)
                    print("Codex audit error report saved: \(reportURL.path)")
                } catch let writeError {
                    print(errorReportString(original: auditError, writeFailure: writeError))
                }
            } else if let raw = String(data: errorData, encoding: .utf8) {
                print(raw)
            }
            return 2
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(report)
            if let reportURL {
                try data.write(to: reportURL, options: .atomic)
                print("Codex audit report saved: \(reportURL.path)")
            } else if let raw = String(data: data, encoding: .utf8) {
                print(raw)
            }
            if !report.blockers.isEmpty { return 2 }
            return report.consistent ? 0 : 1
        } catch {
            print(errorReportString(original: error, writeFailure: nil))
            return 2
        }
    }

    private static func errorReportData(_ error: Error) -> Data {
        (try? JSONSerialization.data(
            withJSONObject: ["error": String(describing: error)], options: [.prettyPrinted, .sortedKeys]
        )) ?? Data("{\"error\":\"Codex audit failed\"}".utf8)
    }

    private static func errorReportString(original: Error, writeFailure: Error?) -> String {
        var object = ["error": String(describing: original)]
        if let writeFailure { object["reportWriteError"] = String(describing: writeFailure) }
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let raw = String(data: data, encoding: .utf8) { return raw }
        return "{\"error\":\"Codex audit failed\"}"
    }

    private static func readSnapshot(_ database: SQLiteDatabase) throws -> Snapshot {
        try database.readTransaction {
            var result = Snapshot()
            try database.query(
                "SELECT key,value FROM meta WHERE key=? OR substr(key,1,length(?))=?",
                binds: [.text(versionKey), .text(cursorPrefix), .text(cursorPrefix)]
            ) { row in
                if let key = row.text(0), let value = row.text(1) { result.metadata[key] = value }
            }
            try database.query(
                "SELECT key,input,output,cache_read,cache_write FROM contrib WHERE source=?",
                binds: [.text(Tool.codex.rawValue)]
            ) { row in
                guard let key = row.text(0) else { return }
                var amount = UsageAmount()
                amount.input = row.int(1)
                amount.output = row.int(2)
                amount.cacheRead = row.int(3)
                amount.cacheWrite = row.int(4)
                result.rows[key] = amount
            }
            // These two keys are deliberately read inside the same snapshot.
            for key in [statusKey] {
                try database.query("SELECT key,value FROM meta WHERE key=?", binds: [.text(key)]) { row in
                    if let key = row.text(0), let value = row.text(1) { result.metadata[key] = value }
                }
            }
            return result
        }
    }

    private static func enumerateSessionPaths(_ directory: URL) throws -> Set<String> {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CodexScanError.unavailable("sessions directory is missing or unreadable: \(directory.path)")
        }
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey],
            errorHandler: { _, error in enumerationError = error; return false }
        ) else {
            throw CodexScanError.unavailable("sessions directory is missing or unreadable: \(directory.path)")
        }
        var paths: Set<String> = []
        while let item = enumerator.nextObject() {
            guard let url = item as? URL, url.pathExtension == "jsonl" else { continue }
            do {
                if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    paths.insert(url.path)
                }
            } catch { enumerationError = error; break }
        }
        if let enumerationError { throw CodexScanError.unavailable("sessions enumeration failed: \(enumerationError)") }
        return paths
    }

    private static func independentlyAccumulate(
        _ events: [CodexTokenRecord], matchedPrefixCount: Int,
        fallbackDay: String, fallbackSegments: [CodexFallbackSegment], path: String
    ) -> (days: [String: UsageAmount], blockers: [String]) {
        var result: [String: UsageAmount] = [:]
        var blockers: [String] = []
        var priorTotals: CodexUsageSnapshot?
        for (index, record) in events.enumerated() {
            if let total = record.total, let reason = invalidBuckets(total) {
                blockers.append("invalid total token buckets at \(path) byte \(record.endByte): \(reason)")
            }
            if let last = record.last, let reason = invalidBuckets(last) {
                blockers.append("invalid last token buckets at \(path) byte \(record.endByte): \(reason)")
            }
            if index < matchedPrefixCount {
                if let total = record.total { priorTotals = total }
                continue
            }
            var usage: CodexUsageSnapshot
            if let total = record.total {
                if let priorTotals {
                    let input = total.input - priorTotals.input
                    let read = total.cacheRead - priorTotals.cacheRead
                    let write = total.cacheWrite - priorTotals.cacheWrite
                    let output = total.output - priorTotals.output
                    if input < 0 || read < 0 || write < 0 || output < 0 {
                        usage = record.last ?? total
                    } else {
                        usage = CodexUsageSnapshot(input: input, cacheRead: read, cacheWrite: write, output: output)
                    }
                } else {
                    usage = record.last ?? total
                }
                priorTotals = total
            } else if let last = record.last {
                usage = last
            } else {
                continue
            }
            if let reason = invalidBuckets(usage) {
                blockers.append("invalid accumulated token buckets at \(path) byte \(record.endByte): \(reason)")
                continue
            }
            let exclusive = usage.input - usage.cacheRead - usage.cacheWrite
            usage.input = exclusive
            if usage.input == 0 && usage.output == 0 && usage.cacheRead == 0 && usage.cacheWrite == 0 { continue }
            let segmentDay = fallbackSegments.first {
                record.endByte > $0.startByte && record.endByte <= $0.endByte
            }?.day
            let day = record.timestamp.map(Fmt.day) ?? segmentDay ?? fallbackDay
            result[day, default: .zero] = result[day, default: .zero] + usage.amount
        }
        return (result, blockers)
    }

    private static func invalidBuckets(_ usage: CodexUsageSnapshot) -> String? {
        if usage.input < 0 || usage.output < 0 || usage.cacheRead < 0 || usage.cacheWrite < 0 {
            return "negative token bucket"
        }
        if usage.cacheRead > usage.input || usage.cacheWrite > usage.input {
            return "cache bucket exceeds input_tokens"
        }
        if usage.cacheRead > usage.input - usage.cacheWrite {
            return "combined cache buckets exceed input_tokens"
        }
        return nil
    }

    private static func findForkCycles(_ graph: [String: Set<String>]) -> [[String]] {
        var state: [String: UInt8] = [:]
        var stack: [String] = []
        var found: [[String]] = []
        var signatures: Set<String> = []

        func canonical(_ cycle: [String]) -> String {
            let body = Array(cycle.dropLast())
            guard !body.isEmpty else { return "" }
            let rotations = body.indices.map { index in
                Array(body[index...]) + Array(body[..<index])
            }
            let normalized = rotations.min { $0.joined(separator: "\u{0}") < $1.joined(separator: "\u{0}") } ?? body
            return normalized.joined(separator: "\u{0}")
        }

        func visit(_ node: String) {
            state[node] = 1
            stack.append(node)
            for parent in (graph[node] ?? []).sorted() {
                if state[parent, default: 0] == 0 {
                    visit(parent)
                } else if state[parent] == 1, let start = stack.firstIndex(of: parent) {
                    let cycle = Array(stack[start...]) + [parent]
                    let signature = canonical(cycle)
                    if signatures.insert(signature).inserted { found.append(cycle) }
                }
            }
            _ = stack.popLast()
            state[node] = 2
        }

        for node in graph.keys.sorted() where state[node, default: 0] == 0 { visit(node) }
        return found
    }

    private static func retentionStartDay(now: Date) -> String {
        let cutoff = Calendar.current.date(byAdding: .day, value: -400, to: now) ?? now
        return Fmt.day(cutoff)
    }

    private static func aggregateByDay(_ rows: [String: UsageAmount]) -> [String: UsageAmount] {
        var result: [String: UsageAmount] = [:]
        for (key, amount) in rows {
            guard let delimiter = key.lastIndex(of: "|") else { continue }
            let day = String(key[key.index(after: delimiter)...])
            result[day, default: .zero] = result[day, default: .zero] + amount
        }
        return result
    }
}
