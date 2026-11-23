import Foundation
import Darwin

/// RAM and swap accounting.
///
/// The split mirrors what `vm_stat`/Activity Monitor report: app pages are the
/// active set, the compressed pager is shown at its physical footprint, and
/// everything reclaimable (inactive file cache plus purgeable pages) is shown
/// separately so "used" never looks scarier than it is.
public final class MemorySampler {
    private let host = mach_host_self()
    private let pageSize: Double

    public init() {
        var size: vm_size_t = 0
        host_page_size(host, &size)
        pageSize = size > 0 ? Double(size) : 4096
    }

    public func read() -> MemorySnapshot {
        var snapshot = MemorySnapshot()
        snapshot.totalBytes = Double(CPUSampler.intSysctl("hw.memsize") ?? 0)

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)

        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS, snapshot.totalBytes > 0 else { return snapshot }

        let pages = pageSize
        let free = Double(stats.free_count) * pages
        let active = Double(stats.active_count) * pages
        let inactive = Double(stats.inactive_count) * pages
        let wired = Double(stats.wire_count) * pages
        let speculative = Double(stats.speculative_count) * pages
        let purgeable = Double(stats.purgeable_count) * pages
        let compressed = Double(stats.compressor_page_count) * pages

        snapshot.freeBytes = free + speculative
        snapshot.appBytes = active
        snapshot.wiredBytes = wired
        snapshot.compressedBytes = compressed
        // External (file-backed) pages live inside the inactive set already.
        snapshot.cachedBytes = inactive + purgeable
        snapshot.usedBytes = active + wired + compressed
        snapshot.pressurePercent = snapshot.usedBytes / snapshot.totalBytes * 100

        readSwap(into: &snapshot)
        return snapshot
    }

    private func readSwap(into snapshot: inout MemorySnapshot) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return }
        snapshot.swapTotalBytes = Double(usage.xsu_total)
        snapshot.swapUsedBytes = Double(usage.xsu_used)
    }
}
