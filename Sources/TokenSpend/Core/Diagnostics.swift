import AppKit
import Darwin
import Foundation

enum Diagnostics {
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "diag_enabled")
    }

    static var logURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("TokenSpend/diag.log")
    }

    private static let ioQueue = DispatchQueue(label: "tokenspend.diag")
    private static var snapshotTimer: DispatchSourceTimer?
    private static var stallTimer: DispatchSourceTimer?

    static func start() {
        guard isEnabled else { return }
        append("diag start")

        let snap = DispatchSource.makeTimerSource(queue: ioQueue)
        snap.schedule(deadline: .now() + 2, repeating: 60)
        snap.setEventHandler { writeSnapshot() }
        snap.activate()
        snapshotTimer = snap

        let stall = DispatchSource.makeTimerSource(queue: ioQueue)
        stall.schedule(deadline: .now() + 1, repeating: 1)
        stall.setEventHandler { probeStall() }
        stall.activate()
        stallTimer = stall
    }

    static func revealLog() {
        let url = logURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static func writeSnapshot() {
        let footprint = physFootprintBytes()
        let threads = threadCount()
        let cache = FileResultCache.shared.count
        var active = "none"
        var waiting = "none"
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.main.async {
            let state = AppState.shared
            let tools = state.activeTools.sorted { $0.rawValue < $1.rawValue }.map(\.rawValue)
            active = tools.isEmpty ? "none" : tools.joined(separator: ",")
            let waits = state.waiting.keys.sorted { $0.rawValue < $1.rawValue }.map(\.rawValue)
            waiting = waits.isEmpty ? "none" : waits.joined(separator: ",")
            group.leave()
        }
        _ = group.wait(timeout: .now() + 1)
        let mb = Double(footprint) / 1_048_576
        append(String(format: "footprint_mb=%.1f threads=%d cache=%d active=%@ waiting=%@", mb, threads, cache, active as NSString, waiting as NSString))
    }

    private static func probeStall() {
        let posted = Date()
        DispatchQueue.main.async {
            let delayMs = Date().timeIntervalSince(posted) * 1000
            if delayMs > 100 {
                append(String(format: "main_stall=%.0fms", delayMs))
            }
        }
    }

    private static func append(_ line: String) {
        ioQueue.async {
            let url = logURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: Data())
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            let stamp = ISO8601DateFormatter().string(from: Date())
            let data = Data("\(stamp) \(line)\n".utf8)
            try? handle.write(contentsOf: data)
        }
    }

    private static func physFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return info.phys_footprint
    }

    private static func threadCount() -> Int {
        var threadList: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        let kr = task_threads(mach_task_self_, &threadList, &count)
        guard kr == KERN_SUCCESS else { return 0 }
        if let threadList {
            let size = vm_size_t(MemoryLayout<thread_t>.stride * Int(count))
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threadList)), size)
        }
        return Int(count)
    }
}
