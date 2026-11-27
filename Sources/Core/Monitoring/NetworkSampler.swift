import Foundation
import Darwin
import SystemConfiguration

/// Throughput from link-layer byte counters.
///
/// Primary path reads native 64-bit counters via `sysctl` (`NET_RT_IFLIST2` /
/// `if_data64`, the same unprivileged source `netstat -ib` uses), avoiding the
/// 32-bit `getifaddrs` rollover every 4 GiB. `getifaddrs` stays as a fallback.
/// Elapsed intervals use `CLOCK_MONOTONIC_RAW` so NTP adjustments cannot shrink
/// the time delta and produce artificial spikes.
public final class NetworkSampler {
    struct Counter {
        var received: UInt64
        var sent: UInt64
    }

    struct CounterReading {
        var counters: [String: Counter]
        var is64Bit: Bool
    }

    private var previous: [String: Counter] = [:]
    private var previousIs64Bit = true
    private var session: [String: Counter] = [:]
    private var lastSampleTime: TimeInterval?
    private var lastSnapshot: NetworkSnapshot?

    private let nowProvider: () -> TimeInterval
    private let counterProvider: () -> CounterReading
    private let primaryInterfaceProvider: () -> String?

    /// Minimum elapsed window for rate division; shorter bursts (e.g. timer
    /// catch-up or rapid interval changes) keep the previous baseline intact.
    private static let minElapsed: TimeInterval = 0.2

    /// Tunnels and link-local adapters whose bytes already travelled over a
    /// physical NIC we also measure, so counting them would double the total.
    private static let doubleCountedPrefixes = ["utun", "ipsec", "ppp", "awdl", "llw", "bridge", "vlan", "gif", "stf", "anpi", "tun", "tap"]
    private static let ignoredPrefixes = ["lo", "pktap", "fwip", "ap1"]

    public convenience init() {
        self.init(
            now: Self.monotonicSeconds,
            counters: Self.collectCounters,
            primaryInterface: Self.primaryInterfaceName
        )
    }

    internal init(
        now: @escaping () -> TimeInterval,
        counters: @escaping () -> CounterReading,
        primaryInterface: @escaping () -> String? = { nil }
    ) {
        self.nowProvider = now
        self.counterProvider = counters
        self.primaryInterfaceProvider = primaryInterface
    }

    public func read() -> NetworkSnapshot {
        let now = nowProvider()
        if let lastTime = lastSampleTime {
            let elapsed = now - lastTime
            if elapsed < Self.minElapsed {
                return lastSnapshot ?? NetworkSnapshot()
            }
        }

        let elapsed = lastSampleTime.map { now - $0 } ?? 0
        let reading = counterProvider()
        var snapshot = NetworkSnapshot()
        snapshot.activeInterface = primaryInterfaceProvider()

        var interfaces: [NetworkInterfaceSample] = []
        var aggregateDownload = 0.0
        var aggregateUpload = 0.0
        var sessionIn = 0.0
        var sessionOut = 0.0

        for (name, counter) in reading.counters.sorted(by: { $0.key < $1.key }) {
            if Self.ignoredPrefixes.contains(where: { name.hasPrefix($0) }) { continue }
            let isDoubleCounted = Self.doubleCountedPrefixes.contains(where: { name.hasPrefix($0) })

            var download = 0.0
            var upload = 0.0
            var received = UInt64(0)
            var sent = UInt64(0)

            if let last = previous[name], elapsed >= Self.minElapsed, !isDoubleCounted {
                let is64Bit = reading.is64Bit && previousIs64Bit
                received = delta(current: counter.received, previous: last.received, is64Bit: is64Bit, elapsed: elapsed)
                sent = delta(current: counter.sent, previous: last.sent, is64Bit: is64Bit, elapsed: elapsed)
                download = Double(received) / elapsed * 8
                upload = Double(sent) / elapsed * 8
                download = max(0, download)
                upload = max(0, upload)
                aggregateDownload += download
                aggregateUpload += upload

                let total = session[name] ?? Counter(received: 0, sent: 0)
                session[name] = Counter(received: total.received + received, sent: total.sent + sent)
            }

            let accumulated = session[name] ?? Counter(received: 0, sent: 0)
            sessionIn += Double(accumulated.received)
            sessionOut += Double(accumulated.sent)

            interfaces.append(NetworkInterfaceSample(
                name: name,
                downloadBps: download,
                uploadBps: upload,
                sessionInBytes: Double(accumulated.received),
                sessionOutBytes: Double(accumulated.sent),
                isActive: download > 8_000 || upload > 8_000
            ))
        }

        previous = reading.counters
        previousIs64Bit = reading.is64Bit
        lastSampleTime = now

        snapshot.downloadBps = aggregateDownload
        snapshot.uploadBps = aggregateUpload
        snapshot.interfaces = interfaces
        snapshot.sessionInBytes = sessionIn
        snapshot.sessionOutBytes = sessionOut
        lastSnapshot = snapshot

        return snapshot
    }

    private func delta(current: UInt64, previous: UInt64, is64Bit: Bool, elapsed: TimeInterval) -> UInt64 {
        if current >= previous { return current - previous }
        // 64-bit counters do not roll over in practice (~18 EB); a drop means
        // the interface reset its counters (e.g. Wi-Fi reconnect or wake).
        guard !is64Bit else { return 0 }
        // 32-bit fallback rollover: reject interface resets by verifying the
        // wrapped delta stays below a 10 Gbps ceiling for this sample window.
        let wrap: UInt64 = 1 << 32
        guard previous < wrap else { return 0 }
        let wrapped = (wrap - previous) + current
        let maxPlausibleBytes = elapsed * (10_000_000_000.0 / 8.0)
        return Double(wrapped) <= maxPlausibleBytes ? wrapped : 0
    }

    private static func monotonicSeconds() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
    }

    private static func collectCounters() -> CounterReading {
        if let counters64 = collectCounters64() {
            return CounterReading(counters: counters64, is64Bit: true)
        }
        return CounterReading(counters: collectCounters32(), is64Bit: false)
    }

    private static func collectCounters64() -> [String: Counter]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var buffer: [UInt8] = []
        var length = 0

        for _ in 0..<2 {
            length = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else {
                return nil
            }
            var capacity = length + 512
            buffer = [UInt8](repeating: 0, count: capacity)
            if sysctl(&mib, UInt32(mib.count), &buffer, &capacity, nil, 0) == 0 {
                length = capacity
                break
            }
            if errno != ENOMEM { return nil }
            length = 0
        }
        guard length > 0 else { return nil }

        var result: [String: Counter] = [:]
        // Routing messages in NET_RT_IFLIST2 mix RTM_IFINFO2 (if_msghdr2),
        // RTM_NEWADDR (ifa_msghdr), and RTM_NEWMADDR2 (ifma_msghdr2). They
        // share only the 4-byte prefix: [msglen: UInt16, version: UInt8, type: UInt8].
        let commonHeaderSize = 4
        let hdr2Size = MemoryLayout<if_msghdr2>.size
        let sdlSize = MemoryLayout<sockaddr_dl>.size
        guard let sdlDataOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data) else { return nil }

        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + commonHeaderSize <= length {
                let msgLen = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                let msgType = Int32(raw.loadUnaligned(fromByteOffset: offset + 3, as: UInt8.self))
                guard msgLen >= commonHeaderSize, offset + msgLen <= length else { break }

                if msgType == RTM_IFINFO2, msgLen >= hdr2Size + sdlSize {
                    let hdr2 = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    let sdlOffset = offset + hdr2Size
                    let sdl = raw.loadUnaligned(fromByteOffset: sdlOffset, as: sockaddr_dl.self)
                    let nameLen = Int(sdl.sdl_nlen)
                    let nameStart = sdlOffset + sdlDataOffset
                    if sdl.sdl_family == UInt8(AF_LINK),
                       nameLen > 0,
                       nameStart + nameLen <= offset + msgLen {
                        let nameSlice = UnsafeRawBufferPointer(rebasing: raw[nameStart..<(nameStart + nameLen)])
                        let name = String(decoding: nameSlice, as: UTF8.self)
                        let counter = Counter(received: hdr2.ifm_data.ifi_ibytes,
                                              sent: hdr2.ifm_data.ifi_obytes)
                        if let existing = result[name] {
                            result[name] = Counter(received: max(existing.received, counter.received),
                                                   sent: max(existing.sent, counter.sent))
                        } else {
                            result[name] = counter
                        }
                    }
                }
                offset += msgLen
            }
        }
        return result.isEmpty ? nil : result
    }

    private static func collectCounters32() -> [String: Counter] {
        var result: [String: Counter] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return result }
        defer { freeifaddrs(first) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = pointer {
            defer { pointer = entry.pointee.ifa_next }

            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_LINK),
                  let data = entry.pointee.ifa_data else { continue }

            let name = String(cString: entry.pointee.ifa_name)
            let link = UnsafeRawPointer(data).assumingMemoryBound(to: if_data.self)
            let counter = Counter(received: UInt64(link.pointee.ifi_ibytes),
                                  sent: UInt64(link.pointee.ifi_obytes))

            if let existing = result[name] {
                result[name] = Counter(received: max(existing.received, counter.received),
                                       sent: max(existing.sent, counter.sent))
            } else {
                result[name] = counter
            }
        }
        return result
    }

    // MARK: - Default route

    /// The interface holding the primary IPv4 configuration, e.g. `en0`.
    static func primaryInterfaceName() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "GlassMonitor.Network" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let primary = value["PrimaryInterface"] as? String, !primary.isEmpty
        else { return nil }
        return primary
    }
}
