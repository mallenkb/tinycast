import Darwin
import Foundation
import os

struct AppMemorySample: Sendable {
    private static let idleTarget: UInt64 = 60_000_000
    private static let budget: UInt64 = 100_000_000
    private static let megabyte: UInt64 = 1_000_000
    private static let logger = Logger(subsystem: "com.tinycast.app", category: "Memory")

    let footprint: UInt64
    private let peak: UInt64
    private let compressed: UInt64
    private let graphics: Int64
    private let heapInUse: Int?
    private let helpers: [String: UInt64]

    private var helperBytes: UInt64 { helpers.values.reduce(0, +) }
    private var total: UInt64 { footprint + helperBytes }
    var isOverBudget: Bool { total >= Self.budget }
    var isAboveIdleTarget: Bool { total > Self.idleTarget }

    func allocatorGoal(currentFootprint: UInt64) -> Int {
        let combined = currentFootprint + helperBytes
        guard combined > Self.idleTarget else { return 0 }
        return Int(min(currentFootprint, combined - Self.idleTarget))
    }

    @concurrent static func capture() async -> Self? {
        guard !Task.isCancelled, let info = virtualMemory() else { return nil }
        return Self(
            footprint: info.phys_footprint, peak: UInt64(clamping: info.ledger_phys_footprint_peak),
            compressed: info.compressed,
            graphics: info.ledger_tag_graphics_footprint + info.ledger_tag_graphics_footprint_compressed,
            heapInUse: info.phys_footprint >= budget ? allocatedHeapBytes() : nil,
            helpers: helperFootprints())
    }

    static func virtualMemory() -> task_vm_info_data_t? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info : nil
    }

    private static func allocatedHeapBytes() -> Int {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        return statistics.size_in_use
    }

    private static func helperFootprints() -> [String: UInt64] {
        let parent = getpid()
        let capacity = Int(proc_listchildpids(parent, nil, 0))
        guard capacity > 0 else { return [:] }
        var children = [pid_t](repeating: 0, count: capacity)
        let count = children.withUnsafeMutableBytes {
            proc_listchildpids(parent, $0.baseAddress, Int32($0.count))
        }
        guard count > 0 else { return [:] }
        let directory = Bundle.main.bundleURL.resolvingSymlinksInPath().appending(path: "Contents/Helpers").pathComponents
        var helpers: [String: UInt64] = [:]
        var path = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        for child in children.prefix(Int(count)) {
            let length = path.withUnsafeMutableBytes { proc_pidpath(child, $0.baseAddress, UInt32($0.count)) }
            guard length > 0, let executablePath = String(bytes: path.prefix(Int(length)), encoding: .utf8) else { continue }
            let executable = URL(filePath: executablePath)
            guard executable.pathComponents.starts(with: directory) else { continue }
            var usage = rusage_info_v4()
            let status = withUnsafeMutableBytes(of: &usage) {
                proc_pid_rusage(child, RUSAGE_INFO_V4, $0.baseAddress!.assumingMemoryBound(to: rusage_info_t?.self))
            }
            if status == 0 { helpers[executable.lastPathComponent, default: 0] += usage.ri_phys_footprint }
        }
        return helpers
    }

    func record(activity: String?, since previous: Self?) -> Bool {
        let noteworthy = isNoteworthy(since: previous)
        let helperSizes = helpers.keys.sorted().map { "\($0)=\(helpers[$0, default: 0] / Self.megabyte)" }
        let heap = heapInUse.map { String($0 / Int(Self.megabyte)) } ?? "unsampled"
        let level: OSLogType = noteworthy ? .default : .info
        Self.logger.log(level: level, """
            Memory MB: total=\(self.total / Self.megabyte) app=\(self.footprint / Self.megabyte) \
            peak=\(self.peak / Self.megabyte) \
            compressed=\(self.compressed / Self.megabyte) graphics=\(self.graphics / Int64(Self.megabyte)) \
            heapInUse=\(heap, privacy: .public) helpers=[\(helperSizes.joined(separator: ", "), privacy: .public)] \
            activity=\(activity ?? "background", privacy: .public)
            """)
        return noteworthy
    }

    private func isNoteworthy(since previous: Self?) -> Bool {
        guard let previous else { return true }
        if isOverBudget != previous.isOverBudget || isAboveIdleTarget != previous.isAboveIdleTarget { return true }
        let step = 16 * Self.megabyte
        if peak >= previous.peak + step { return true }
        guard total >= Self.budget else { return false }
        if abs(Int64(footprint) - Int64(previous.footprint)) >= step { return true }
        return Set(helpers.keys).union(previous.helpers.keys).contains {
            abs(Int64(helpers[$0, default: 0]) - Int64(previous.helpers[$0, default: 0])) >= step
        }
    }
}
