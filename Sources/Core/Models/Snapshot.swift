import Foundation

// MARK: - Sampled values

/// One logical core's utilisation over a single sampling interval.
public struct CoreLoad: Identifiable {
    public let id: Int
    public var usage: Double
    public var user: Double
    public var system: Double
}

public struct CPUSnapshot {
    public var totalUsage: Double = 0
    public var user: Double = 0
    public var system: Double = 0
    public var idle: Double = 0
    public var cores: [CoreLoad] = []
    public var logicalCount: Int = 0
    public var physicalCount: Int = 0
    public var loadAverage: [Double] = []
    public var frequencyGHz: Double?
    /// Highest turbo ratio the firmware P-state table declares, in GHz.
    public var turboGHz: Double?
    public var temperatureC: Double?
    public var packagePowerW: Double?

    public init() {}
}

public struct GPUSnapshot: Identifiable {
    /// Registry entry ID of the device, stable for one boot. macOS assigns a
    /// new one after a reboot, so it must never be persisted.
    public var id: String = "gpu"
    public var name: String = "GPU"
    public var vendor: String?
    public var utilization: Double?
    public var memoryUtilization: Double?
    public var temperatureC: Double?
    public var fanPercent: Double?
    public var fanRPM: Double?
    public var powerW: Double?
    public var coreClockMHz: Double?
    public var memoryClockMHz: Double?
    public var vramTotalBytes: Double?
    public var vramUsedBytes: Double?
    public var vramCachedBytes: Double?
    public var vramFreeBytes: Double?
    /// 核显从系统内存里映射给 GPU 的字节数（GART 已用）；独显不使用此字段。
    public var sharedMemoryBytes: Double?
    public var isSupported = false
    /// 集成显卡（Intel / Apple GPU）。它没有独立风扇，macOS 也不为它发布
    /// 独立功耗与频率通道，面板据此只展示确实存在的指标。
    public var isIntegrated = false

    public init() {}

    public var displayName: String {
        if let vendor, !name.hasPrefix(vendor) { return "\(vendor) \(name)" }
        return name
    }
}

public struct MemorySnapshot {
    public var totalBytes: Double = 0
    public var usedBytes: Double = 0
    public var appBytes: Double = 0
    public var wiredBytes: Double = 0
    public var compressedBytes: Double = 0
    public var cachedBytes: Double = 0
    public var freeBytes: Double = 0
    public var swapTotalBytes: Double = 0
    public var swapUsedBytes: Double = 0
    public var pressurePercent: Double = 0

    public init() {}
}

public struct NetworkInterfaceSample {
    public var name: String
    public var downloadBps: Double
    public var uploadBps: Double
    /// Bytes moved since the app started, summed from wrap-corrected deltas.
    public var sessionInBytes: Double
    public var sessionOutBytes: Double
    public var isActive: Bool

    public init(name: String, downloadBps: Double, uploadBps: Double,
                sessionInBytes: Double, sessionOutBytes: Double, isActive: Bool) {
        self.name = name
        self.downloadBps = downloadBps
        self.uploadBps = uploadBps
        self.sessionInBytes = sessionInBytes
        self.sessionOutBytes = sessionOutBytes
        self.isActive = isActive
    }
}

public struct NetworkSnapshot {
    public var downloadBps: Double = 0
    public var uploadBps: Double = 0
    public var sessionInBytes: Double = 0
    public var sessionOutBytes: Double = 0
    public var interfaces: [NetworkInterfaceSample] = []
    public var activeInterface: String?

    public init() {}
}

public struct FanSample: Identifiable {
    public let id = UUID()
    public var index: Int
    public var name: String
    /// Firmware channel key (`CPUFAN`, `SYSFAN`, `F0Ac`, …) when known.
    public var channel: String
    public var currentRPM: Double?
    public var minRPM: Double?
    public var maxRPM: Double?
    public var targetRPM: Double?

    public init(index: Int, name: String, channel: String = "", currentRPM: Double?,
                minRPM: Double?, maxRPM: Double?, targetRPM: Double?) {
        self.index = index
        self.name = name
        self.channel = channel
        self.currentRPM = currentRPM
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.targetRPM = targetRPM
    }

    /// Utilisation against the tachometer's declared ceiling, which is only
    /// published by some super-IO plug-ins.
    public var percent: Double? {
        guard let currentRPM, let maxRPM, maxRPM > 0 else { return nil }
        return min(100, max(0, currentRPM / maxRPM * 100))
    }
}

/// A named temperature channel, grouped so the UI can show one number per domain.
public struct TemperatureSample: Identifiable {
    public let id = UUID()
    public var key: String
    public var label: String
    public var group: Group
    public var celsius: Double

    public init(key: String, label: String, group: Group, celsius: Double) {
        self.key = key
        self.label = label
        self.group = group
        self.celsius = celsius
    }

    public enum Group: String, CaseIterable {
        case cpu = "CPU"
        case gpu = "GPU"
        case board = "Board"
        case memory = "Memory"
        case drive = "Drive"
        case other = "Other"
    }
}

// MARK: - Aggregate

/// Everything one UI tick needs. History lives per-metric so the sparklines do
/// not have to retain whole snapshots.
public struct SystemSnapshot {
    public var date = Date()
    public var cpu = CPUSnapshot()
    /// Every independent accelerator, discrete first. `gpu` mirrors the head
    /// of this list and is what the menu bar reports.
    public var gpus: [GPUSnapshot] = []
    public var gpu = GPUSnapshot()
    public var memory = MemorySnapshot()
    public var network = NetworkSnapshot()
    public var fans: [FanSample] = []
    public var temperatures: [TemperatureSample] = []

    public init() {}

    public var cpuTemperature: Double? {
        temperatures.first { $0.group == .cpu }?.celsius ?? cpu.temperatureC
    }

    public var gpuTemperature: Double? {
        gpu.temperatureC ?? temperatures.first { $0.group == .gpu }?.celsius
    }

    /// Extra GPU channels — hotspot and memory junctions — which only appear
    /// once SMCRadeonSensors is injected.
    public var gpuTemperatures: [TemperatureSample] {
        temperatures.filter { $0.group == .gpu }
    }

    public var hottest: Double? {
        temperatures.map(\.celsius).max()
    }

    /// 自动判断的 CPU 风扇：先认固件的 `CPUFAN` 通道（即使读数为 0），再认
    /// 一体水冷的 `PUMP` 通道，两者都不存在时才退回转速最高的在转风扇。
    /// 主板把散热器接在别的通道时，用户可在设置里手动指定；这里不擅自把
    /// 别的通道当成 CPU 风扇，以免掩盖 CPU 风扇停转。
    public var coolerFan: FanSample? {
        fans.first { $0.channel == "CPUFAN" }
            ?? fans.first { $0.channel.uppercased().contains("PUMP") }
            ?? fans.filter { ($0.currentRPM ?? 0) > 0 }
                .max(by: { ($0.currentRPM ?? 0) < ($1.currentRPM ?? 0) })
            ?? fans.first
    }

    /// 用户在设置里指定了通道就用它；该通道本次启动中不存在时回退到自动。
    public func coolingFan(preferring channel: String?) -> FanSample? {
        if let channel, let selected = fans.first(where: { $0.channel == channel }) {
            return selected
        }
        return coolerFan
    }
}
