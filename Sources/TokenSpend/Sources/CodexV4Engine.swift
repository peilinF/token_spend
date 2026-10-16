import Foundation
import CryptoKit

enum CodexV4Engine {
    private static let version = "4"
    private static let statePrefix = "codex_cursor:"
    private static let legacyPrefixes = ["codex_cursor:", "codex_sig:", "codex_off:", "codex_baseline:"]
    static var beforeCommitHookForTesting: (() throws -> Void)?

    private struct RefreshStage {
        var replacePrefixes: [String] = []
        var replacementEntries: [ContribEntry] = []
        var additiveEntries: [ContribEntry] = []
        var metadata: [String: String] = [:]
        var latestRate: (json: [String: Any], ts: Double)?
        var validateBeforeCommit: (() throws -> Void)?
    }

    static func refresh(
        store: UsageStore,
        sessionsDirectory suppliedDirectory: URL? = nil,
        backupURL suppliedBackupURL: URL? = nil
    ) throws -> (json: [String: Any], ts: Double)? {
        let directory = suppliedDirectory ?? defaultSessionsDirectory
        do {
            let files = try enumerateFiles(directory)
            let storedVersion = try store.metaThrowing(StoreKeys.codexUsageVersion)
            if storedVersion != version {
                let backup = suppliedBackupURL ?? defaultBackupURL(for: store)
                try store.backup(to: backup)
                try store.setMeta(StoreKeys.codexUsageStatus, "rebuilding")
                do {
                    let stage = try fullRebuild(files: files, directory: directory)
                    var metadata = stage.metadata
                    metadata[StoreKeys.codexUsageVersion] = version
                    metadata[StoreKeys.codexUsageStatus] = "ready"
                    try beforeCommitHookForTesting?()
                    try stage.validateBeforeCommit?()
                    try store.replaceSource(
                        source: .codex,
                        entries: stage.replacementEntries,
                        metadataPrefixesToDelete: legacyPrefixes,
                        meta: metadata
                    )
                    return stage.latestRate
                } catch {
                    try? store.setMeta(StoreKeys.codexUsageStatus, "incomplete: \(error)")
                    throw error
                }
            }

            let stage = try incrementalRefresh(files: files, store: store, directory: directory)
            var metadata = stage.metadata
            if try store.metaThrowing(StoreKeys.codexUsageStatus) != "ready" {
                metadata[StoreKeys.codexUsageStatus] = "ready"
            }
            try beforeCommitHookForTesting?()
            try stage.validateBeforeCommit?()
            try store.applySourceChanges(
                source: .codex,
                replacingKeyPrefixes: stage.replacePrefixes,
                replacementEntries: stage.replacementEntries,
                additiveEntries: stage.additiveEntries,
                meta: metadata
            )
            return stage.latestRate
        } catch {
            try? store.setMeta(StoreKeys.codexUsageStatus, "incomplete: \(error)")
            throw error
        }
    }

    static func reconcile(store: UsageStore, sessionsDirectory suppliedDirectory: URL? = nil) throws {
        let directory = suppliedDirectory ?? defaultSessionsDirectory
        do {
            var files = try enumerateFiles(directory)
            var validPaths = Set(files.map(\.path))
            var cursors = try readCursors(store)
            var missingDependencies = missingLiveDependencies(cursors, validPaths: validPaths)
            if !missingDependencies.isEmpty {
                // A deleted recovery file may have a surviving sibling with
                // the same session ID. Re-run the normal selector under the
                // caller's source lock before deciding the dependency is lost.
                _ = try refresh(store: store, sessionsDirectory: directory)
                files = try enumerateFiles(directory)
                validPaths = Set(files.map(\.path))
                cursors = try readCursors(store)
                missingDependencies = missingLiveDependencies(cursors, validPaths: validPaths)
            }
            if let dependency = missingDependencies.sorted(by: { $0.path < $1.path }).first {
                let path = dependency.path
                throw CodexScanError.unavailable("fork parent is missing: \(path)")
            }

            let contributionKeys = try store.keysForSourceThrowing(source: .codex)
            let pathsFromRows = Set(contributionKeys.compactMap { key -> String? in
                guard let delimiter = key.lastIndex(of: "|") else { return nil }
                return String(key[..<delimiter])
            })
            let metadata = try store.metadataThrowing(prefix: statePrefix)
            let legacyPrefixesForFiles = Array(legacyPrefixes.dropFirst())
            let legacyMetadata = try legacyPrefixesForFiles.reduce(into: [String: String]()) { result, prefix in
                result.merge(try store.metadataThrowing(prefix: prefix)) { _, new in new }
            }
            func legacyPath(_ key: String) -> String? {
                guard let prefix = legacyPrefixesForFiles.first(where: { key.hasPrefix($0) }) else { return nil }
                return String(key.dropFirst(prefix.count))
            }
            let legacyPaths = Set(legacyMetadata.keys.compactMap(legacyPath))
            let knownPaths = Set(cursors.keys).union(legacyPaths).union(pathsFromRows)
            let deletedPaths = knownPaths.subtracting(validPaths)
            guard !deletedPaths.isEmpty else { return }

            let deleteKeys = metadata.keys.filter { key in
                deletedPaths.contains(String(key.dropFirst(statePrefix.count)))
            } + legacyMetadata.keys.filter { key in legacyPath(key).map(deletedPaths.contains) ?? false }
            try store.applySourceChanges(
                source: .codex,
                replacingKeyPrefixes: deletedPaths.map { $0 + "|" },
                metadataKeysToDelete: Array(Set(deleteKeys)),
                meta: [StoreKeys.codexUsageStatus: "ready"]
            )
        } catch {
            try? store.setMeta(StoreKeys.codexUsageStatus, "incomplete: \(error)")
            throw error
        }
    }

    private static var defaultSessionsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    private static func defaultBackupURL(for store: UsageStore) -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return store.fileURL.deletingLastPathComponent()
            .appendingPathComponent("store.pre-codex-v4-\(stamp)-\(UUID().uuidString).db")
    }

    private static func enumerateFiles(_ directory: URL) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CodexScanError.unavailable("sessions directory is missing or unavailable: \(directory.path)")
        }
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [],
            errorHandler: { _, error in enumerationError = error; return false }
        ) else {
            throw CodexScanError.unavailable("cannot enumerate sessions directory: \(directory.path)")
        }
        var files: [URL] = []
        while let item = enumerator.nextObject() {
            guard let url = item as? URL, url.pathExtension == "jsonl" else { continue }
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey])
                if values.isRegularFile == true { files.append(url) }
            } catch { enumerationError = error; break }
        }
        if let enumerationError {
            throw CodexScanError.unavailable("sessions enumeration failed: \(enumerationError)")
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func missingLiveDependencies(
        _ cursors: [String: CodexFileCursor], validPaths: Set<String>
    ) -> [CodexForkDependency] {
        cursors.filter { validPaths.contains($0.key) }
            .values.flatMap(\.dependencies)
            .filter { !validPaths.contains($0.path) }
    }

    private static func fullRebuild(files: [URL], directory: URL) throws -> RefreshStage {
        let captured = try Dictionary(uniqueKeysWithValues: files.map { ($0.path, try CodexIndex.identity(at: $0)) })
        var scans: [String: CodexScannedFile] = [:]
        for file in files {
            scans[file.path] = try CodexIndex.scan(file, fixedIdentity: captured[file.path])
        }
        try validateScanSnapshots(scans)
        let finalPaths = Set(try enumerateFiles(directory).map(\.path))
        guard finalPaths == Set(files.map(\.path)) else {
            throw CodexScanError.unstable("sessions directory changed during the Codex rebuild")
        }
        let descriptors = try makeDescriptors(scans: scans, existing: [:])
        try validateForkGraph(descriptors)

        var stage = RefreshStage()
        var eofCheckedParentPaths: Set<String> = []
        for descriptor in descriptors.values.sorted(by: { $0.path < $1.path }) {
            let scan = scans[descriptor.path]!
            let match = try matchFork(
                scan.events, forkedFromID: descriptor.forkedFromID, descriptors: descriptors,
                scans: scans, fixedIdentities: captured
            )
            eofCheckedParentPaths.formUnion(match.eofCheckedParentPaths)
            let fallback = Fmt.day(Date(timeIntervalSince1970: Double(scan.identity.modifiedMilliseconds) / 1000))
            let usage = try accumulate(scan.events, matchedPrefixCount: match.count, startingAt: 0,
                                       baseline: nil, fallbackDay: fallback)
            stage.replacementEntries += entries(path: descriptor.path, days: usage.days)
            let cursor = CodexFileCursor(
                identity: scan.identity, offset: scan.offset, tokenEventCount: scan.events.count,
                fallbackSegments: scan.offset > 0 ? [CodexFallbackSegment(startByte: 0, endByte: scan.offset, day: fallback)] : [],
                rawBaseline: usage.baseline, committedRawSHA256: scan.committedRawSHA256,
                sessionID: descriptor.sessionID, forkedFromID: descriptor.forkedFromID,
                sessionMetaSeen: scan.sessionMetaSeen,
                dependencies: match.dependencies, matchedPrefixCount: match.count,
                forkPrefixOpen: match.isOpen,
                childPrefixEndByte: match.count > 0 ? scan.events[match.count - 1].endByte : 0,
                prefixSHA256: try CodexIndex.prefixSHA256(scan.events, count: match.count)
            )
            stage.metadata[StoreKeys.codexCursorState(descriptor.path)] = try encode(cursor)
            updateLatestRate(from: scan.events, into: &stage.latestRate)
        }
        stage.validateBeforeCommit = {
            try validateCapturedSnapshot(captured, directory: directory, expectedPaths: Set(files.map(\.path)))
            try validateScannedCommitHashes(scans)
            try validateEOFChecks(eofCheckedParentPaths, captured: captured)
        }
        return stage
    }

    private static func incrementalRefresh(files: [URL], store: UsageStore, directory: URL) throws -> RefreshStage {
        var cursors = try readCursors(store)
        let identities = try Dictionary(uniqueKeysWithValues: files.map { ($0.path, try CodexIndex.identity(at: $0)) })
        let urls = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        cursors = cursors.filter { identities[$0.key] != nil }
        var forceFull: Set<String> = []
        var metadataDirty: Set<String> = []
        var verifiedPrefixPaths: Set<String> = []
        var verifiedHashers: [String: SHA256] = [:]

        // A changed file must prove that its committed raw prefix is still
        // present before the incremental scanner trusts the old cursor. Hash
        // raw bytes only; JSON decoding remains limited to the new tail.
        for (path, cursor) in cursors {
            guard let identity = identities[path], identity.signature != cursor.identity.signature else { continue }
            guard identity.inode == cursor.identity.inode,
                  identity.size >= cursor.offset,
                  let committedDigest = cursor.committedRawSHA256 else {
                forceFull.insert(path)
                continue
            }
            let hasher = try CodexIndex.rawHasher(urls[path]!, through: cursor.offset, fixedIdentity: identity)
            if CodexIndex.digestString(hasher) == committedDigest {
                verifiedPrefixPaths.insert(path)
                verifiedHashers[path] = hasher
            } else {
                forceFull.insert(path)
            }
        }

        for (childPath, cursor) in cursors {
            var updated = cursor
            var changed = false
            for dependency in cursor.dependencies {
                guard urls[dependency.path] != nil, let identity = identities[dependency.path] else {
                    // A different recovery file may still carry the same
                    // parent session ID. Rebuild the child and resolve the
                    // current candidate set below; graph validation blocks
                    // the commit if every candidate is gone.
                    forceFull.insert(childPath)
                    continue
                }
                guard identity.signature != dependency.identity.signature else { continue }
                let parentAlreadyCommittedAtCurrentIdentity = cursors[dependency.path]?.identity.signature == identity.signature
                if parentAlreadyCommittedAtCurrentIdentity || verifiedPrefixPaths.contains(dependency.path) {
                    if let index = updated.dependencies.firstIndex(where: { $0.path == dependency.path }) {
                        updated.dependencies[index].identity = identity
                        changed = true
                    }
                } else {
                    forceFull.insert(childPath)
                    forceFull.insert(dependency.path)
                }
            }
            if changed {
                cursors[childPath] = updated
                metadataDirty.insert(childPath)
            }
        }

        var scans: [String: CodexScannedFile] = [:]
        var scanWasFull: Set<String> = []
        for file in files {
            let path = file.path
            guard let identity = identities[path] else { continue }
            guard let cursor = cursors[path] else {
                scans[path] = try CodexIndex.scan(file, fixedIdentity: identity)
                scanWasFull.insert(path)
                continue
            }
            if !forceFull.contains(path), identity.signature == cursor.identity.signature {
                continue
            }
            if forceFull.contains(path) || identity.inode != cursor.identity.inode
                || identity.size < cursor.offset || identity.size <= cursor.identity.size {
                scans[path] = try CodexIndex.scan(file, fixedIdentity: identity)
                scanWasFull.insert(path)
            } else if identity.signature != cursor.identity.signature {
                scans[path] = try CodexIndex.scan(
                    file, from: cursor.offset,
                    inheritedSessionID: cursor.sessionID,
                    inheritedForkedFromID: cursor.forkedFromID,
                    inheritedSessionMetaSeen: cursor.sessionMetaSeen ?? (cursor.sessionID != nil),
                    fixedIdentity: identity,
                    startingHasher: verifiedHashers[path]
                )
            } else {
                scans[path] = try CodexIndex.scan(file, fixedIdentity: identity)
                scanWasFull.insert(path)
            }
        }

        // New recovery files may add another candidate for a parent's ID.
        // Re-evaluate existing children that name that ID before committing.
        for (path, scan) in scans where scanWasFull.contains(path) {
            guard let id = scan.sessionID else { continue }
            for (childPath, cursor) in cursors where cursor.forkedFromID == id && childPath != path {
                forceFull.insert(childPath)
            }
        }
        for path in forceFull where !scanWasFull.contains(path) {
            guard let url = urls[path] else { throw CodexScanError.unavailable("fork child is missing: \(path)") }
            scans[path] = try CodexIndex.scan(url, fixedIdentity: identities[path])
            scanWasFull.insert(path)
        }

        for (path, scan) in scans where scanWasFull.contains(path) {
            guard let id = scan.sessionID else { continue }
            for (childPath, cursor) in cursors where cursor.forkedFromID == id && childPath != path {
                if scans[childPath] == nil, let childURL = urls[childPath] {
                    scans[childPath] = try CodexIndex.scan(childURL, fixedIdentity: identities[childPath])
                    scanWasFull.insert(childPath)
                    forceFull.insert(childPath)
                }
            }
        }

        let descriptors = try makeDescriptors(scans: scans, existing: cursors)
        try validateForkGraph(descriptors)
        var stage = RefreshStage()
        var parentPathsRead: Set<String> = []
        var eofCheckedParentPaths: Set<String> = []
        let emptyPrefixHash = try CodexIndex.prefixSHA256([], count: 0)
        for descriptor in descriptors.values.sorted(by: { $0.path < $1.path }) {
            guard let scan = scans[descriptor.path] else { continue }
            let path = descriptor.path
            let previous = cursors[path]
            let isFull = scanWasFull.contains(path)
            var matchCount = previous?.matchedPrefixCount ?? 0
            var dependencies = previous?.dependencies ?? []
            var forkPrefixOpen = previous?.forkPrefixOpen ?? false
            var days: [String: UsageAmount] = [:]
            var baseline = previous?.rawBaseline
            var tokenCount = previous?.tokenEventCount ?? 0
            var fallbackSegments = previous?.fallbackSegments ?? []
            var prefixEnd = previous?.childPrefixEndByte ?? 0
            var prefixHash = previous?.prefixSHA256 ?? emptyPrefixHash

            if isFull {
                let match = try matchFork(
                    scan.events, forkedFromID: descriptor.forkedFromID,
                    descriptors: descriptors, scans: scans, urls: urls, fixedIdentities: identities
                )
                parentPathsRead.formUnion(match.parentPathsRead)
                eofCheckedParentPaths.formUnion(match.eofCheckedParentPaths)
                matchCount = match.count
                dependencies = match.dependencies
                forkPrefixOpen = match.isOpen
                let fallback = Fmt.day(Date(timeIntervalSince1970: Double(scan.identity.modifiedMilliseconds) / 1000))
                let usage = try accumulate(scan.events, matchedPrefixCount: matchCount, startingAt: 0,
                                           baseline: nil, fallbackDay: fallback)
                days = usage.days
                baseline = usage.baseline
                tokenCount = scan.events.count
                fallbackSegments = scan.offset > 0 ? [CodexFallbackSegment(startByte: 0, endByte: scan.offset, day: fallback)] : []
                prefixEnd = matchCount > 0 ? scan.events[matchCount - 1].endByte : 0
                prefixHash = try CodexIndex.prefixSHA256(scan.events, count: matchCount)
                let unchanged = previous?.committedRawSHA256 != nil
                    && previous?.committedRawSHA256 == scan.committedRawSHA256
                    && !forceFull.contains(path)
                if previous == nil || !unchanged {
                    stage.replacePrefixes.append(path + "|")
                    stage.replacementEntries += entries(path: path, days: days)
                }
            } else {
                guard let previous else { continue }
                if previous.forkPrefixOpen {
                    let match = try extendOpenFork(
                        tailEvents: scan.events, oldTokenCount: previous.tokenEventCount,
                        matchedPrefixCount: previous.matchedPrefixCount,
                        prefixEndByte: previous.childPrefixEndByte,
                        prefixSHA256: previous.prefixSHA256,
                        dependencies: previous.dependencies,
                        descriptors: descriptors, scans: scans, urls: urls, identities: identities
                    )
                    parentPathsRead.formUnion(match.parentPathsRead)
                    eofCheckedParentPaths.formUnion(match.eofCheckedParentPaths)
                    matchCount = match.count
                    prefixEnd = match.prefixEndByte
                    prefixHash = match.prefixSHA256
                    dependencies = match.dependencies
                    forkPrefixOpen = match.isOpen
                }
                let usage = try accumulate(scan.events, matchedPrefixCount: matchCount,
                                           startingAt: tokenCount, baseline: baseline,
                                           fallbackDay: Fmt.day(Date(timeIntervalSince1970: Double(scan.identity.modifiedMilliseconds) / 1000)))
                days = usage.days
                baseline = usage.baseline
                tokenCount += scan.events.count
                if scan.offset > previous.offset {
                    fallbackSegments.append(CodexFallbackSegment(
                        startByte: previous.offset, endByte: scan.offset,
                        day: Fmt.day(Date(timeIntervalSince1970: Double(scan.identity.modifiedMilliseconds) / 1000))
                    ))
                }
                if !days.isEmpty { stage.additiveEntries += entries(path: path, days: days) }
            }

            let cursor = CodexFileCursor(
                identity: scan.identity, offset: scan.offset, tokenEventCount: tokenCount,
                fallbackSegments: fallbackSegments, rawBaseline: baseline,
                committedRawSHA256: scan.committedRawSHA256 ?? previous?.committedRawSHA256,
                sessionID: descriptor.sessionID, forkedFromID: descriptor.forkedFromID,
                sessionMetaSeen: scan.sessionMetaSeen,
                dependencies: dependencies, matchedPrefixCount: matchCount,
                forkPrefixOpen: forkPrefixOpen,
                childPrefixEndByte: prefixEnd, prefixSHA256: prefixHash
            )
            stage.metadata[StoreKeys.codexCursorState(path)] = try encode(cursor)
            updateLatestRate(from: scan.events, into: &stage.latestRate)
        }
        // Cursors whose parent dependency changed only by appending retain
        // their usage rows. Persist the newly verified parent signature.
        for (path, cursor) in cursors where scans[path] == nil && metadataDirty.contains(path) {
            stage.metadata[StoreKeys.codexCursorState(path)] = try encode(cursor)
        }
        stage.validateBeforeCommit = {
            try validateCapturedSnapshot(identities, directory: directory,
                                         expectedPaths: Set(files.map(\.path)))
            try validateScannedCommitHashes(scans)
            try validatePersistedParentReads(parentPathsRead, scans: scans, cursors: cursors,
                                             identities: identities)
            try validateEOFChecks(eofCheckedParentPaths, captured: identities)
        }
        return stage
    }

    private struct Descriptor {
        let path: String
        let sessionID: String?
        let forkedFromID: String?
    }

    private struct ForkMatch {
        let count: Int
        let dependencies: [CodexForkDependency]
        let isOpen: Bool
        let parentPathsRead: Set<String>
        let eofCheckedParentPaths: Set<String>
    }

    private struct ForkExtension {
        let count: Int
        let prefixEndByte: Int64
        let prefixSHA256: String
        let dependencies: [CodexForkDependency]
        let isOpen: Bool
        let parentPathsRead: Set<String>
        let eofCheckedParentPaths: Set<String>
    }

    private static func makeDescriptors(
        scans: [String: CodexScannedFile], existing: [String: CodexFileCursor]
    ) throws -> [String: Descriptor] {
        var result: [String: Descriptor] = [:]
        let paths = Set(scans.keys).union(existing.keys)
        for path in paths {
            let scan = scans[path]
            let cursor = existing[path]
            let id = scan != nil ? scan!.sessionID : cursor?.sessionID
            let parentID = scan != nil ? scan!.forkedFromID : cursor?.forkedFromID
            if id?.hasPrefix("!conflict:") == true || parentID?.hasPrefix("!conflict:") == true {
                throw CodexScanError.invalid("conflicting session metadata: \(path)")
            }
            result[path] = Descriptor(path: path, sessionID: id, forkedFromID: parentID)
        }
        return result
    }

    private static func validateForkGraph(_ descriptors: [String: Descriptor]) throws {
        var byID: [String: [Descriptor]] = [:]
        for descriptor in descriptors.values {
            if let id = descriptor.sessionID { byID[id, default: []].append(descriptor) }
        }
        for (id, recoveryFiles) in byID {
            let relationships = Set<String?>(recoveryFiles.map(\.forkedFromID))
            guard relationships.count > 1 else { continue }
            let parents = relationships.map { $0 ?? "<none>" }.sorted().joined(separator: ", ")
            throw CodexScanError.invalid("conflicting fork parents for session \(id): \(parents)")
        }
        var graph: [String: Set<String>] = [:]
        for descriptor in descriptors.values {
            guard let parentID = descriptor.forkedFromID else { continue }
            guard let childID = descriptor.sessionID else {
                throw CodexScanError.invalid("fork child has no session ID: \(descriptor.path)")
            }
            guard byID[parentID] != nil else {
                throw CodexScanError.unavailable("fork parent session is missing: \(parentID)")
            }
            graph[childID, default: []].insert(parentID)
        }
        var visiting: Set<String> = []
        var visited: Set<String> = []
        func visit(_ id: String) throws {
            if visited.contains(id) { return }
            guard visiting.insert(id).inserted else {
                throw CodexScanError.invalid("fork relationship cycle at session \(id)")
            }
            for parent in graph[id] ?? [] { try visit(parent) }
            visiting.remove(id)
            visited.insert(id)
        }
        for id in graph.keys { try visit(id) }
    }

    private static func matchFork(
        _ childEvents: [CodexTokenRecord],
        forkedFromID: String?,
        descriptors: [String: Descriptor],
        scans: [String: CodexScannedFile],
        urls: [String: URL]? = nil,
        fixedIdentities: [String: CodexFileIdentity]? = nil
    ) throws -> ForkMatch {
        guard let forkedFromID else {
            return ForkMatch(count: 0, dependencies: [], isOpen: false,
                             parentPathsRead: [], eofCheckedParentPaths: [])
        }
        let candidates = descriptors.values.filter { $0.sessionID == forkedFromID }.sorted { $0.path < $1.path }
        guard !candidates.isEmpty else {
            throw CodexScanError.unavailable("fork parent session is missing: \(forkedFromID)")
        }
        var parentEvents: [String: [CodexTokenRecord]] = [:]
        var parentPathsRead: Set<String> = []
        for candidate in candidates {
            if let scan = scans[candidate.path], scan.startOffset == 0 {
                parentEvents[candidate.path] = scan.events
            } else if !childEvents.isEmpty, let url = urls?[candidate.path] {
                parentPathsRead.insert(candidate.path)
                parentEvents[candidate.path] = try CodexIndex.scan(
                    url, maximumEvents: childEvents.count, inheritedSessionID: candidate.sessionID,
                    inheritedForkedFromID: descriptors[candidate.path]?.forkedFromID,
                    fixedIdentity: fixedIdentities?[candidate.path]
                ).events
            } else {
                parentEvents[candidate.path] = []
            }
        }
        var candidateMatches: [String: Int] = [:]
        for candidate in candidates {
            let events = parentEvents[candidate.path] ?? []
            var common = 0
            while common < min(childEvents.count, events.count),
                  childEvents[common].fingerprint == events[common].fingerprint { common += 1 }
            candidateMatches[candidate.path] = common
        }
        let best = candidateMatches.values.max() ?? 0
        var dependencies: [CodexForkDependency] = []
        var eofCheckedParentPaths: Set<String> = []
        for candidate in candidates {
            let events = parentEvents[candidate.path] ?? []
            let common = candidateMatches[candidate.path] ?? 0
            if childEvents.count > 0 && events.count < childEvents.count && common == events.count {
                eofCheckedParentPaths.insert(candidate.path)
            }
            let checkCount = common
            let endByte = common > 0 ? events[common - 1].endByte : 0
            let identity: CodexFileIdentity
            if let scanned = scans[candidate.path] { identity = scanned.identity }
            else if let fixed = fixedIdentities?[candidate.path] { identity = fixed }
            else if let url = urls?[candidate.path] { identity = try CodexIndex.identity(at: url) }
            else {
                throw CodexScanError.unavailable("cannot find fork parent file: \(candidate.path)")
            }
            dependencies.append(CodexForkDependency(
                path: candidate.path, sessionID: forkedFromID, identity: identity,
                checkedEventCount: checkCount, checkedEndByte: endByte,
                checkedPrefixSHA256: try CodexIndex.prefixSHA256(events, count: checkCount),
                parentWasShorterThanChild: events.count < childEvents.count
            ))
        }
        return ForkMatch(count: best, dependencies: dependencies, isOpen: best == childEvents.count,
                         parentPathsRead: parentPathsRead, eofCheckedParentPaths: eofCheckedParentPaths)
    }

    private static func extendOpenFork(
        tailEvents: [CodexTokenRecord], oldTokenCount: Int,
        matchedPrefixCount: Int, prefixEndByte: Int64, prefixSHA256: String,
        dependencies: [CodexForkDependency], descriptors: [String: Descriptor],
        scans: [String: CodexScannedFile], urls: [String: URL],
        identities: [String: CodexFileIdentity]
    ) throws -> ForkExtension {
        guard !tailEvents.isEmpty else {
            return ForkExtension(count: matchedPrefixCount, prefixEndByte: prefixEndByte,
                                 prefixSHA256: prefixSHA256, dependencies: dependencies, isOpen: true,
                                 parentPathsRead: [], eofCheckedParentPaths: [])
        }
        var updatedDependencies = dependencies
        var bestExtension = 0
        var parentPathsRead: Set<String> = []
        var eofCheckedParentPaths: Set<String> = []
        for index in updatedDependencies.indices {
            var dependency = updatedDependencies[index]
            guard dependency.checkedEventCount == oldTokenCount,
                  let url = urls[dependency.path], let identity = identities[dependency.path] else { continue }
            let parentTail: [CodexTokenRecord]
            if let scan = scans[dependency.path], scan.startOffset == 0 {
                parentTail = Array(scan.events.dropFirst(dependency.checkedEventCount).prefix(tailEvents.count))
            } else if let scan = scans[dependency.path], scan.startOffset == dependency.checkedEndByte {
                parentTail = Array(scan.events.prefix(tailEvents.count))
            } else {
                parentPathsRead.insert(dependency.path)
                parentTail = try CodexIndex.scan(
                    url, from: dependency.checkedEndByte, maximumEvents: tailEvents.count,
                    inheritedSessionID: dependency.sessionID,
                    inheritedForkedFromID: descriptors[dependency.path]?.forkedFromID,
                    inheritedSessionMetaSeen: true,
                    fixedIdentity: identity
                ).events
            }
            var common = 0
            while common < min(tailEvents.count, parentTail.count),
                  tailEvents[common].fingerprint == parentTail[common].fingerprint { common += 1 }
            if parentTail.count < tailEvents.count && common == parentTail.count {
                eofCheckedParentPaths.insert(dependency.path)
                let afterRead = try CodexIndex.identity(at: url)
                guard afterRead.signature == identity.signature else {
                    throw CodexScanError.unstable("fork parent changed while checking an open prefix: \(url.path)")
                }
            }
            if common > bestExtension { bestExtension = common }
            dependency.identity = identity
            dependency.checkedEventCount += common
            dependency.checkedEndByte = common > 0 ? parentTail[common - 1].endByte : dependency.checkedEndByte
            dependency.checkedPrefixSHA256 = try CodexIndex.extendPrefixSHA256(
                dependency.checkedPrefixSHA256, with: Array(tailEvents.prefix(common))
            )
            dependency.parentWasShorterThanChild = parentTail.count < tailEvents.count
            updatedDependencies[index] = dependency
        }
        let matchedCount = matchedPrefixCount + bestExtension
        let updatedPrefixEnd = bestExtension > 0 ? tailEvents[bestExtension - 1].endByte : prefixEndByte
        let updatedPrefixHash = try CodexIndex.extendPrefixSHA256(
            prefixSHA256, with: Array(tailEvents.prefix(bestExtension))
        )
        return ForkExtension(
            count: matchedCount, prefixEndByte: updatedPrefixEnd,
            prefixSHA256: updatedPrefixHash, dependencies: updatedDependencies,
            isOpen: bestExtension == tailEvents.count,
            parentPathsRead: parentPathsRead, eofCheckedParentPaths: eofCheckedParentPaths
        )
    }

    private static func accumulate(
        _ events: [CodexTokenRecord], matchedPrefixCount: Int, startingAt startIndex: Int,
        baseline initialBaseline: CodexUsageSnapshot?, fallbackDay: String
    ) throws -> (days: [String: UsageAmount], baseline: CodexUsageSnapshot?) {
        var days: [String: UsageAmount] = [:]
        var baseline = initialBaseline
        for (relativeIndex, event) in events.enumerated() {
            let absoluteIndex = startIndex + relativeIndex
            if absoluteIndex < matchedPrefixCount {
                if let current = event.total { baseline = current }
                continue
            }
            var amount: UsageAmount
            if let current = event.total {
                if let previous = baseline {
                    let delta = current.amount - previous.amount
                    if delta.input < 0 || delta.output < 0 || delta.cacheRead < 0 || delta.cacheWrite < 0 {
                        amount = event.last?.amount ?? current.amount
                    } else {
                        amount = delta
                    }
                } else {
                    amount = event.last?.amount ?? current.amount
                }
                baseline = current
            } else if let last = event.last {
                amount = last.amount
            } else {
                continue
            }
            guard amount.input >= 0, amount.output >= 0, amount.cacheRead >= 0, amount.cacheWrite >= 0 else {
                throw CodexScanError.invalid("negative token delta in Codex event")
            }
            let exclusiveInput = amount.input - amount.cacheRead - amount.cacheWrite
            guard exclusiveInput >= 0 else {
                throw CodexScanError.invalid("cache buckets exceed input_tokens; Codex totals were not committed")
            }
            guard amount.input != 0 || amount.output != 0 || amount.cacheRead != 0 || amount.cacheWrite != 0 else {
                continue
            }
            amount.input = exclusiveInput
            let day = event.timestamp.map(Fmt.day) ?? fallbackDay
            days[day, default: .zero] = days[day, default: .zero] + amount
        }
        return (days, baseline)
    }

    private static func entries(path: String, days: [String: UsageAmount]) -> [ContribEntry] {
        days.map { day, amount in
            ContribEntry(source: .codex, key: path + "|" + day, day: day, amount: amount)
        }
    }

    private static func validateScanSnapshots(_ scans: [String: CodexScannedFile]) throws {
        for scan in scans.values {
            let current = try CodexIndex.identity(at: scan.url)
            guard current.inode == scan.identity.inode, current.size >= scan.identity.size else {
                throw CodexScanError.unstable("file was replaced or truncated before Codex commit: \(scan.url.path)")
            }
            if current.size == scan.identity.size,
               current.modifiedMilliseconds != scan.identity.modifiedMilliseconds {
                throw CodexScanError.unstable("file changed before Codex commit: \(scan.url.path)")
            }
        }
    }

    private static func validateCapturedSnapshot(
        _ captured: [String: CodexFileIdentity], directory: URL, expectedPaths: Set<String>
    ) throws {
        let finalPaths = Set(try enumerateFiles(directory).map(\.path))
        guard finalPaths == expectedPaths else {
            throw CodexScanError.unstable("sessions directory changed before Codex commit")
        }
        for (path, expected) in captured {
            let current = try CodexIndex.identity(at: URL(fileURLWithPath: path))
            guard current.inode == expected.inode, current.size >= expected.size else {
                throw CodexScanError.unstable("file was replaced or truncated before Codex commit: \(path)")
            }
            if current.size == expected.size,
               current.modifiedMilliseconds != expected.modifiedMilliseconds {
                throw CodexScanError.unstable("file changed before Codex commit: \(path)")
            }
        }
    }

    private static func validateScannedCommitHashes(_ scans: [String: CodexScannedFile]) throws {
        try validateScanSnapshots(scans)
        for scan in scans.values {
            guard let expected = scan.committedRawSHA256 else {
                throw CodexScanError.invalid("scan did not produce a committed raw-prefix hash: \(scan.url.path)")
            }
            let hasher = try CodexIndex.rawHasher(scan.url, through: scan.offset, fixedIdentity: scan.identity)
            guard CodexIndex.digestString(hasher) == expected else {
                throw CodexScanError.unstable("committed prefix changed during Codex scan: \(scan.url.path)")
            }
        }
    }

    private static func validatePersistedParentReads(
        _ paths: Set<String>, scans: [String: CodexScannedFile],
        cursors: [String: CodexFileCursor], identities: [String: CodexFileIdentity]
    ) throws {
        for path in paths where scans[path] == nil {
            guard let cursor = cursors[path], let identity = identities[path],
                  let expected = cursor.committedRawSHA256 else {
                throw CodexScanError.unavailable("cannot validate previously committed fork parent: \(path)")
            }
            let hasher = try CodexIndex.rawHasher(
                URL(fileURLWithPath: path), through: cursor.offset, fixedIdentity: identity
            )
            guard CodexIndex.digestString(hasher) == expected else {
                throw CodexScanError.unstable("fork parent changed during prefix matching: \(path)")
            }
        }
    }

    private static func validateEOFChecks(
        _ paths: Set<String>, captured: [String: CodexFileIdentity]
    ) throws {
        for path in paths {
            guard let expected = captured[path] else {
                throw CodexScanError.unavailable("cannot verify fork parent snapshot: \(path)")
            }
            let current = try CodexIndex.identity(at: URL(fileURLWithPath: path))
            guard current.signature == expected.signature else {
                throw CodexScanError.unstable("fork parent changed after an end-of-file prefix check: \(path)")
            }
        }
    }

    private static func readCursors(_ store: UsageStore) throws -> [String: CodexFileCursor] {
        let metadata = try store.metadataThrowing(prefix: statePrefix)
        var result: [String: CodexFileCursor] = [:]
        let decoder = JSONDecoder()
        for (key, raw) in metadata {
            let path = String(key.dropFirst(statePrefix.count))
            guard let data = raw.data(using: .utf8) else {
                throw CodexScanError.invalid("invalid Codex cursor for \(path)")
            }
            do { result[path] = try decoder.decode(CodexFileCursor.self, from: data) }
            catch { throw CodexScanError.invalid("invalid Codex cursor for \(path): \(error)") }
        }
        return result
    }

    private static func encode(_ cursor: CodexFileCursor) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(cursor)
        guard let raw = String(data: data, encoding: .utf8) else {
            throw CodexScanError.invalid("could not encode Codex cursor")
        }
        return raw
    }

    private static func updateLatestRate(
        from events: [CodexTokenRecord], into best: inout (json: [String: Any], ts: Double)?
    ) {
        for event in events {
            guard let json = event.rateLimits, json["primary"] != nil || json["secondary"] != nil || json["used_percent"] != nil else {
                continue
            }
            let ts = event.timestamp?.timeIntervalSince1970 ?? 0
            if best == nil || ts > best!.ts { best = (json, ts) }
        }
    }
}
