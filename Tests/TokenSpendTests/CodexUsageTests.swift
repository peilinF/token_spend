import Foundation
import Darwin
import CryptoKit

@main
struct CodexUsageTests {
    private var fixtures: [URL] = []

    static func main() async throws {
        let childArguments = Array(CommandLine.arguments.dropFirst())
        if childArguments.first == "--hold-codex-file-lock" {
            guard childArguments.count == 4 else { throw SQLiteError(message: "bad lock-holder arguments") }
            let databaseURL = URL(fileURLWithPath: childArguments[1])
            let readyURL = URL(fileURLWithPath: childArguments[2])
            let releaseURL = URL(fileURLWithPath: childArguments[3])
            try CodexSource.withDatabaseFileLock(databaseURL: databaseURL) {
                try Data("locked".utf8).write(to: readyURL)
                let deadline = Date().addingTimeInterval(10)
                while !FileManager.default.fileExists(atPath: releaseURL.path) {
                    guard Date() < deadline else { throw SQLiteError(message: "lock holder timed out") }
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
            return
        }
        if childArguments.first == "--refresh-codex-once" {
            guard childArguments.count == 5 else { throw SQLiteError(message: "bad refresh-worker arguments") }
            let store = UsageStore(databaseURL: URL(fileURLWithPath: childArguments[1]))
            let sessionsURL = URL(fileURLWithPath: childArguments[2], isDirectory: true)
            let startedURL = URL(fileURLWithPath: childArguments[3])
            let finishedURL = URL(fileURLWithPath: childArguments[4])
            try Data("started".utf8).write(to: startedURL)
            try CodexSource.refresh(store: store, sessionsDirectory: sessionsURL)
            try Data("finished".utf8).write(to: finishedURL)
            return
        }
        if childArguments.first == "--scan-session-readonly" {
            guard childArguments.count == 2 else { throw SQLiteError(message: "expected one session file path") }
            let startedAt = Date()
            let scan = try CodexIndex.scan(URL(fileURLWithPath: childArguments[1]))
            print("bytes=\(scan.identity.size) events=\(scan.events.count) committed=\(scan.offset) trailing=\(scan.trailingByteCount) elapsed_ms=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
            return
        }
        var tests = CodexUsageTests()
        defer { for url in tests.fixtures { try? FileManager.default.removeItem(at: url) } }
        try tests.testInheritedHistoryAndCacheAreNotCountedTwice()
        try tests.testDuplicateSnapshotsAndIncrementalRefresh()
        try tests.testScannerHandlesMultichunkLinesAndPartialTail()
        try tests.testFirstSessionHeaderOwnsCopiedHistoryIdentity()
        try tests.testCounterResetStartsWithLatestRequest()
        try tests.testIncompleteLineIsReReadOnceCompleted()
        try tests.testForkPrefixesAndChildUsageAreCountedOnce()
        try tests.testParentAppendAndNewChildUseParentRawPrefix()
        try tests.testSameLastWithDifferentTotalsEndsThePrefix()
        try tests.testMissingAndZeroFieldsDoNotMatch()
        try tests.testRestartAndStablePollDoNotRescan()
        try tests.testCommittedPrefixRewritePlusGrowthForcesFullRebuild()
        try tests.testFullRewriteWithoutHeaderClearsMetadataSeenFlag()
        try tests.testOpenForkPrefixExtendsAcrossAppendBatches()
        try tests.testParentAppendDoesNotRebuildUnchangedChild()
        try tests.testNewRecoveryCandidateAndChildAppendRecomputeSameCycle()
        try tests.testRefreshRejectsConflictingParentRelationshipsWithoutWriting()
        try tests.testReconcileReselectsSurvivingRecoveryParent()
        try tests.testCrossProcessRefreshesShareDatabaseLock()
        try tests.testNestedForksAndMultipleRecoveryParents()
        try tests.testV4IncompleteLineIsCommittedOnlyWhenCompleted()
        try tests.testPrecommitPrefixRewriteAbortsWholeStage()
        try tests.testDivergedForkDoesNotDependOnParentEOF()
        try tests.testEOFDependentForkAppendAbortsWholeStage()
        try tests.testAuditIsReadonlyAndMatchesCommittedContributions()
        try tests.testAuditRejectsInvalidBucketsIncludingCopiedPrefix()
        try tests.testAuditRejectsForkCyclesAndConflictingRelationships()
        try tests.testAuditFailureWritesReportFile()
        try tests.testMissingParentLeavesCommittedRowsAndCursorsUntouched()
        try tests.testReconcileAllowsDeletingChildAndParentTogether()
        try tests.testReconcileDeletesExactMetadataKeysWithPipePaths()
        try tests.testBackupFailurePreservesOldVersionAndRows()
        try tests.testMigrationCommitFailurePreservesOldCodexRows()
        try tests.testQuotaNewerObservationWinsResetRegression()
        try tests.testQuotaEqualObservationRepairsStoredWindow()
        try tests.testQuotaDelayedOlderObservationIsIgnored()
        try tests.testQuotaMissingWindowKeepsItsOwnObservationTime()
        try tests.testQuotaClassificationIgnoresRawPosition()
        try tests.testLegacyQuotaPrimePreservesUsageRowsAndCursor()
        try tests.testLegacyPrimeFlagSurvivesShortOnlyMerge()
        tests.testChineseTokenUnits()
        try await CursorQuotaTests.run()
        print("Passed 41 Codex usage, fork, storage, quota, audit, locking, and unit regression checks")
    }
    private func event(input: Int64, cache: Int64, output: Int64,
                       lastInput: Int64, lastCache: Int64, lastOutput: Int64,
                       timestamp: String = "2026-10-08T05:00:00Z") throws -> Data {
        let obj: [String: Any] = [
            "timestamp": timestamp,
            "payload": ["type": "token_count", "info": [
                "total_token_usage": ["input_tokens": input, "cached_input_tokens": cache, "output_tokens": output],
                "last_token_usage": ["input_tokens": lastInput, "cached_input_tokens": lastCache, "output_tokens": lastOutput]
            ]]
        ]
        var data = try JSONSerialization.data(withJSONObject: obj)
        data.append(10)
        return data
    }

    private mutating func fixture(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        try data.write(to: url)
        fixtures.append(url)
        return url
    }

    mutating func testInheritedHistoryAndCacheAreNotCountedTwice() throws {
        let data = try event(input: 191_415_137, cache: 179_782_400, output: 578_048,
                             lastInput: 153_039, lastCache: 152_832, lastOutput: 221)
        let result = CodexSource.parseChunk(try fixture(data), from: 0, baseline: nil)
        guard let amount = result.0["2026-10-08"] else { fatalError("Missing usage day") }
        checkEqual(amount.input, 207)
        checkEqual(amount.total(mode: .lean), 428)
        checkEqual(amount.total(mode: .full), 153_260)
    }

    mutating func testDuplicateSnapshotsAndIncrementalRefresh() throws {
        let first = try event(input: 1000, cache: 800, output: 100,
                              lastInput: 1000, lastCache: 800, lastOutput: 100)
        let url = try fixture(first + first)
        let initial = CodexSource.parseChunk(url, from: 0, baseline: nil)
        checkEqual(initial.0["2026-10-08"]?.total(mode: .full), 1100)
        let next = try event(input: 1500, cache: 1200, output: 150,
                             lastInput: 500, lastCache: 400, lastOutput: 50,
                             timestamp: "2026-10-09T05:00:00Z")
        try (first + first + next).write(to: url)
        let increment = CodexSource.parseChunk(url, from: initial.1, baseline: initial.3)
        checkEqual(increment.0["2026-10-09"]?.total(mode: .full), 550)
        checkEqual(increment.0["2026-10-09"]?.total(mode: .lean), 150)
        precondition(increment.0["2026-10-08"] == nil)
    }

    mutating func testScannerHandlesMultichunkLinesAndPartialTail() throws {
        let metadata = try JSONSerialization.data(withJSONObject: [
            "type": "session_meta", "payload": ["id": "multichunk"]
        ]) + Data([10])
        let largeNonCandidateLine = Data("{\"type\":\"message\",\"text\":\"".utf8)
            + Data(repeating: 97, count: 256 * 1024)
            + Data("\"}\n".utf8)
        let completeEvent = try codexEvent(total: usage(input: 100, cache: 40, output: 10),
                                           last: usage(input: 100, cache: 40, output: 10))
        let incompleteEvent = try codexEvent(total: usage(input: 150, cache: 60, output: 15),
                                             last: usage(input: 50, cache: 20, output: 5))
        let committedBytes = metadata + largeNonCandidateLine + completeEvent
        let file = try fixture(committedBytes + Data(incompleteEvent.dropLast()))

        let initial = try CodexIndex.scan(file)

        checkEqual(initial.offset, Int64(committedBytes.count))
        checkEqual(initial.trailingByteCount, Int64(incompleteEvent.count - 1))
        checkEqual(initial.events.count, 1)
        checkEqual(initial.sessionID, "multichunk")
        checkEqual(initial.committedRawSHA256, Self.sha256(committedBytes))

        try append(Data([10]), to: file)
        let identity = try CodexIndex.identity(at: file)
        let priorHasher = try CodexIndex.rawHasher(file, through: initial.offset, fixedIdentity: identity)
        let appended = try CodexIndex.scan(
            file, from: initial.offset, inheritedSessionID: initial.sessionID,
            inheritedForkedFromID: initial.forkedFromID,
            inheritedSessionMetaSeen: initial.sessionMetaSeen,
            fixedIdentity: identity, startingHasher: priorHasher
        )
        let full = try CodexIndex.scan(file)
        let completeFileBytes = committedBytes + incompleteEvent
        checkEqual(appended.startOffset, initial.offset)
        checkEqual(appended.offset, Int64(completeFileBytes.count))
        checkEqual(appended.trailingByteCount, 0)
        checkEqual(appended.events.count, 1)
        checkEqual(appended.committedRawSHA256, Self.sha256(completeFileBytes))
        checkEqual(appended.committedRawSHA256, full.committedRawSHA256)
        checkEqual(full.events.count, 2)
    }

    mutating func testFirstSessionHeaderOwnsCopiedHistoryIdentity() throws {
        let context = try tempStore()
        let first = try codexEvent(total: usage(input: 100, cache: 40, output: 10),
                                   last: usage(input: 100, cache: 40, output: 10))
        let second = try codexEvent(total: usage(input: 150, cache: 60, output: 15),
                                    last: usage(input: 50, cache: 20, output: 5))
        let third = try codexEvent(total: usage(input: 180, cache: 75, output: 18),
                                   last: usage(input: 30, cache: 15, output: 3))
        let fourth = try codexEvent(total: usage(input: 190, cache: 80, output: 20),
                                    last: usage(input: 10, cache: 5, output: 2))
        let grandparent = try writeSession(context.sessions, name: "grandparent.jsonl", id: "grandparent",
                                           events: first)
        let parent = try writeSession(context.sessions, name: "parent.jsonl", id: "parent",
                                      parentID: "grandparent", events: first + second,
                                      trailingMetadata: [try sessionMeta(id: "grandparent")])
        let child = try writeSession(context.sessions, name: "child.jsonl", id: "child", parentID: "parent",
                                     events: first + second + third,
                                     trailingMetadata: [try sessionMeta(id: "parent", parentID: "grandparent"),
                                                        try sessionMeta(id: "grandparent")])

        try CodexSource.refresh(store: context.store, sessionsDirectory: context.sessions, backupURL: context.backup)

        let childCursor = try cursor(for: child, in: context.store)
        checkEqual(childCursor.sessionID, "child")
        checkEqual(childCursor.forkedFromID, "parent")
        checkEqual(childCursor.sessionMetaSeen, true)
        checkEqual(childCursor.matchedPrefixCount, 2)
        checkEqual(try cursor(for: parent, in: context.store).sessionID, "parent")
        checkEqual(try cursor(for: parent, in: context.store).forkedFromID, "grandparent")
        checkEqual(try cursor(for: grandparent, in: context.store).sessionID, "grandparent")
        checkEqual(try amount(in: context.store, path: child.path).total(mode: .lean), 18)
        checkEqual(try amount(in: context.store, path: child.path).total(mode: .full), 33)

        try append(try sessionMeta(id: "parent", parentID: "grandparent") + sessionMeta(id: "grandparent") + fourth,
                   to: child)
        try CodexSource.refresh(store: context.store, sessionsDirectory: context.sessions)

        let incremented = try cursor(for: child, in: context.store)
        checkEqual(incremented.sessionID, "child")
        checkEqual(incremented.forkedFromID, "parent")
        checkEqual(incremented.matchedPrefixCount, 2)
        checkEqual(try amount(in: context.store, path: child.path).total(mode: .lean), 25)
        checkEqual(try amount(in: context.store, path: child.path).total(mode: .full), 45)
        let report = try CodexAudit.makeReport(databaseURL: context.database, sessionsDirectory: context.sessions)
        precondition(report.consistent, "copied session headers should agree with readonly fork audit: \(report.blockers)")
    }

    mutating func testCounterResetStartsWithLatestRequest() throws {
        let first = try event(input: 1000, cache: 800, output: 100,
                              lastInput: 1000, lastCache: 800, lastOutput: 100)
        let reset = try event(input: 700, cache: 400, output: 70,
                              lastInput: 200, lastCache: 100, lastOutput: 20)
        let result = CodexSource.parseChunk(try fixture(first + reset), from: 0, baseline: nil)
        checkEqual(result.0["2026-10-08"]?.total(mode: .full), 1320)
        checkEqual(result.0["2026-10-08"]?.total(mode: .lean), 420)
    }

    mutating func testIncompleteLineIsReReadOnceCompleted() throws {
        let data = try event(input: 1000, cache: 800, output: 100,
                             lastInput: 1000, lastCache: 800, lastOutput: 100)
        let url = try fixture(Data(data.dropLast()))
        let partial = CodexSource.parseChunk(url, from: 0, baseline: nil)
        precondition(partial.0.isEmpty)
        checkEqual(partial.1, 0)
        try data.write(to: url)
        let complete = CodexSource.parseChunk(url, from: partial.1, baseline: partial.3)
        checkEqual(complete.0["2026-10-08"]?.total(mode: .full), 1100)
    }

    mutating func testForkPrefixesAndChildUsageAreCountedOnce() throws {
        let context = try tempStore()
        let first = try codexEvent(total: usage(input: 1_000, cache: 800, output: 100),
                                   last: usage(input: 1_000, cache: 800, output: 100))
        let second = try codexEvent(total: usage(input: 1_500, cache: 1_200, output: 150),
                                    last: usage(input: 500, cache: 400, output: 50))
        let parent = try writeSession(context.sessions, name: "parent.jsonl", id: "parent", events: first + second)
        let childOne = try writeSession(
            context.sessions, name: "child-one.jsonl", id: "child-one", parentID: "parent",
            events: try codexEvent(total: usage(input: 1_000, cache: 800, output: 100),
                                   last: usage(input: 1_000, cache: 800, output: 100),
                                   timestamp: "2026-10-09T01:00:00Z")
                + codexEvent(total: usage(input: 1_500, cache: 1_200, output: 150),
                             last: usage(input: 500, cache: 400, output: 50),
                             timestamp: "2026-10-09T01:01:00Z")
                + codexEvent(total: usage(input: 1_600, cache: 1_250, output: 160),
                             last: usage(input: 100, cache: 50, output: 10))
        )
        let childTwo = try writeSession(
            context.sessions, name: "child-two.jsonl", id: "child-two", parentID: "parent",
            events: first + second + codexEvent(total: usage(input: 1_700, cache: 1_300, output: 170),
                                                last: usage(input: 200, cache: 100, output: 20))
        )
        try CodexSource.refresh(store: context.store, sessionsDirectory: context.sessions, backupURL: context.backup)

        checkEqual(try amount(in: context.store, path: parent.path).total(mode: .lean), 450)
        checkEqual(try amount(in: context.store, path: childOne.path).total(mode: .lean), 60)
        checkEqual(try amount(in: context.store, path: childTwo.path).total(mode: .lean), 120)
        let all = try amount(in: context.store, path: parent.path)
            + amount(in: context.store, path: childOne.path)
            + amount(in: context.store, path: childTwo.path)
        checkEqual(all.total(mode: .lean), 630)
        checkEqual(all.total(mode: .full), 1_980)
        checkEqual(try cursor(for: childOne, in: context.store).matchedPrefixCount, 2)
        checkEqual(try cursor(for: childTwo, in: context.store).matchedPrefixCount, 2)
        let permissions = try FileManager.default.attributesOfItem(atPath: context.backup.path)[.posixPermissions] as? NSNumber
        checkEqual(permissions?.intValue, 0o600)
    }

    mutating func testParentAppendAndNewChildUseParentRawPrefix() throws {
        let context = try tempStore()
        let first = try codexEvent(total: usage(input: 1_000, cache: 800, output: 100),
                                   last: usage(input: 1_000, cache: 800, output: 100))
        let second = try codexEvent(total: usage(input: 1_500, cache: 1_200, output: 150),
                                    last: usage(input: 500, cache: 400, output: 50))
        let parent = try writeSession(context.sessions, name: "parent.jsonl", id: "parent", events: first + second)
        try CodexSource.refresh(store: context.store, sessionsDirectory: context.sessions, backupURL: context.backup)

        let parentThird = try codexEvent(total: usage(input: 1_700, cache: 1_300, output: 170),
                                         last: usage(input: 200, cache: 100, output: 20))
        let handle = try FileHandle(forWritingTo: parent)
        try handle.seekToEnd()
        try handle.write(contentsOf: parentThird)
        try handle.close()
        let child = try writeSession(
            context.sessions, name: "child.jsonl", id: "child", parentID: "parent",
            events: first + second + codexEvent(total: usage(input: 1_600, cache: 1_250, output: 160),
                                                last: usage(input: 100, cache: 50, output: 10))
        )
        try CodexSource.refresh(store: context.store, sessionsDirectory: context.sessions)

        checkEqual(try cursor(for: child, in: context.store).matchedPrefixCount, 2)
        checkEqual(try amount(in: context.store, path: child.path).total(mode: .lean), 60)
        checkEqual(try amount(in: context.store, path: parent.path).total(mode: .lean), 570)
    }

    mutating func testSameLastWithDifferentTotalsEndsThePrefix() throws {
        let context = try tempStore()
        let first = try codexEvent(total: usage(input: 100, cache: 0, output: 10),
                                   last: usage(input: 100, cache: 0, output: 10))
        let parentSecond = try codexEvent(total: usage(input: 300, cache: 0, output: 30),
                                          last: usage(input: 100, cache: 0, output: 10))
        let childSecond = try codexEvent(total: usage(input: 200, cache: 0, output: 20),
                                         last: usage(input: 100, cache: 0, output: 10))
        _ = try writeSession(context.sessions, name: "parent.jsonl", id: "parent", events: first + parentSecond)
        let child = try writeSession(context.sessions, name: "child.jsonl", id: "child", parentID: "parent",
                                     events: first + childSecond)
        try CodexSource.refresh(store: context.store, sessionsDirectory: context.sessions, backupURL: context.backup)
        checkEqual(try cursor(for: child, in: context.store).matchedPrefixCount, 1)
        checkEqual(try amount(in: context.store, path: child.path).total(mode: .full), 110)
    }

    mutating func testMissingAndZeroFieldsDoNotMatch() throws {
        let context = try tempStore()
        let parentEvent = try codexEvent(total: ["input_tokens": 100], last: ["input_tokens": 100])
        let childEvent = try codexEvent(total: ["input_tokens": 100, "output_tokens": 0],
                                        last: ["input_tokens": 100, "output_tokens": 0])
        _ = try writeSession(context.sessions, name: "parent.jsonl", id: "parent", events: parentEvent)
        let child = try writeSession(context.sessions, name: "child.jsonl", id: "child", parentID: "parent", events: childEvent)
        try CodexSource.refresh(store: context.store, sessionsDirectory: context.sessions, backupURL: context.backup)
        checkEqual(try cursor(for: child, in: context.store).matchedPrefixCount, 0)
        checkEqual(try amount(in: context.store, path: child.path).input, 100)
    }

    mutating func testRestartAndStablePollDoNotRescan() throws {
        let root = try tempDirectory()
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("db/store.db")
        let backup = root.appendingPathComponent("db/backup.db")
        let eventData = try codexEvent(total: usage(input: 100, cache: 0, output: 10),
                                       last: usage(input: 100, cache: 0, output: 10))
        _ = try writeSession(sessions, name: "one.jsonl", id: "one", events: eventData)
        var store: UsageStore? = UsageStore(databaseURL: database)
        try CodexSource.refresh(store: store!, sessionsDirectory: sessions, backupURL: backup)
        checkEqual(try store!.dailyTotals(sinceDay: "0000-01-01")[.codex]?.values.reduce(.zero, +).total(mode: .full), 110)
        store = nil

        let restarted = UsageStore(databaseURL: database)
        CodexIndex.resetScanCounters()
        try CodexSource.refresh(store: restarted, sessionsDirectory: sessions)
        checkEqual(CodexIndex.scanInvocationCount, 0)
        checkEqual(CodexIndex.fullScanInvocationCount, 0)
        checkEqual(try restarted.dailyTotals(sinceDay: "0000-01-01")[.codex]?.values.reduce(.zero, +).total(mode: .full), 110)
    }

    mutating func testCommittedPrefixRewritePlusGrowthForcesFullRebuild() throws {
        let context = try tempStore()
        let first = try codexEvent(total: usage(input: 100, cache: 0, output: 10),
                                   last: usage(input: 100, cache: 0, output: 10))
        let second = try codexEvent(total: usage(input: 200, cache: 0, output: 20),
                                    last: usage(input: 100, cache: 0, output: 10))
        let file = try writeSession(context.sessions, name: "rewrite.jsonl", id: "rewrite", events: first)
        try CodexSource.refresh(store: context.store, sessionsDirectory: context.sessions, backupURL: context.backup)
        let beforeIdentity = try CodexIndex.identity(at: file)
        let initialCursor = try cursor(for: file, in: context.store)
        precondition(initialCursor.committedRawSHA256 != nil)

        let replacement = try codexEvent(total: usage(input: 100, cache: 0, output: 10),
                                         last: usage(input: 100, cache: 0, output: 10),
                                         timestamp: "2026-10-08T06:00:00Z")
        precondition(first.count == replacement.count)
        let contents = try Data(contentsOf: file)
        guard let range = contents.range(of: first) else { fatalError("could not locate committed event") }
        let handle = try FileHandle(forWritingTo: file)
        try handle.seek(toOffset: UInt64(range.lowerBound))
        try handle.write(contentsOf: replacement)
        try handle.seekToEnd()
        try handle.write(contentsOf: second)
        try handle.close()
        let afterIdentity = try CodexIndex.identity(at: file)
        checkEqual(afterIdentity.inode, beforeIdentity.inode)
        precondition(afterIdentity.size > beforeIdentity.size)

        CodexIndex.resetScanCounters()
        try CodexSource.refresh(store: context.store, sessionsDirectory: context.sessions)
        precondition(CodexIndex.fullScanInvocationPaths.contains(file.path), "prefix rewrite must force a complete scan")
        checkEqual(try cursor(for: file, in: context.store).tokenEventCount, 2)
        checkEqual(try amount(in: context.store, path: file.path).total(mode: .full), 220)
    }

    mutating func testFullRewriteWithoutHeaderClearsMetadataSeenFlag() throws {
        let context = try tempStore()
        let first = try codexEvent(total: usage(input: 100, cache: 0, output: 10),
                                   last: usage(input: 100, cache: 0, output: 10))
        let second = try codexEvent(total: usage(input: 200, cache: 0, output: 20),
                                    last: usage(input: 100, cache: 0, output: 10))
        let third = try codexEvent(total: usage(input: 300, cache: 0, output: 30),
                                   last: usage(input: 100, cache: 0, output: 10))
        let file = try writeSession(context.sessions, name: "metadata-rewrite.jsonl", id: "rewritten", events: first)
        try CodexSource.refresh(store: context.store, sessionsDirectory: context.sessions, backupURL: context.backup)
        let initialCursor = try cursor(for: file, in: context.store)
        precondition(initialCursor.sessionMetaSeen == true)

        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: first + second)
        try handle.close()
        try CodexSource.refresh(store: context.store, sessionsDirectory: context.sessions)
        let rewrittenCursor = try cursor(for: file, in: context.store)
        checkEqual(rewrittenCursor.sessionMetaSeen, false)
        checkEqual(rewrittenCursor.sessionID, nil)

        try append(try sessionMeta(id: "restored") + third, to: file)
        try CodexSource.refresh(store: context.store, sessionsDirectory: context.sessions)
        let restoredCursor = try cursor(for: file, in: context.store)
        checkEqual(restoredCursor.sessionMetaSeen, true)
        checkEqual(restoredCursor.sessionID, "restored")
        checkEqual(restoredCursor.tokenEventCount, 3)
        checkEqual(try amount(in: context.store, path: file.path).total(mode: .full), 330)
    }

    mutating func testOpenForkPrefixExtendsAcrossAppendBatches() throws {
        let context = try tempStore()
        let first = try codexEvent(total: usage(input: 1_000, cache: 800, output: 100),
                                   last: usage(input: 1_000, cache: 800, output: 100))
        let second = try codexEvent(total: usage(input: 1_500, cache: 1_200, output: 150),
                                    last: usage(input: 500, cache: 400, output: 50))
        let third = try codexEvent(total: usage(input: 1_600, cache: 1_250, output: 160),
                                   last: usage(input: 100, cache: 50, output: 10))
        _ = try writeSession(context.sessions, name: "parent.jsonl", id: "parent", events: first + second)
        let child = try writeSession(context.sessions, name: "empty-child.jsonl", id: "child", parentID: "parent", events: Data())
        try CodexSource.refresh(store: context.store, sessionsDirectory: context.sessions, backupURL: context.backup)
        let emptyCursor = try cursor(for: child, in: context.store)
        precondition(emptyCursor.forkPrefixOpen)
        checkEqual(try cursor(for: child, in: context.store).matchedPrefixCount, 0)

        try append(first, to: child)
        try CodexSource.refresh(store: context.store, sessionsDirectory: context.sessions)
        checkEqual(try cursor(for: child, in: context.store).matchedPrefixCount, 1)
        checkEqual(try cursor(for: child, in: context.store).forkPrefixOpen, true)
        checkEqual(try amount(in: context.store, path: child.path).total(mode: .full), 0)

        try append(second, to: child)
        try CodexSource.refresh(store: context.store, sessionsDirectory: context.sessions)
        checkEqual(try cursor(for: child, in: context.store).matchedPrefixCount, 2)
        checkEqual(try cursor(for: child, in: context.store).forkPrefixOpen, true)
        checkEqual(try amount(in: context.store, path: child.path).total(mode: .full), 0)

        try append(third, to: child)
        try CodexSource.refresh(store: context.store, sessionsDirectory: context.sessions)
        checkEqual(try cursor(for: child, in: context.store).matchedPrefixCount, 2)
        checkEqual(try cursor(for: child, in: context.store).forkPrefixOpen, false)
        checkEqual(try amount(in: context.store, path: child.path).total(mode: .lean), 60)
        checkEqual(try amount(in: context.store, path: child.path).total(mode: .full), 110)
    }

    mutating func testParentAppendDoesNotRebuildUnchangedChild() throws {
        let context = try tempStore()
        let first = try codexEvent(total: usage(input: 1_000, cache: 800, output: 100),
                                   last: usage(input: 1_000, cache: 800, output: 100))
        let second = try codexEvent(total: usage(input: 1_500, cache: 1_200, output: 150),
                                    last: usage(input: 500, cache: 400, output: 50))
        let parent = try writeSession(context.sessions, name: "parent.jsonl", id: "parent", events: first)
        let child = try writeSession(context.sessions, name: "child.jsonl", id: "child", parentID: "parent", events: first)
        try CodexSource.refresh(store: context.store, sessionsDirectory: context.sessions, backupURL: context.backup)

        try append(second, to: parent)
        CodexIndex.resetScanCounters()
        try CodexSource.refresh(store: context.store, sessionsDirectory: context.sessions)
        precondition(CodexIndex.scanInvocationPaths.contains(parent.path))
        precondition(!CodexIndex.scanInvocationPaths.contains(child.path), "parent append must not rescan unchanged child")
        precondition(!CodexIndex.fullScanInvocationPaths.contains(parent.path), "append must scan only the parent tail")
        precondition(CodexIndex.rawPrefixBytesRead > 0, "changed parent committed prefix must be verified as raw bytes")
        checkEqual(try amount(in: context.store, path: child.path).total(mode: .full), 0)
        checkEqual(try cursor(for: child, in: context.store).dependencies.first?.identity.signature,
                   try CodexIndex.identity(at: parent).signature)
    }

    mutating func testNewRecoveryCandidateAndChildAppendRecomputeSameCycle() throws {
        let context = try tempStore()
        let first = try codexEvent(total: usage(input: 1_000, cache: 800, output: 100),
                                   last: usage(input: 1_000, cache: 800, output: 100))
        let second = try codexEvent(total: usage(input: 1_200, cache: 900, output: 120),
                                    last: usage(input: 200, cache: 100, output: 20))
        let third = try codexEvent(total: usage(input: 1_300, cache: 950, output: 130),
                                   last: usage(input: 100, cache: 50, output: 10))
        _ = try writeSession(context.sessions, name: "parent-original.jsonl", id: "parent", events: first)
        let child = try writeSession(context.sessions, name: "child.jsonl", id: "child", parentID: "parent",
                                     events: first + second)
        try CodexSource.refresh(store: context.store, sessionsDirectory: context.sessions, backupURL: context.backup)
        checkEqual(try amount(in: context.store, path: child.path).total(mode: .full), 220)
        checkEqual(try cursor(for: child, in: context.store).matchedPrefixCount, 1)

        _ = try writeSession(context.sessions, name: "parent-recovery.jsonl", id: "parent", events: first + second)
        try append(third, to: child)
        try CodexSource.refresh(store: context.store, sessionsDirectory: context.sessions)

        checkEqual(try cursor(for: child, in: context.store).matchedPrefixCount, 2)
        checkEqual(try amount(in: context.store, path: child.path).total(mode: .full), 110)
    }

    mutating func testRefreshRejectsConflictingParentRelationshipsWithoutWriting() throws {
        let context = try tempStore()
        let event = try codexEvent(total: usage(input: 100, cache: 0, output: 10),
                                   last: usage(input: 100, cache: 0, output: 10))
        let existing = try writeSession(context.sessions, name: "shared-original.jsonl", id: "shared", events: event)
        try CodexSource.refresh(store: context.store, sessionsDirectory: context.sessions, backupURL: context.backup)
        let beforeRows = try context.store.keysForSourceThrowing(source: .codex)
        let beforeAmount = try amount(in: context.store, path: existing.path)
        let beforeVersion = try context.store.metaThrowing(StoreKeys.codexUsageVersion)
        let beforeDataVersion = context.store.dataVersion

        _ = try writeSession(context.sessions, name: "parent.jsonl", id: "parent", events: Data())
        _ = try writeSession(context.sessions, name: "shared-fork.jsonl", id: "shared", parentID: "parent", events: event)
        do {
            try CodexSource.refresh(store: context.store, sessionsDirectory: context.sessions)
            fatalError("different parent relationships for one session ID must be rejected")
        } catch { }

        checkEqual(try context.store.keysForSourceThrowing(source: .codex), beforeRows)
        checkEqual(try amount(in: context.store, path: existing.path), beforeAmount)
        checkEqual(try context.store.metaThrowing(StoreKeys.codexUsageVersion), beforeVersion)
        checkEqual(context.store.dataVersion, beforeDataVersion)
        precondition(context.store.meta(StoreKeys.codexUsageStatus)?.hasPrefix("incomplete:") == true)
    }

    mutating func testReconcileReselectsSurvivingRecoveryParent() throws {
        let context = try tempStore()
        let first = try codexEvent(total: usage(input: 1_000, cache: 800, output: 100),
                                   last: usage(input: 1_000, cache: 800, output: 100))
        let second = try codexEvent(total: usage(input: 1_200, cache: 900, output: 120),
                                    last: usage(input: 200, cache: 100, output: 20))
        let third = try codexEvent(total: usage(input: 1_300, cache: 950, output: 130),
                                   last: usage(input: 100, cache: 50, output: 10))
        let shortParent = try writeSession(context.sessions, name: "parent-short.jsonl", id: "parent", events: first)
        let longParent = try writeSession(context.sessions, name: "parent-long.jsonl", id: "parent", events: first + second)
        let child = try writeSession(context.sessions, name: "child.jsonl", id: "child", parentID: "parent",
                                     events: first + second + third)
        try CodexSource.refresh(store: context.store, sessionsDirectory: context.sessions, backupURL: context.backup)
        checkEqual(try cursor(for: child, in: context.store).matchedPrefixCount, 2)
        checkEqual(try amount(in: context.store, path: child.path).total(mode: .full), 110)
        let longParentCursorKey = StoreKeys.codexCursorState(longParent.path)

        try FileManager.default.removeItem(at: longParent)
        try CodexSource.reconcile(store: context.store, sessionsDirectory: context.sessions)

        checkEqual(try cursor(for: child, in: context.store).matchedPrefixCount, 1)
        checkEqual(try cursor(for: child, in: context.store).dependencies.map(\.path), [shortParent.path])
        checkEqual(try amount(in: context.store, path: child.path).total(mode: .full), 330)
        checkEqual(try amount(in: context.store, path: longParent.path).total(mode: .full), 0)
        checkEqual(try context.store.metaThrowing(longParentCursorKey), nil)
        checkEqual(try context.store.metaThrowing(StoreKeys.codexUsageStatus), "ready")
        let report = try CodexAudit.makeReport(databaseURL: context.database, sessionsDirectory: context.sessions)
        precondition(report.consistent, "reselected child and removed recovery rows should agree with readonly audit: \(report.blockers), \(report.differenceByDay)")
    }

    mutating func testCrossProcessRefreshesShareDatabaseLock() throws {
        let context = try tempStore()
        let first = try codexEvent(total: usage(input: 100, cache: 0, output: 10),
                                   last: usage(input: 100, cache: 0, output: 10))
        let second = try codexEvent(total: usage(input: 200, cache: 0, output: 20),
                                    last: usage(input: 100, cache: 0, output: 10))
        let file = try writeSession(context.sessions, name: "concurrent.jsonl", id: "concurrent", events: first)
        try CodexSource.refresh(store: context.store, sessionsDirectory: context.sessions, backupURL: context.backup)
        try append(second, to: file)

        let lockReady = context.root.appendingPathComponent("lock-ready")
        let releaseLock = context.root.appendingPathComponent("release-lock")
        let holder = try launchTestProcess([
            "--hold-codex-file-lock", context.database.path, lockReady.path, releaseLock.path
        ])
        defer {
            if holder.isRunning {
                try? Data("release".utf8).write(to: releaseLock)
                holder.waitUntilExit()
            }
        }
        try waitForFile(lockReady)

        let firstStarted = context.root.appendingPathComponent("refresh-one-started")
        let firstFinished = context.root.appendingPathComponent("refresh-one-finished")
        let secondStarted = context.root.appendingPathComponent("refresh-two-started")
        let secondFinished = context.root.appendingPathComponent("refresh-two-finished")
        let workerOne = try launchTestProcess([
            "--refresh-codex-once", context.database.path, context.sessions.path,
            firstStarted.path, firstFinished.path
        ])
        let workerTwo = try launchTestProcess([
            "--refresh-codex-once", context.database.path, context.sessions.path,
            secondStarted.path, secondFinished.path
        ])
        try waitForFile(firstStarted)
        try waitForFile(secondStarted)
        Thread.sleep(forTimeInterval: 0.25)
        precondition(!FileManager.default.fileExists(atPath: firstFinished.path)
                     && !FileManager.default.fileExists(atPath: secondFinished.path),
                     "refresh processes must wait for the database-scoped file lock")

        try Data("release".utf8).write(to: releaseLock)
        workerOne.waitUntilExit()
        workerTwo.waitUntilExit()
        holder.waitUntilExit()
        checkEqual(workerOne.terminationStatus, 0)
        checkEqual(workerTwo.terminationStatus, 0)
        checkEqual(holder.terminationStatus, 0)
        precondition(FileManager.default.fileExists(atPath: firstFinished.path)
                     && FileManager.default.fileExists(atPath: secondFinished.path))
        let lockURL = URL(fileURLWithPath: context.database.path + ".codex.lock")
        let lockAttributes = try FileManager.default.attributesOfItem(atPath: lockURL.path)
        checkEqual((lockAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        checkEqual(try amount(in: context.store, path: file.path).total(mode: .full), 220)
    }

    mutating func testNestedForksAndMultipleRecoveryParents() throws {
        let context = try tempStore()
        let first = try codexEvent(total: usage(input: 100, cache: 0, output: 0),
                                   last: usage(input: 100, cache: 0, output: 0))
        let second = try codexEvent(total: usage(input: 160, cache: 0, output: 0),
                                    last: usage(input: 60, cache: 0, output: 0))
        let third = try codexEvent(total: usage(input: 230, cache: 0, output: 0),
                                   last: usage(input: 70, cache: 0, output: 0))
        let fourth = try codexEvent(total: usage(input: 300, cache: 0, output: 0),
                                    last: usage(input: 70, cache: 0, output: 0))
        _ = try writeSession(context.sessions, name: "parent-short.jsonl", id: "parent", events: first)
        _ = try writeSession(context.sessions, name: "parent-long.jsonl", id: "parent", events: first + second)
        let child = try writeSession(context.sessions, name: "child.jsonl", id: "child", parentID: "parent", events: first + second + third)
        let grandchild = try writeSession(context.sessions, name: "grandchild.jsonl", id: "grandchild", parentID: "child", events: first + second + third + fourth)

        try CodexSource.refresh(store: context.store, sessionsDirectory: context.sessions, backupURL: context.backup)

        checkEqual(try cursor(for: child, in: context.store).dependencies.count, 2)
        checkEqual(try cursor(for: child, in: context.store).matchedPrefixCount, 2)
        checkEqual(try cursor(for: grandchild, in: context.store).matchedPrefixCount, 3)
        checkEqual(try amount(in: context.store, path: child.path).total(mode: .lean), 70)
        checkEqual(try amount(in: context.store, path: grandchild.path).total(mode: .lean), 70)
    }

    mutating func testV4IncompleteLineIsCommittedOnlyWhenCompleted() throws {
        let context = try tempStore()
        let eventData = try codexEvent(total: usage(input: 100, cache: 0, output: 10),
                                       last: usage(input: 100, cache: 0, output: 10))
        let file = try writeSession(context.sessions, name: "partial.jsonl", id: "partial", events: Data(eventData.dropLast()))
        try CodexSource.refresh(store: context.store, sessionsDirectory: context.sessions, backupURL: context.backup)
        let partialCursor = try cursor(for: file, in: context.store)
        checkEqual(partialCursor.tokenEventCount, 0)
        precondition(partialCursor.offset < partialCursor.identity.size)
        checkEqual(try amount(in: context.store, path: file.path).total(mode: .full), 0)

        try append(Data([10]), to: file)
        try CodexSource.refresh(store: context.store, sessionsDirectory: context.sessions)
        checkEqual(try cursor(for: file, in: context.store).tokenEventCount, 1)
        checkEqual(try amount(in: context.store, path: file.path).total(mode: .full), 110)
        try CodexSource.refresh(store: context.store, sessionsDirectory: context.sessions)
        checkEqual(try amount(in: context.store, path: file.path).total(mode: .full), 110)
    }

    mutating func testPrecommitPrefixRewriteAbortsWholeStage() throws {
        let context = try tempStore()
        let first = try codexEvent(total: usage(input: 100, cache: 0, output: 10),
                                   last: usage(input: 100, cache: 0, output: 10))
        let second = try codexEvent(total: usage(input: 200, cache: 0, output: 20),
                                    last: usage(input: 100, cache: 0, output: 10))
        let third = try codexEvent(total: usage(input: 300, cache: 0, output: 30),
                                   last: usage(input: 100, cache: 0, output: 10))
        let parent = try writeSession(context.sessions, name: "parent.jsonl", id: "parent", events: first)
        try CodexSource.refresh(store: context.store, sessionsDirectory: context.sessions, backupURL: context.backup)
        let oldParentCursor = try context.store.metaThrowing(StoreKeys.codexCursorState(parent.path))
        let oldParentAmount = try amount(in: context.store, path: parent.path)
        let child = try writeSession(context.sessions, name: "child.jsonl", id: "child", parentID: "parent", events: first)
        try append(second, to: parent)
        let replacement = try codexEvent(
            total: usage(input: 100, cache: 0, output: 10),
            last: usage(input: 100, cache: 0, output: 10),
            timestamp: "2026-10-08T06:00:00Z"
        )

        CodexV4Engine.beforeCommitHookForTesting = {
            let bytes = try Data(contentsOf: parent)
            guard let range = bytes.range(of: first) else { fatalError("parent event not found") }
            let handle = try FileHandle(forWritingTo: parent)
            try handle.seek(toOffset: UInt64(range.lowerBound))
            try handle.write(contentsOf: replacement)
            try handle.seekToEnd()
            try handle.write(contentsOf: third)
            try handle.close()
        }
        defer { CodexV4Engine.beforeCommitHookForTesting = nil }
        do {
            try CodexSource.refresh(store: context.store, sessionsDirectory: context.sessions)
            fatalError("pre-commit content change must reject the staged refresh")
        } catch { }

        checkEqual(try context.store.metaThrowing(StoreKeys.codexCursorState(parent.path)), oldParentCursor)
        checkEqual(try amount(in: context.store, path: parent.path), oldParentAmount)
        checkEqual(try context.store.metaThrowing(StoreKeys.codexCursorState(child.path)), nil)
        checkEqual(try context.store.metaThrowing(StoreKeys.codexUsageVersion), "4")
        precondition(context.store.meta(StoreKeys.codexUsageStatus)?.hasPrefix("incomplete:") == true)
    }

    mutating func testDivergedForkDoesNotDependOnParentEOF() throws {
        let context = try tempStore()
        let parentEvent = try codexEvent(total: usage(input: 100, cache: 0, output: 10),
                                         last: usage(input: 100, cache: 0, output: 10))
        let childFirst = try codexEvent(total: usage(input: 200, cache: 0, output: 20),
                                        last: usage(input: 200, cache: 0, output: 20))
        let childSecond = try codexEvent(total: usage(input: 300, cache: 0, output: 30),
                                         last: usage(input: 100, cache: 0, output: 10))
        let appendedParentEvent = try codexEvent(total: usage(input: 250, cache: 0, output: 25),
                                                 last: usage(input: 150, cache: 0, output: 15))
        let parent = try writeSession(context.sessions, name: "parent.jsonl", id: "parent", events: parentEvent)
        try CodexSource.refresh(store: context.store, sessionsDirectory: context.sessions, backupURL: context.backup)
        let child = try writeSession(context.sessions, name: "child.jsonl", id: "child", parentID: "parent",
                                     events: childFirst + childSecond)

        CodexV4Engine.beforeCommitHookForTesting = {
            let handle = try FileHandle(forWritingTo: parent)
            try handle.seekToEnd()
            try handle.write(contentsOf: appendedParentEvent)
            try handle.close()
        }
        defer { CodexV4Engine.beforeCommitHookForTesting = nil }
        try CodexSource.refresh(store: context.store, sessionsDirectory: context.sessions)

        checkEqual(try cursor(for: child, in: context.store).matchedPrefixCount, 0)
        checkEqual(try amount(in: context.store, path: child.path).total(mode: .full), 330)
        checkEqual(try context.store.metaThrowing(StoreKeys.codexUsageStatus), "ready")
    }

    mutating func testEOFDependentForkAppendAbortsWholeStage() throws {
        let context = try tempStore()
        let first = try codexEvent(total: usage(input: 100, cache: 0, output: 10),
                                   last: usage(input: 100, cache: 0, output: 10))
        let second = try codexEvent(total: usage(input: 200, cache: 0, output: 20),
                                    last: usage(input: 100, cache: 0, output: 10))
        let appendedParentEvent = try codexEvent(total: usage(input: 250, cache: 0, output: 25),
                                                 last: usage(input: 50, cache: 0, output: 5))
        let parent = try writeSession(context.sessions, name: "parent.jsonl", id: "parent", events: first)
        _ = try writeSession(context.sessions, name: "child.jsonl", id: "child", parentID: "parent",
                             events: first + second)

        CodexV4Engine.beforeCommitHookForTesting = {
            let handle = try FileHandle(forWritingTo: parent)
            try handle.seekToEnd()
            try handle.write(contentsOf: appendedParentEvent)
            try handle.close()
        }
        defer { CodexV4Engine.beforeCommitHookForTesting = nil }
        do {
            try CodexSource.refresh(store: context.store, sessionsDirectory: context.sessions, backupURL: context.backup)
            fatalError("an append beyond a matched parent EOF must reject the staged migration")
        } catch { }

        checkEqual(try context.store.metaThrowing(StoreKeys.codexUsageVersion), nil)
        checkEqual(try context.store.keysForSourceThrowing(source: .codex), [])
        precondition(context.store.meta(StoreKeys.codexUsageStatus)?.hasPrefix("incomplete:") == true)
    }

    mutating func testAuditIsReadonlyAndMatchesCommittedContributions() throws {
        let context = try tempStore()
        let first = try codexEvent(total: usage(input: 1_000, cache: 800, output: 100),
                                   last: usage(input: 1_000, cache: 800, output: 100))
        let second = try codexEvent(total: usage(input: 1_500, cache: 1_200, output: 150),
                                    last: usage(input: 500, cache: 400, output: 50))
        _ = try writeSession(context.sessions, name: "parent.jsonl", id: "parent", events: first + second)
        _ = try writeSession(context.sessions, name: "child.jsonl", id: "child", parentID: "parent", events: first + second)
        try CodexSource.refresh(store: context.store, sessionsDirectory: context.sessions, backupURL: context.backup)
        let version = context.store.dataVersion
        let beforeRows = try context.store.keysForSourceThrowing(source: .codex)
        let beforeStatus = try context.store.metaThrowing(StoreKeys.codexUsageStatus)

        let report = try CodexAudit.makeReport(databaseURL: context.database, sessionsDirectory: context.sessions)

        precondition(report.consistent, "audit should independently agree with committed rows: \(report.blockers), \(report.differenceByDay)")
        checkEqual(report.forks.count, 1)
        checkEqual(report.forks.first?.matchedPrefixEvents, 2)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try JSONSerialization.jsonObject(with: encoder.encode(report)) as! [String: Any]
        let dayBuckets = json["expectedByDay"] as! [String: [String: Any]]
        let day = dayBuckets["2026-10-08"]!
        checkEqual((day["lean"] as? NSNumber)?.int64Value, 450)
        checkEqual((day["full"] as? NSNumber)?.int64Value, 1_650)
        let forkJSON = (json["forks"] as! [[String: Any]]).first!
        let addedUsage = forkJSON["addedUsage"] as! [String: Any]
        precondition(addedUsage.keys.contains("lean") && addedUsage.keys.contains("full"),
                     "fork addedUsage JSON must include lean and full totals")
        checkEqual(context.store.dataVersion, version)
        checkEqual(try context.store.keysForSourceThrowing(source: .codex), beforeRows)
        checkEqual(try context.store.metaThrowing(StoreKeys.codexUsageStatus), beforeStatus)

        if let key = beforeRows.first {
            try context.store.upsert(source: .codex, key: key, day: "2026-10-08", amount: UsageAmount(input: 1))
            let mismatch = try CodexAudit.makeReport(databaseURL: context.database, sessionsDirectory: context.sessions)
            precondition(!mismatch.consistent)
            checkEqual(mismatch.differenceByDay["2026-10-08"]?.input == nil, false)
        }
    }

    mutating func testAuditRejectsInvalidBucketsIncludingCopiedPrefix() throws {
        let context = try tempStore()
        let cachedAboveInput = try codexEvent(total: usage(input: 10, cache: 11, output: 1),
                                              last: usage(input: 10, cache: 11, output: 1))
        let negativeOutput = try codexEvent(total: usage(input: 20, cache: 0, output: -1),
                                            last: usage(input: 10, cache: 0, output: -2))
        let parent = try writeSession(context.sessions, name: "invalid-parent.jsonl", id: "parent",
                                      events: cachedAboveInput + negativeOutput)
        let child = try writeSession(context.sessions, name: "invalid-child.jsonl", id: "child", parentID: "parent",
                                     events: cachedAboveInput + negativeOutput)
        try seedAuditState([parent, child], store: context.store)
        let lockURL = URL(fileURLWithPath: context.database.path + ".codex.lock")
        precondition(!FileManager.default.fileExists(atPath: lockURL.path), "readonly audit fixtures start without a source lockfile")

        let report = try CodexAudit.makeReport(databaseURL: context.database, sessionsDirectory: context.sessions)
        precondition(!FileManager.default.fileExists(atPath: lockURL.path), "readonly audit must not create a source lockfile")
        precondition(report.forks.first?.matchedPrefixEvents == 2)
        precondition(report.blockers.contains { $0.contains("cache bucket") && $0.contains(parent.path) && $0.contains("byte") },
                     "invalid parent buckets should identify their source byte offset")
        precondition(report.blockers.contains { $0.contains("negative token bucket") && $0.contains(parent.path) && $0.contains("byte") },
                     "negative parent buckets should identify their source byte offset")
        precondition(report.blockers.contains { $0.contains(child.path) && $0.contains("byte") },
                     "copied-prefix snapshots should be validated even when their usage is skipped")
        checkEqual(CodexAudit.run(databaseURL: context.database, sessionsDirectory: context.sessions,
                                  reportURL: context.root.appendingPathComponent("invalid-report.json")), 2)
    }

    mutating func testAuditRejectsForkCyclesAndConflictingRelationships() throws {
        let context = try tempStore()
        let event = try codexEvent(total: nil, last: nil)
        let a = try writeSession(context.sessions, name: "cycle-a.jsonl", id: "cycle-a", parentID: "cycle-b", events: event)
        let b = try writeSession(context.sessions, name: "cycle-b.jsonl", id: "cycle-b", parentID: "cycle-a", events: event)
        let sharedA = try writeSession(context.sessions, name: "shared-a.jsonl", id: "shared", parentID: "root-a", events: event)
        let sharedB = try writeSession(context.sessions, name: "shared-b.jsonl", id: "shared", parentID: "root-b", events: event)
        let rootA = try writeSession(context.sessions, name: "root-a.jsonl", id: "root-a", events: event)
        let rootB = try writeSession(context.sessions, name: "root-b.jsonl", id: "root-b", events: event)
        try seedAuditState([a, b, sharedA, sharedB, rootA, rootB], store: context.store)

        let report = try CodexAudit.makeReport(databaseURL: context.database, sessionsDirectory: context.sessions)
        precondition(report.blockers.contains { $0.contains("fork cycle") && $0.contains("cycle-a") && $0.contains("cycle-b") },
                     "audit must report fork cycles")
        precondition(report.blockers.contains { $0.contains("conflicting parent relationships") && $0.contains("shared") },
                     "audit must report differing parent links for recovery files with the same session ID")
        checkEqual(CodexAudit.run(databaseURL: context.database, sessionsDirectory: context.sessions,
                                  reportURL: context.root.appendingPathComponent("cycle-report.json")), 2)
    }

    mutating func testAuditFailureWritesReportFile() throws {
        let context = try tempStore()
        let reportURL = context.root.appendingPathComponent("audit-error.json")
        let missingDirectory = context.root.appendingPathComponent("missing-sessions", isDirectory: true)

        checkEqual(CodexAudit.run(databaseURL: context.database, sessionsDirectory: missingDirectory,
                                  reportURL: reportURL), 2)

        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: reportURL)) as! [String: Any]
        precondition(object["error"] as? String != nil, "audit setup failures should be saved to the requested report file")
    }

    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
    }

    mutating func testMissingParentLeavesCommittedRowsAndCursorsUntouched() throws {
        let context = try tempStore()
        let eventData = try codexEvent(total: usage(input: 100, cache: 0, output: 10),
                                       last: usage(input: 100, cache: 0, output: 10))
        let parent = try writeSession(context.sessions, name: "parent.jsonl", id: "parent", events: eventData)
        let child = try writeSession(context.sessions, name: "child.jsonl", id: "child", parentID: "parent", events: eventData)
        try CodexSource.refresh(store: context.store, sessionsDirectory: context.sessions, backupURL: context.backup)
        let beforeChild = try amount(in: context.store, path: child.path)
        let beforeCursor = try context.store.metaThrowing(StoreKeys.codexCursorState(child.path))
        try FileManager.default.removeItem(at: parent)
        do {
            try CodexSource.refresh(store: context.store, sessionsDirectory: context.sessions)
            fatalError("missing parent should stop the refresh")
        } catch { }
        do {
            try CodexSource.reconcile(store: context.store, sessionsDirectory: context.sessions)
            fatalError("reconcile must not delete a child while every parent candidate is missing")
        } catch { }
        checkEqual(try amount(in: context.store, path: child.path), beforeChild)
        checkEqual(try context.store.metaThrowing(StoreKeys.codexCursorState(child.path)), beforeCursor)
        checkEqual(try context.store.metaThrowing(StoreKeys.codexUsageVersion), "4")
        precondition(context.store.meta(StoreKeys.codexUsageStatus)?.hasPrefix("incomplete:") == true)
    }

    mutating func testReconcileAllowsDeletingChildAndParentTogether() throws {
        let context = try tempStore()
        let eventData = try codexEvent(total: usage(input: 100, cache: 0, output: 10),
                                       last: usage(input: 100, cache: 0, output: 10))
        let parent = try writeSession(context.sessions, name: "parent.jsonl", id: "parent", events: eventData)
        let child = try writeSession(context.sessions, name: "child.jsonl", id: "child", parentID: "parent", events: eventData)
        try CodexSource.refresh(store: context.store, sessionsDirectory: context.sessions, backupURL: context.backup)
        let parentCursorKey = StoreKeys.codexCursorState(parent.path)
        let childCursorKey = StoreKeys.codexCursorState(child.path)
        try FileManager.default.removeItem(at: parent)
        try FileManager.default.removeItem(at: child)

        try CodexSource.reconcile(store: context.store, sessionsDirectory: context.sessions)

        checkEqual(try context.store.amountsForSourceThrowing(source: .codex, keyPrefix: "").count, 0)
        checkEqual(try context.store.metaThrowing(parentCursorKey), nil)
        checkEqual(try context.store.metaThrowing(childCursorKey), nil)
        checkEqual(try context.store.metaThrowing(StoreKeys.codexUsageStatus), "ready")
    }

    mutating func testReconcileDeletesExactMetadataKeysWithPipePaths() throws {
        let context = try tempStore()
        let retained = try writeSession(context.sessions, name: "foo.jsonl-other.jsonl", id: "retained", events: Data())
        let removedPath = context.sessions.appendingPathComponent("foo.jsonl").path
        try context.store.upsert(source: .codex, key: removedPath + "|2026-10-08", day: "2026-10-08",
                                 amount: UsageAmount(input: 10))
        try context.store.upsert(source: .codex, key: retained.path + "|2026-10-08", day: "2026-10-08",
                                 amount: UsageAmount(input: 20))
        try context.store.setMeta(StoreKeys.codexSig(removedPath), "gone")
        try context.store.setMeta(StoreKeys.codexSig(retained.path), "keep")

        try CodexSource.reconcile(store: context.store, sessionsDirectory: context.sessions)

        checkEqual(try amount(in: context.store, path: removedPath).input, 0)
        checkEqual(try amount(in: context.store, path: retained.path).input, 20)
        checkEqual(try context.store.metaThrowing(StoreKeys.codexSig(removedPath)), nil)
        checkEqual(try context.store.metaThrowing(StoreKeys.codexSig(retained.path)), "keep")
    }

    mutating func testMigrationCommitFailurePreservesOldCodexRows() throws {
        let context = try tempStore()
        let file = try writeSession(
            context.sessions, name: "one.jsonl", id: "one",
            events: codexEvent(total: usage(input: 100, cache: 0, output: 10),
                               last: usage(input: 100, cache: 0, output: 10))
        )
        try context.store.upsert(source: .codex, key: "old|2026-10-01", day: "2026-10-01",
                                 amount: UsageAmount(input: 77))
        try context.store.setMeta(StoreKeys.codexUsageVersion, "3")
        let db = try SQLiteDatabase(path: context.database.path)
        try db.execute("CREATE TRIGGER fail_codex_insert BEFORE INSERT ON contrib WHEN NEW.source='codex' BEGIN SELECT RAISE(ABORT,'injected failure'); END")

        do {
            try CodexSource.refresh(store: context.store, sessionsDirectory: context.sessions, backupURL: context.backup)
            fatalError("trigger should reject the source transaction")
        } catch { }
        checkEqual(try context.store.metaThrowing(StoreKeys.codexUsageVersion), "3")
        checkEqual(try amount(in: context.store, path: "old").input, 77)
        checkEqual(try amount(in: context.store, path: file.path).input, 0)
    }

    mutating func testBackupFailurePreservesOldVersionAndRows() throws {
        let context = try tempStore()
        let file = try writeSession(
            context.sessions, name: "one.jsonl", id: "one",
            events: codexEvent(total: usage(input: 100, cache: 0, output: 10),
                               last: usage(input: 100, cache: 0, output: 10))
        )
        try context.store.upsert(source: .codex, key: "old|2026-10-01", day: "2026-10-01",
                                 amount: UsageAmount(input: 77))
        try context.store.setMeta(StoreKeys.codexUsageVersion, "3")
        try FileManager.default.createDirectory(at: context.backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("reserved".utf8).write(to: context.backup)

        do {
            try CodexSource.refresh(store: context.store, sessionsDirectory: context.sessions, backupURL: context.backup)
            fatalError("an existing backup destination must stop migration")
        } catch { }
        checkEqual(try context.store.metaThrowing(StoreKeys.codexUsageVersion), "3")
        checkEqual(try amount(in: context.store, path: "old").input, 77)
        checkEqual(try amount(in: context.store, path: file.path).input, 0)
        checkEqual(try Data(contentsOf: context.backup), Data("reserved".utf8))
    }

    mutating func testQuotaNewerObservationWinsResetRegression() throws {
        let oldObserved = 1_791_535_853.332
        let stored: [String: Any] = [
            "observed_ts": oldObserved,
            "short": quotaWindow(used: 94, minutes: 300, reset: 1_791_546_881, observed: oldObserved),
            "long": quotaWindow(used: 33, minutes: 10_080, reset: 1_792_030_118, observed: oldObserved)
        ]
        let incoming: [String: Any] = [
            "limit_id": "codex",
            "secondary": quotaWindow(used: 61, minutes: 10_080, reset: 1_792_029_929)
        ]

        let merged = CodexQuota.mergeRateSnapshot(stored: stored, with: incoming, observedTs: oldObserved + 189)
        let short = merged["short"] as! [String: Any]
        let long = merged["long"] as! [String: Any]
        checkEqual((short["used_percent"] as? NSNumber)?.doubleValue, 94)
        checkEqual((short["observed_ts"] as? NSNumber)?.doubleValue, oldObserved)
        checkEqual((long["used_percent"] as? NSNumber)?.doubleValue, 61)
        checkEqual((long["resets_at"] as? NSNumber)?.doubleValue, 1_792_029_929)
        checkEqual((long["observed_ts"] as? NSNumber)?.doubleValue, oldObserved + 189)
    }

    mutating func testQuotaEqualObservationRepairsStoredWindow() throws {
        let observed = 1_791_535_853.332
        let stored: [String: Any] = [
            "observed_ts": observed,
            "long": quotaWindow(used: 33, minutes: 10_080, reset: 1_792_030_118)
        ]
        let incoming: [String: Any] = [
            "limit_id": "codex",
            "secondary": quotaWindow(used: 61, minutes: 10_080, reset: 1_792_029_929)
        ]

        let merged = CodexQuota.mergeRateSnapshot(stored: stored, with: incoming, observedTs: observed)
        let long = merged["long"] as! [String: Any]
        checkEqual((long["used_percent"] as? NSNumber)?.doubleValue, 61)
        checkEqual((long["observed_ts"] as? NSNumber)?.doubleValue, observed)
    }

    mutating func testQuotaDelayedOlderObservationIsIgnored() throws {
        let stored: [String: Any] = [
            "observed_ts": 2_000,
            "long": quotaWindow(used: 61, minutes: 10_080, reset: 3_000, observed: 2_000)
        ]
        let incoming: [String: Any] = [
            "limit_id": "codex",
            "secondary": quotaWindow(used: 33, minutes: 10_080, reset: 9_000)
        ]

        let merged = CodexQuota.mergeRateSnapshot(stored: stored, with: incoming, observedTs: 1_999)
        let long = merged["long"] as! [String: Any]
        checkEqual((long["used_percent"] as? NSNumber)?.doubleValue, 61)
        checkEqual((long["resets_at"] as? NSNumber)?.doubleValue, 3_000)
        checkEqual((long["observed_ts"] as? NSNumber)?.doubleValue, 2_000)
    }

    mutating func testQuotaMissingWindowKeepsItsOwnObservationTime() throws {
        let stored: [String: Any] = [
            "observed_ts": 2_000,
            "short": quotaWindow(used: 94, minutes: 300, reset: 4_000, observed: 2_000),
            "long": quotaWindow(used: 33, minutes: 10_080, reset: 9_000, observed: 1_000)
        ]
        let incoming: [String: Any] = [
            "limit_id": "codex",
            "primary": quotaWindow(used: 95, minutes: 300, reset: 4_100)
        ]

        let merged = CodexQuota.mergeRateSnapshot(stored: stored, with: incoming, observedTs: 3_000)
        let short = merged["short"] as! [String: Any]
        let long = merged["long"] as! [String: Any]
        checkEqual((merged["observed_ts"] as? NSNumber)?.doubleValue, 3_000)
        checkEqual((short["used_percent"] as? NSNumber)?.doubleValue, 95)
        checkEqual((short["observed_ts"] as? NSNumber)?.doubleValue, 3_000)
        checkEqual((long["used_percent"] as? NSNumber)?.doubleValue, 33)
        checkEqual((long["observed_ts"] as? NSNumber)?.doubleValue, 1_000)
    }

    mutating func testQuotaClassificationIgnoresRawPosition() throws {
        let raw: [String: Any] = [
            "limit_id": "codex", "observed_ts": 1_000,
            "primary": quotaWindow(used: 61, minutes: 10_080, reset: 5_000),
            "secondary": quotaWindow(used: 94, minutes: 300, reset: 2_000)
        ]
        let merged = CodexQuota.mergeRateSnapshot(stored: [:], with: raw, observedTs: 1_000)
        let short = merged["short"] as! [String: Any]
        let long = merged["long"] as! [String: Any]
        checkEqual((short["used_percent"] as? NSNumber)?.doubleValue, 94)
        checkEqual((long["used_percent"] as? NSNumber)?.doubleValue, 61)
        checkEqual((short["observed_ts"] as? NSNumber)?.doubleValue, 1_000)
        checkEqual((long["observed_ts"] as? NSNumber)?.doubleValue, 1_000)
        let decoded = CodexQuota.decode(fromJSON: try rateMapJSON(["codex": merged]))
        checkEqual(decoded?.primary?.usedPercent, 94)
        checkEqual(decoded?.secondary?.usedPercent, 61)
    }

    mutating func testLegacyQuotaPrimePreservesUsageRowsAndCursor() throws {
        let context = try tempStore()
        let timestamp = "2026-10-09T00:00:00.332Z"
        let observed = Formatters.isoFractional.date(from: timestamp)!.timeIntervalSince1970
        let limits: [String: Any] = [
            "limit_id": "codex",
            "primary": quotaWindow(used: 94, minutes: 300, reset: 1_791_546_881),
            "secondary": quotaWindow(used: 61, minutes: 10_080, reset: 1_792_029_929)
        ]
        let file = try writeSession(
            context.sessions, name: "legacy-quota.jsonl", id: "legacy-quota",
            events: try quotaEvent(timestamp: timestamp, rateLimits: limits)
        )
        try seedAuditState([file], store: context.store)
        let legacy: [String: Any] = [
            "codex": [
                "limit_id": "codex", "observed_ts": observed,
                "short": quotaWindow(used: 94, minutes: 300, reset: 1_791_546_881),
                "long": quotaWindow(used: 33, minutes: 10_080, reset: 1_792_030_118)
            ]
        ]
        try context.store.setMeta(StoreKeys.codexRateLimits, try rateMapJSON(legacy))
        try context.store.upsert(source: .codex, key: file.path + "|2026-10-09", day: "2026-10-09",
                                 amount: UsageAmount(input: 7))
        let beforeRows = try context.store.keysForSourceThrowing(source: .codex)
        let beforeAmount = try amount(in: context.store, path: file.path)
        let cursorKey = StoreKeys.codexCursorState(file.path)
        let beforeCursor = try context.store.metaThrowing(cursorKey)
        CodexSource.resetRatePrimeThrottleForTesting()

        try CodexSource.refresh(store: context.store, sessionsDirectory: context.sessions)

        let cache = try rateMap(from: context.store)
        let codex = cache["codex"] as! [String: Any]
        let long = codex["long"] as! [String: Any]
        checkEqual((long["used_percent"] as? NSNumber)?.doubleValue, 61)
        checkEqual((long["observed_ts"] as? NSNumber)?.doubleValue, observed)
        checkEqual(try context.store.keysForSourceThrowing(source: .codex), beforeRows)
        checkEqual(try amount(in: context.store, path: file.path), beforeAmount)
        checkEqual(try context.store.metaThrowing(cursorKey), beforeCursor)
    }

    mutating func testLegacyPrimeFlagSurvivesShortOnlyMerge() throws {
        let context = try tempStore()
        let baselineTimestamp = "2026-10-09T00:00:00.000Z"
        let shortTimestamp = "2026-10-09T00:00:10.000Z"
        let fullTimestamp = "2026-10-09T00:00:20.000Z"
        let baselineObserved = Formatters.isoFractional.date(from: baselineTimestamp)!.timeIntervalSince1970
        let fullObserved = Formatters.isoFractional.date(from: fullTimestamp)!.timeIntervalSince1970
        let oldFullSnapshot: [String: Any] = [
            "limit_id": "codex",
            "primary": quotaWindow(used: 94, minutes: 300, reset: 1_791_546_881),
            "secondary": quotaWindow(used: 33, minutes: 10_080, reset: 1_792_030_118)
        ]
        let existingFile = try writeSession(
            context.sessions, name: "incremental.jsonl", id: "incremental",
            events: try quotaEvent(timestamp: baselineTimestamp, rateLimits: oldFullSnapshot)
        )
        let latestSnapshot: [String: Any] = [
            "limit_id": "codex",
            "primary": quotaWindow(used: 95, minutes: 300, reset: 1_791_546_981),
            "secondary": quotaWindow(used: 61, minutes: 10_080, reset: 1_792_030_029)
        ]
        let latestFile = try writeSession(
            context.sessions, name: "latest.jsonl", id: "latest",
            events: try quotaEvent(timestamp: fullTimestamp, rateLimits: latestSnapshot)
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(7_200)], ofItemAtPath: latestFile.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-7_200)], ofItemAtPath: existingFile.path
        )
        try seedAuditState([existingFile, latestFile], store: context.store)
        let legacy: [String: Any] = [
            "codex": [
                "limit_id": "codex", "observed_ts": baselineObserved,
                "short": quotaWindow(used: 94, minutes: 300, reset: 1_791_546_881),
                "long": quotaWindow(used: 33, minutes: 10_080, reset: 1_792_030_118)
            ]
        ]
        try context.store.setMeta(StoreKeys.codexRateLimits, try rateMapJSON(legacy))
        let shortOnly: [String: Any] = [
            "limit_id": "codex",
            "primary": quotaWindow(used: 96, minutes: 300, reset: 1_791_546_991)
        ]
        try append(try quotaEvent(timestamp: shortTimestamp, rateLimits: shortOnly), to: existingFile)
        try context.store.upsert(source: .codex, key: existingFile.path + "|2026-10-09", day: "2026-10-09",
                                 amount: UsageAmount(input: 7))
        let rowsBefore = try context.store.keysForSourceThrowing(source: .codex)
        let amountBefore = try amount(in: context.store, path: existingFile.path)
        CodexSource.resetRatePrimeThrottleForTesting()

        try CodexSource.refresh(store: context.store, sessionsDirectory: context.sessions)

        let cache = try rateMap(from: context.store)
        let long = (cache["codex"] as! [String: Any])["long"] as! [String: Any]
        checkEqual((long["used_percent"] as? NSNumber)?.doubleValue, 61)
        checkEqual((long["observed_ts"] as? NSNumber)?.doubleValue, fullObserved)
        checkEqual(try context.store.keysForSourceThrowing(source: .codex), rowsBefore)
        checkEqual(try amount(in: context.store, path: existingFile.path), amountBefore)
    }

    mutating func testChineseTokenUnits() {
        checkEqual(Fmt.tokens(9999), "9999")
        checkEqual(Fmt.tokens(10_000), "1.00万")
        checkEqual(Fmt.tokens(4_000_000), "400万")
        checkEqual(Fmt.tokens(100_000_000), "1.00亿")
        checkEqual(Fmt.tokens(400_000_000), "4.00亿")
    }

    private struct StoreContext {
        let root: URL
        let sessions: URL
        let database: URL
        let backup: URL
        let store: UsageStore
    }

    private mutating func tempStore() throws -> StoreContext {
        let root = try tempDirectory()
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("db/store.db")
        return StoreContext(root: root, sessions: sessions, database: database,
                            backup: root.appendingPathComponent("db/backup.db"),
                            store: UsageStore(databaseURL: database))
    }

    private mutating func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CodexV4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        fixtures.append(url)
        return url.resolvingSymlinksInPath()
    }

    private func usage(input: Int64, cache: Int64, output: Int64) -> [String: Any] {
        ["input_tokens": input, "cached_input_tokens": cache, "output_tokens": output]
    }

    private func codexEvent(
        total: [String: Any], last: [String: Any], timestamp: String = "2026-10-08T05:00:00Z"
    ) throws -> Data {
        try codexEvent(total: Optional(total), last: Optional(last), timestamp: timestamp)
    }

    private func codexEvent(
        total: [String: Any]?, last: [String: Any]?, timestamp: String = "2026-10-08T05:00:00Z"
    ) throws -> Data {
        var info: [String: Any] = [:]
        if let total { info["total_token_usage"] = total }
        if let last { info["last_token_usage"] = last }
        let object: [String: Any] = [
            "timestamp": timestamp,
            "payload": ["type": "token_count", "info": info]
        ]
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        return data
    }

    private func quotaWindow(used: Double, minutes: Int, reset: Double, observed: Double? = nil) -> [String: Any] {
        var window: [String: Any] = [
            "used_percent": used, "window_minutes": minutes, "resets_at": reset
        ]
        if let observed { window["observed_ts"] = observed }
        return window
    }

    private func quotaEvent(timestamp: String, rateLimits: [String: Any]) throws -> Data {
        let object: [String: Any] = [
            "timestamp": timestamp,
            "payload": ["type": "token_count", "info": [:], "rate_limits": rateLimits]
        ]
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        return data
    }

    private func rateMapJSON(_ map: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: map)
        guard let raw = String(data: data, encoding: .utf8) else { throw SQLiteError(message: "invalid quota JSON") }
        return raw
    }

    private func rateMap(from store: UsageStore) throws -> [String: Any] {
        guard let raw = try store.metaThrowing(StoreKeys.codexRateLimits),
              let data = raw.data(using: .utf8),
              let map = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SQLiteError(message: "missing or invalid Codex quota cache")
        }
        return map
    }

    private func sessionMeta(id: String, parentID: String? = nil) throws -> Data {
        var payload: [String: Any] = ["id": id]
        if let parentID { payload["forked_from_id"] = parentID }
        var data = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": payload])
        data.append(10)
        return data
    }

    private func writeSession(
        _ directory: URL, name: String, id: String, parentID: String? = nil, events: Data,
        trailingMetadata: [Data] = []
    ) throws -> URL {
        var data = try sessionMeta(id: id, parentID: parentID)
        for metadata in trailingMetadata { data.append(metadata) }
        data.append(events)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)!
        while let entry = enumerator.nextObject() as? URL {
            if entry.lastPathComponent == name { return entry }
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private func amount(in store: UsageStore, path: String) throws -> UsageAmount {
        try store.amountsForSourceThrowing(source: .codex, keyPrefix: path + "|").values.reduce(.zero, +)
    }

    private func cursor(for file: URL, in store: UsageStore) throws -> CodexFileCursor {
        guard let raw = try store.metaThrowing(StoreKeys.codexCursorState(file.path)),
              let data = raw.data(using: .utf8) else { fatalError("missing Codex cursor") }
        return try JSONDecoder().decode(CodexFileCursor.self, from: data)
    }

    private func launchTestProcess(_ arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    private func waitForFile(_ file: URL, timeout: TimeInterval = 5) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: file.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw SQLiteError(message: "timed out waiting for fixture file \(file.path)")
        }
    }

    private func seedAuditState(_ files: [URL], store: UsageStore) throws {
        try store.setMeta(StoreKeys.codexUsageVersion, "4")
        try store.setMeta(StoreKeys.codexUsageStatus, "ready")
        for file in files {
            let scan = try CodexIndex.scan(file)
            let fallback = Fmt.day(Date(timeIntervalSince1970: Double(scan.identity.modifiedMilliseconds) / 1000))
            let cursor = CodexFileCursor(
                identity: scan.identity, offset: scan.offset, tokenEventCount: scan.events.count,
                fallbackSegments: scan.offset > 0
                    ? [CodexFallbackSegment(startByte: 0, endByte: scan.offset, day: fallback)] : [],
                rawBaseline: scan.events.reversed().compactMap(\.total).first,
                committedRawSHA256: scan.committedRawSHA256,
                sessionID: scan.sessionID, forkedFromID: scan.forkedFromID,
                dependencies: [], matchedPrefixCount: 0, forkPrefixOpen: false,
                childPrefixEndByte: 0, prefixSHA256: try CodexIndex.prefixSHA256(scan.events, count: 0)
            )
            let data = try JSONEncoder().encode(cursor)
            try store.setMeta(StoreKeys.codexCursorState(file.path), String(data: data, encoding: .utf8)!)
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private func checkEqual<T: Equatable>(_ actual: T, _ expected: T, line: UInt = #line) {
    precondition(actual == expected, "Line \(line): expected \(expected), got \(actual)")
}
