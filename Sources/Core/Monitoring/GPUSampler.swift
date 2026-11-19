import Foundation
import IOKit

/// GPU telemetry read straight out of the IORegistry.
///
/// Apple's accelerator drivers publish a `PerformanceStatistics` dictionary on
/// every `IOAccelerator` — utilisation, temperature, power, clocks and VRAM
/// counters — which is readable without root. That covers Intel, AMD and
/// Apple Silicon GPUs, including the `AMDRadeonX6000` driver most
/// Hackintoshes rely on, so no `powermetrics` helper or privileged listener is
/// needed.
///
/// Each accelerator belongs to exactly one physical GPU, and a machine can
/// expose several (an iGPU next to a dGPU). Readings are therefore taken per
/// device and never merged; the panel lets the user pick which GPU a card
/// shows, one at a time.
public final class GPUSampler {
    public init() {}

    /// All detected GPUs, discrete first, so index 0 is the sensible default.
    public func readAll() -> [GPUSnapshot] {
        let devices = Self.devices()
        guard !devices.isEmpty else {
            var snapshot = GPUSnapshot()
            snapshot.name = Self.fallbackName
            snapshot.vendor = Self.fallbackVendor
            snapshot.isIntegrated = Self.isIntegrated(vendor: Self.fallbackVendor)
            return [snapshot]
        }
        return devices.sorted {
            let left = Self.priority($0), right = Self.priority($1)
            return left == right ? $0.id < $1.id : left > right
        }
    }

    public func read() -> GPUSnapshot {
        readAll().first ?? GPUSnapshot()
    }

    // MARK: - Per-device sampling

    private static func devices() -> [GPUSnapshot] {
        var result: [GPUSnapshot] = []
        var iterator: io_iterator_t = 0

        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iterator) == kIOReturnSuccess else { return result }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }

            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == kIOReturnSuccess,
                  let dictionary = properties?.takeRetainedValue() as? [String: Any],
                  let statistics = dictionary["PerformanceStatistics"] as? [String: Any]
            else { continue }

            var snapshot = GPUSnapshot()
            let identity = deviceIdentity(for: service)
            snapshot.id = identity.id
            snapshot.name = identity.name
            snapshot.vendor = identity.vendor
            snapshot.isIntegrated = Self.isIntegrated(vendor: identity.vendor)

            snapshot.utilization = number(statistics["Device Utilization %"])
                ?? number(statistics["GPU Activity(%)"])
            snapshot.temperatureC = number(statistics["Temperature(C)"])
            snapshot.powerW = number(statistics["Total Power(W)"])
            snapshot.coreClockMHz = number(statistics["Core Clock(MHz)"])
            snapshot.memoryClockMHz = number(statistics["Memory Clock(MHz)"])
            // >= 0: the keys stay published at zero-RPM idle, and their presence
            // is what proves the fan is populated.
            snapshot.fanPercent = number(statistics["Fan Speed(%)"]).flatMap { $0 >= 0 ? $0 : nil }
            snapshot.fanRPM = number(statistics["Fan Speed(RPM)"]).flatMap { $0 >= 0 ? $0 : nil }

            let used = number(statistics["inUseVidMemoryBytes"]) ?? 0
            let cached = number(statistics["orphanedReusableVidMemoryBytes"]) ?? 0
            let free = number(statistics["vramFreeBytes"]) ?? 0
            if used > 0 || free > 0 {
                snapshot.vramUsedBytes = used
                snapshot.vramCachedBytes = cached
                snapshot.vramFreeBytes = free
                snapshot.vramTotalBytes = used + cached + free
                snapshot.memoryUtilization = used / (used + cached + free) * 100
            }

            if snapshot.isIntegrated {
                // 核显没有独立 VRAM，但会从系统内存映射共享区域。inUseSysMemoryBytes
                // 偶尔下溢成天文数字（睡眠唤醒后见过），超出 GART 容量时丢弃，
                // 退回到始终自洽的 GART 已用量。
                let limit = number(statistics["gartSizeBytes"]) ?? 1e12
                let inUse = number(statistics["inUseSysMemoryBytes"]).flatMap {
                    $0 >= 0 && $0 <= limit ? $0 : nil
                }
                snapshot.sharedMemoryBytes = inUse ?? number(statistics["gartUsedBytes"])
            }

            snapshot.isSupported = true
            result.append(snapshot)
        }
        return result
    }

    /// Discrete GPUs beat integrated ones, then breadth of telemetry breaks
    /// ties, so an enabled iGPU never displaces the card that is actually
    /// driving the display.
    private static func priority(_ gpu: GPUSnapshot) -> Int {
        var score = gpu.isIntegrated ? 0 : 2
        if gpu.temperatureC != nil { score += 1 }
        if gpu.fanRPM != nil { score += 1 }
        if gpu.vramTotalBytes != nil { score += 1 }
        return score
    }

    /// Mac 上的 Intel / Apple GPU 都是核显：无独立风扇，也不发布独立功耗与
    /// 频率通道。Apple Silicon 的 AGX 加速器没有 PCI 厂商属性，只能按 CPU
    /// 架构判断。
    private static let isAppleSilicon = CPUSampler.intSysctl("hw.optional.arm64") == 1

    private static func isIntegrated(vendor: String?) -> Bool {
        vendor == "Intel" || vendor == "Apple" || isAppleSilicon
    }

    // MARK: - Naming

    /// The accelerator node itself carries no marketing name; its PCI parent
    /// does. PCI class `03.00.00` marks a display controller. The registry
    /// entry ID of that parent identifies the device across samples.
    private static func deviceIdentity(for service: io_registry_entry_t)
        -> (id: String, name: String, vendor: String?) {
        var serviceID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &serviceID)
        let fallbackID = "gpu-\(serviceID)"

        var entry = service
        IOObjectRetain(entry)
        defer { IOObjectRelease(entry) }

        for _ in 0..<10 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == kIOReturnSuccess,
                  parent != 0 else { return (fallbackID, "GPU", nil) }
            IOObjectRelease(entry)
            entry = parent

            guard let classCode = property(entry, "class-code") as? Data,
                  classCode.count >= 3,
                  // Stored little-endian: prog-if, subclass, then base class 0x03.
                  classCode[2] == 0x03
            else { continue }

            var registryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(entry, &registryID)
            let id = "gpu-\(registryID)"
            let vendor = vendorName(property(entry, "vendor-id"))
            if let string = property(entry, "model") as? String { return (id, string, vendor) }
            if let data = property(entry, "model") as? Data,
               let decoded = String(data: data, encoding: .ascii), !decoded.isEmpty {
                return (id, decoded, vendor)
            }
            return (id, "GPU", vendor)
        }
        return (fallbackID, "GPU", nil)
    }

    private static func vendorName(_ value: Any?) -> String? {
        guard let data = value as? Data, data.count >= 2 else { return nil }
        let id = Int(data.withUnsafeBytes { UInt32($0.loadUnaligned(as: UInt32.self)) & 0xffff })
        switch id {
        case 0x1002: return "AMD"
        case 0x10de: return "NVIDIA"
        case 0x8086: return "Intel"
        case 0x106b: return "Apple"
        default: return String(format: "Vendor 0x%04x", id)
        }
    }

    /// No accelerator at all (driver missing or unsupported GPU): fall back to
    /// the firmware's name on the first display-controller PCI function.
    private static let fallbackInfo: (model: String?, vendor: String?) = {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOPCIDevice"),
                                           &iterator) == kIOReturnSuccess else { return (nil, nil) }
        defer { IOObjectRelease(iterator) }

        var model: String?
        var vendor: String?

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }

            guard let classCode = property(service, "class-code") as? Data,
                  classCode.count >= 3,
                  classCode[2] == 0x03
            else { continue }

            // A function without an injected `model` is an HD-audio endpoint or
            // a spare port on the same card, not the GPU itself.
            guard property(service, "model") != nil else { continue }

            if model == nil {
                if let string = property(service, "model") as? String { model = string }
                else if let data = property(service, "model") as? Data, let decoded = String(data: data, encoding: .ascii) {
                    model = decoded
                }
            }
            if vendor == nil { vendor = vendorName(property(service, "vendor-id")) }
        }
        return (model, vendor)
    }()

    private static var fallbackName: String { fallbackInfo.model ?? "GPU" }
    private static var fallbackVendor: String? { fallbackInfo.vendor }

    private static func property(_ service: io_registry_entry_t, _ name: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, name as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return Double(truncating: number) }
        if let string = value as? String, let parsed = Double(string) { return parsed }
        return nil
    }
}