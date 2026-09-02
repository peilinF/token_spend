import Foundation

final class ActivityWatcher {
    var onActivity: ((Tool) -> Void)?

    private struct Watch {
        var source: DispatchSourceFileSystemObject?
        var path: String = ""
    }

    private var watches: [String: Watch] = [:]
    private let queue = DispatchQueue(label: "tokenspend.activitywatcher", qos: .utility)
    private var retargetTimer: DispatchSourceTimer?
    private var started = false
    private var pendingTools: Set<Tool> = []
    private var flushWork: DispatchWorkItem?

    func start() {
        guard !started else { return }
        started = true
        retargetAll()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.retargetAll() }
        timer.activate()
        retargetTimer = timer
    }

    func stop() {
        retargetTimer?.cancel()
        flushWork?.cancel()
        pendingTools.removeAll()
        for key in Array(watches.keys) { unwatch(key) }
        started = false
    }

    private func retargetAll() {
        let targets: [(Tool, [String])] = [
            (.opencode, opencodeTargets()),
            (.codex, CodexSource.newestSessionFile().map { [$0.path] } ?? []),
            (.cursor, CursorLogs.newestRequestTrace().map { [$0.url.path] } ?? []),
        ]
        var desired = Set<String>()
        for (tool, paths) in targets {
            for path in paths where FileManager.default.fileExists(atPath: path) {
                let key = "\(tool.rawValue)|\(path)"
                desired.insert(key)
                if watches[key]?.source != nil { continue }
                watch(tool, path: path, key: key)
            }
        }
        for key in Array(watches.keys) where !desired.contains(key) {
            unwatch(key)
        }
    }

    private func opencodeTargets() -> [String] {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db").path
        return [base + "-wal", base].filter { FileManager.default.fileExists(atPath: $0) }
    }

    private func watch(_ tool: Tool, path: String, key: String) {
        unwatch(key)
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let flags = source.data
            if !flags.isDisjoint(with: [.write, .extend, .attrib]) {
                self.emit(tool)
            }
            if !flags.isDisjoint(with: [.delete, .rename, .revoke]) {
                self.unwatch(key)
            }
        }
        source.setCancelHandler { close(fd) }
        source.activate()
        watches[key] = Watch(source: source, path: path)
    }

    private func unwatch(_ key: String) {
        watches[key]?.source?.cancel()
        watches[key] = nil
    }

    private func emit(_ tool: Tool) {
        pendingTools.insert(tool)
        flushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let tools = self.pendingTools
            self.pendingTools.removeAll()
            for tool in tools {
                self.onActivity?(tool)
            }
        }
        flushWork = work
        queue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}
