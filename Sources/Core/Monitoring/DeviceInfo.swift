import Foundation
import IOKit
import IOKit.kext

/// Static machine identity, resolved once at launch.
public struct DeviceInfo {
    public static let shared = DeviceInfo()

    public let cpuBrand: String
    public let logicalCores: Int
    public let physicalCores: Int
    public let memoryBytes: Double
    public let macModel: String
    public let osVersion: String
    public let isHackintosh: Bool
    /// 内核记录的启动时间。`ProcessInfo.systemUptime` 在睡眠期间不前进，
    /// 用墙钟差值才对得上用户理解的“已运行”。
    public let bootDate: Date?

    private init() {
        cpuBrand = CPUSampler.stringSysctl("machdep.cpu.brand_string") ?? "Unknown CPU"
        logicalCores = CPUSampler.intSysctl("hw.logicalcpu") ?? 0
        physicalCores = CPUSampler.intSysctl("hw.physicalcpu") ?? 0
        memoryBytes = Double(CPUSampler.intSysctl("hw.memsize") ?? 0)
        macModel = CPUSampler.stringSysctl("hw.model") ?? "Mac"
        osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        isHackintosh = Self.detectHackintosh()
        bootDate = Self.readBootDate()
    }

    /// 系统版本号本体，例如 `26.7.3`；`osVersion` 还带着构建号。
    public var shortOSVersion: String {
        osVersion
            .replacingOccurrences(of: "Version ", with: "")
            .components(separatedBy: " (")
            .first ?? osVersion
    }

    /// 自启动到现在经过的时间（含睡眠）。
    public var uptime: TimeInterval? {
        bootDate.map { Date().timeIntervalSince($0) }
    }

    private static func readBootDate() -> Date? {
        var value = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0, value.tv_sec > 0
        else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(value.tv_sec)
                    + TimeInterval(value.tv_usec) / 1_000_000)
    }

    /// `hw.model` is spoofed on nearly every Hackintosh, so the SMBIOS identity
    /// proves nothing. VirtualSMC, Lilu and WhateverGreen, however, only exist
    /// on one.
    private static func detectHackintosh() -> Bool {
        let markers = ["as.vit9696.VirtualSMC", "as.vit9696.Lilu", "as.vit9696.WhateverGreen",
                       "org.netke.io.kext.FakeSMC"]
        let loaded = KextManagerCopyLoadedKextInfo(nil, nil)?.takeRetainedValue() as? [String: Any] ?? [:]
        if markers.contains(where: { loaded[$0] != nil }) { return true }

        let chosen = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/chosen")
        guard chosen != 0 else { return false }
        defer { IOObjectRelease(chosen) }
        guard let booter = IORegistryEntryCreateCFProperty(chosen, "booter-name" as CFString,
                                                           kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Data,
              let name = String(data: booter, encoding: .ascii)?.trimmingCharacters(in: .controlCharacters)
        else { return false }
        return name.contains("OpenCore") || name.contains("Clover")
    }

    public var shortCPUName: String {
        cpuBrand
            .replacingOccurrences(of: "Intel(R) ", with: "")
            .replacingOccurrences(of: "Intel(R) Core(TM) ", with: "")
            .replacingOccurrences(of: "Core(TM) ", with: "")
            .replacingOccurrences(of: "(R)", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Formatting

public enum ByteFormat {
    /// Human readable byte count, decimal-ish like Activity Monitor.
    public static func string(_ bytes: Double, perSecond: Bool = false) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = max(0, bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        let suffix = perSecond ? "/s" : ""
        if index == 0 { return "\(Int(value)) \(units[index])\(suffix)" }
        return String(format: "%.1f %@%@", value, units[index], suffix)
    }

    /// Bit rate, the way network tools conventionally show it.
    public static func bitsPerSecond(_ bps: Double) -> String {
        let units = ["bps", "Kbps", "Mbps", "Gbps"]
        var value = max(0, bps)
        var index = 0
        while value >= 1000, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        if index == 0 { return "\(Int(value)) bps" }
        return String(format: "%.1f %@", value, units[index])
    }
}
