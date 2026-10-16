import Foundation
import CryptoKit

struct CodexUsageSnapshot: Codable, Equatable {
    var input: Int64
    var cacheRead: Int64
    var cacheWrite: Int64
    var output: Int64

    var amount: UsageAmount {
        UsageAmount(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite)
    }
}

struct CodexFingerprintField: Codable, Equatable {
    let present: Bool
    let value: Int64?
}

struct CodexFingerprintGroup: Codable, Equatable {
    let present: Bool
    let fields: [String: CodexFingerprintField]
}

struct CodexRawFingerprint: Codable, Equatable {
    let total: CodexFingerprintGroup
    let last: CodexFingerprintGroup
}

struct CodexTokenRecord {
    let fingerprint: CodexRawFingerprint
    let total: CodexUsageSnapshot?
    let last: CodexUsageSnapshot?
    let timestamp: Date?
    let endByte: Int64
    let rateLimits: [String: Any]?
}

struct CodexFileIdentity: Codable, Equatable {
    let inode: Int64
    let size: Int64
    let modifiedMilliseconds: Int64

    var signature: String { "\(inode)|\(modifiedMilliseconds)|\(size)" }
}

struct CodexForkDependency: Codable, Equatable {
    let path: String
    let sessionID: String
    var identity: CodexFileIdentity
    var checkedEventCount: Int
    var checkedEndByte: Int64
    var checkedPrefixSHA256: String
    var parentWasShorterThanChild: Bool
}

struct CodexFallbackSegment: Codable, Equatable {
    let startByte: Int64
    let endByte: Int64
    let day: String
}

struct CodexFileCursor: Codable {
    var formatVersion = 1
    var identity: CodexFileIdentity
    var offset: Int64
    var tokenEventCount: Int
    var fallbackSegments: [CodexFallbackSegment]
    var rawBaseline: CodexUsageSnapshot?
    /// SHA-256 over the complete newline-terminated raw bytes through `offset`.
    var committedRawSHA256: String?
    var sessionID: String?
    var forkedFromID: String?
    /// True after the authoritative first valid session_meta header has been
    /// observed. Optional for compatibility with cursors written by early v4 builds.
    var sessionMetaSeen: Bool? = nil
    var dependencies: [CodexForkDependency]
    var matchedPrefixCount: Int
    var forkPrefixOpen: Bool
    var childPrefixEndByte: Int64
    var prefixSHA256: String
}

struct CodexScannedFile {
    let url: URL
    let startOffset: Int64
    let identity: CodexFileIdentity
    let offset: Int64
    let trailingByteCount: Int64
    let committedRawSHA256: String?
    let sessionID: String?
    let forkedFromID: String?
    let sessionMetaSeen: Bool
    let events: [CodexTokenRecord]
}

enum CodexScanError: Error, CustomStringConvertible {
    case unavailable(String)
    case unstable(String)
    case invalid(String)

    var description: String {
        switch self {
        case .unavailable(let message), .unstable(let message), .invalid(let message): return message
        }
    }
}

enum CodexIndex {
    private(set) static var scanInvocationCount = 0
    private(set) static var fullScanInvocationCount = 0
    private(set) static var rawPrefixBytesRead: Int64 = 0
    private(set) static var scanInvocationPaths: [String] = []
    private(set) static var fullScanInvocationPaths: [String] = []

    static func resetScanCounters() {
        scanInvocationCount = 0
        fullScanInvocationCount = 0
        rawPrefixBytesRead = 0
        scanInvocationPaths = []
        fullScanInvocationPaths = []
    }
    static let usageFieldNames = [
        "input_tokens", "cached_input_tokens", "cache_write_input_tokens",
        "output_tokens", "reasoning_output_tokens", "total_tokens"
    ]
    private static let tokenCountNeedle = Data("token_count".utf8)
    private static let sessionMetaNeedle = Data("session_meta".utf8)

    static func identity(at url: URL) throws -> CodexFileIdentity {
        let attrs: [FileAttributeKey: Any]
        do { attrs = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch { throw CodexScanError.unavailable("cannot stat \(url.path): \(error)") }
        guard let size = (attrs[.size] as? NSNumber)?.int64Value,
              let modified = attrs[.modificationDate] as? Date else {
            throw CodexScanError.unavailable("cannot read file identity: \(url.path)")
        }
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.int64Value ?? 0
        return CodexFileIdentity(
            inode: inode,
            size: size,
            modifiedMilliseconds: Int64((modified.timeIntervalSince1970 * 1000).rounded())
        )
    }

    static func scan(
        _ url: URL,
        from offset: Int64 = 0,
        through requestedEnd: Int64? = nil,
        maximumEvents: Int? = nil,
        inheritedSessionID: String? = nil,
        inheritedForkedFromID: String? = nil,
        inheritedSessionMetaSeen: Bool = false,
        fixedIdentity: CodexFileIdentity? = nil,
        startingHasher: SHA256? = nil
    ) throws -> CodexScannedFile {
        scanInvocationCount += 1
        scanInvocationPaths.append(url.path)
        if offset == 0, requestedEnd == nil, maximumEvents == nil {
            fullScanInvocationCount += 1
            fullScanInvocationPaths.append(url.path)
        }
        let actualBefore = try identity(at: url)
        let before = fixedIdentity ?? actualBefore
        guard actualBefore.inode == before.inode, actualBefore.size >= before.size else {
            throw CodexScanError.unstable("file changed before scanning: \(url.path)")
        }
        if actualBefore.size == before.size, actualBefore.modifiedMilliseconds != before.modifiedMilliseconds {
            throw CodexScanError.unstable("file changed before scanning: \(url.path)")
        }
        guard offset >= 0, offset <= before.size else {
            throw CodexScanError.unstable("file was truncated before scanning: \(url.path)")
        }
        let boundary = min(before.size, requestedEnd ?? before.size)
        guard boundary >= offset else {
            throw CodexScanError.unstable("invalid scan boundary: \(url.path)")
        }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { throw CodexScanError.unavailable("cannot read \(url.path): \(error)") }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: UInt64(offset)) }
        catch { throw CodexScanError.unavailable("cannot seek \(url.path): \(error)") }

        var hasher = maximumEvents == nil ? (startingHasher ?? SHA256()) : nil
        var pending = Data()
        var pendingSearchOffset = 0
        var absolutePosition = offset
        var consumedEnd = offset
        var records: [CodexTokenRecord] = []
        var sessionID = inheritedSessionID
        var forkedFromID = inheritedForkedFromID
        var sessionMetaSeen = inheritedSessionMetaSeen

        scanLoop: while absolutePosition < boundary, maximumEvents.map({ records.count < $0 }) ?? true {
            let requested = Int(min(64 * 1024, boundary - absolutePosition))
            let chunk: Data
            do { chunk = try handle.read(upToCount: requested) ?? Data() }
            catch { throw CodexScanError.unavailable("cannot read \(url.path): \(error)") }
            guard !chunk.isEmpty else {
                throw CodexScanError.unstable("short read while scanning \(url.path)")
            }
            absolutePosition += Int64(chunk.count)
            pending.append(chunk)
            var consumedLength = 0
            var searchOffset = pendingSearchOffset
            var reachedMaximumEvents = false
            while let newlineOffset = newlineOffset(in: pending, from: searchOffset) {
                let lineEnd = newlineOffset + 1
                let line = pending[consumedLength..<lineEnd]
                consumedEnd += Int64(lineEnd - consumedLength)
                hasher?.update(data: line)
                if line.range(of: Self.tokenCountNeedle) != nil
                    || line.range(of: Self.sessionMetaNeedle) != nil {
                    autoreleasepool {
                        guard let object = parseObject(line) else { return }
                        if !sessionMetaSeen {
                            sessionMetaSeen = readSessionMeta(object, sessionID: &sessionID, forkedFromID: &forkedFromID)
                        }
                        guard let payload = object["payload"] as? [String: Any],
                              payload["type"] as? String == "token_count",
                              let info = payload["info"] as? [String: Any] else { return }
                        let totalObject = info["total_token_usage"] as? [String: Any]
                        let lastObject = info["last_token_usage"] as? [String: Any]
                        let total = usageSnapshot(totalObject)
                        let last = usageSnapshot(lastObject)
                        let timestamp = (object["timestamp"] as? String).flatMap(parseTimestamp)
                        let rateLimits = payload["rate_limits"] as? [String: Any]
                        records.append(CodexTokenRecord(
                            fingerprint: CodexRawFingerprint(
                                total: fingerprintGroup(info["total_token_usage"]),
                                last: fingerprintGroup(info["last_token_usage"])
                            ),
                            total: total, last: last, timestamp: timestamp,
                            endByte: consumedEnd, rateLimits: rateLimits
                        ))
                    }
                }
                consumedLength = lineEnd
                searchOffset = lineEnd
                if let maximumEvents, records.count >= maximumEvents {
                    reachedMaximumEvents = true
                    break
                }
            }
            if !reachedMaximumEvents { searchOffset = pending.count }
            if consumedLength > 0 { pending.removeSubrange(0..<consumedLength) }
            pendingSearchOffset = reachedMaximumEvents ? 0 : max(0, searchOffset - consumedLength)
            if reachedMaximumEvents { break scanLoop }
        }

        let trailing = Int64(pending.count)
        let after = try identity(at: url)
        guard after.inode == before.inode, after.size >= boundary else {
            throw CodexScanError.unstable("file was replaced or truncated while scanning: \(url.path)")
        }
        if after.size == before.size, after.modifiedMilliseconds != before.modifiedMilliseconds {
            throw CodexScanError.unstable("file changed while scanning: \(url.path)")
        }
        let digest = hasher.map(digestString)
        return CodexScannedFile(
            url: url, startOffset: offset, identity: before, offset: consumedEnd, trailingByteCount: trailing,
            committedRawSHA256: digest, sessionID: sessionID, forkedFromID: forkedFromID,
            sessionMetaSeen: sessionMetaSeen, events: records
        )
    }

    /// Build a resumable SHA-256 state over a committed raw byte prefix. The
    /// caller compares `digestString` with the stored digest before using the
    /// state to continue hashing newly appended complete lines.
    static func rawHasher(
        _ url: URL, through end: Int64, fixedIdentity: CodexFileIdentity
    ) throws -> SHA256 {
        let actualBefore = try identity(at: url)
        guard actualBefore.inode == fixedIdentity.inode,
              actualBefore.size >= fixedIdentity.size,
              end >= 0, end <= fixedIdentity.size else {
            throw CodexScanError.unstable("file changed before prefix verification: \(url.path)")
        }
        if actualBefore.size == fixedIdentity.size,
           actualBefore.modifiedMilliseconds != fixedIdentity.modifiedMilliseconds {
            throw CodexScanError.unstable("file changed before prefix verification: \(url.path)")
        }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { throw CodexScanError.unavailable("cannot verify \(url.path): \(error)") }
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = end
        while remaining > 0 {
            let requested = Int(min(1024 * 1024, remaining))
            let data: Data
            do { data = try handle.read(upToCount: requested) ?? Data() }
            catch { throw CodexScanError.unavailable("cannot verify \(url.path): \(error)") }
            guard !data.isEmpty else {
                throw CodexScanError.unstable("short read while verifying prefix: \(url.path)")
            }
            hasher.update(data: data)
            remaining -= Int64(data.count)
            rawPrefixBytesRead += Int64(data.count)
        }
        let actualAfter = try identity(at: url)
        guard actualAfter.inode == fixedIdentity.inode,
              actualAfter.size >= fixedIdentity.size else {
            throw CodexScanError.unstable("file was replaced or truncated during prefix verification: \(url.path)")
        }
        if actualAfter.size == fixedIdentity.size,
           actualAfter.modifiedMilliseconds != fixedIdentity.modifiedMilliseconds {
            throw CodexScanError.unstable("file changed during prefix verification: \(url.path)")
        }
        return hasher
    }

    static func digestString(_ hasher: SHA256) -> String {
        let copy = hasher
        return copy.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func prefixSHA256(_ events: [CodexTokenRecord], count: Int) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var hasher = SHA256()
        for event in events.prefix(max(0, count)) {
            let encoded = try encoder.encode(event.fingerprint)
            var length = UInt64(encoded.count).bigEndian
            var step = SHA256()
            step.update(data: Data(hasher.finalize()))
            withUnsafeBytes(of: &length) { step.update(data: Data($0)) }
            step.update(data: encoded)
            hasher = step
        }
        return digestString(hasher)
    }

    static func extendPrefixSHA256(_ previous: String, with events: [CodexTokenRecord]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var current = previous
        for event in events {
            let encoded = try encoder.encode(event.fingerprint)
            guard let prior = dataFromHex(current) else {
                throw CodexScanError.invalid("invalid stored Codex prefix fingerprint")
            }
            var length = UInt64(encoded.count).bigEndian
            var step = SHA256()
            step.update(data: prior)
            withUnsafeBytes(of: &length) { step.update(data: Data($0)) }
            step.update(data: encoded)
            current = digestString(step)
        }
        return current
    }

    static func parseObject(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed])) as? [String: Any]
    }

    /// Search only bytes not inspected during the previous append. `memchr`
    /// avoids Data's per-byte Collection accessor on large session files.
    private static func newlineOffset(in data: Data, from offset: Int) -> Int? {
        guard offset < data.count else { return nil }
        return data.withUnsafeBytes { buffer -> Int? in
            guard let base = buffer.baseAddress,
                  let match = memchr(base.advanced(by: offset), 10, buffer.count - offset) else { return nil }
            return base.distance(to: UnsafeRawPointer(match))
        }
    }

    private static func dataFromHex(_ value: String) -> Data? {
        let bytes = Array(value.utf8)
        guard bytes.count.isMultiple(of: 2) else { return nil }
        var data = Data()
        data.reserveCapacity(bytes.count / 2)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let byte = UInt8(String(bytes: bytes[index..<(index + 2)], encoding: .utf8) ?? "", radix: 16) else {
                return nil
            }
            data.append(byte)
        }
        return data
    }

    private static func readSessionMeta(
        _ object: [String: Any], sessionID: inout String?, forkedFromID: inout String?
    ) -> Bool {
        guard object["type"] as? String == "session_meta" else { return false }
        let payload = object["payload"] as? [String: Any] ?? [:]
        let meta = object["session_meta"] as? [String: Any] ?? payload
        let foundID = (meta["id"] as? String) ?? (payload["id"] as? String) ?? (object["id"] as? String)
        guard let foundID, !foundID.isEmpty else { return false }
        let foundParent = (meta["forked_from_id"] as? String)
            ?? (payload["forked_from_id"] as? String)
            ?? (object["forked_from_id"] as? String)
        sessionID = foundID
        forkedFromID = foundParent.flatMap { $0.isEmpty ? nil : $0 }
        return true
    }

    private static func fingerprintGroup(_ value: Any?) -> CodexFingerprintGroup {
        guard let dict = value as? [String: Any] else {
            return CodexFingerprintGroup(present: value != nil, fields: [:])
        }
        let fields = Dictionary(uniqueKeysWithValues: usageFieldNames.map { key in
            let raw = dict[key]
            return (key, CodexFingerprintField(present: raw != nil, value: integer(raw)))
        })
        return CodexFingerprintGroup(present: true, fields: fields)
    }

    private static func usageSnapshot(_ dict: [String: Any]?) -> CodexUsageSnapshot? {
        guard let dict else { return nil }
        return CodexUsageSnapshot(
            input: integer(dict["input_tokens"]) ?? 0,
            cacheRead: integer(dict["cached_input_tokens"]) ?? 0,
            cacheWrite: integer(dict["cache_write_input_tokens"]) ?? 0,
            output: integer(dict["output_tokens"]) ?? 0
        )
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber else { return nil }
        return number.int64Value
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        if let date = Formatters.isoFractional.date(from: value) { return date }
        return Formatters.isoPlain.date(from: value)
    }
}
