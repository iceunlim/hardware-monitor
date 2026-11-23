import Foundation

/// Discovers and reads every plausible temperature channel in the SMC.
///
/// Sensor keys differ wildly between chipsets and super-IO chips, and on a
/// Hackintosh the set is defined by whatever SMCSuperIO/SMCRadeonSensors
/// plug-in is loaded. Rather than hard-coding, the whole key space is scanned
/// once at startup and the numeric `T*` keys are labelled against Intel's
/// naming convention.
public final class TemperatureReader {
    private let smc = SMCClient.shared
    private var keys: [(key: String, label: String, group: TemperatureSample.Group, rank: Int)] = []
    private var didDiscover = false

    public init() {}

    public func read() -> [TemperatureSample] {
        if !didDiscover {
            keys = discover()
            didDiscover = true
        }

        var seen = Set<String>()
        var samples: [TemperatureSample] = []
        for entry in keys {
            guard let value = smc.read(entry.key)?.number, value >= 3, value <= 130 else { continue }
            // Duplicate encodings of the same domain (TC0C/TC0c) collapse together.
            let identity = "\(entry.group)-\(entry.label)"
            guard !seen.contains(identity) else { continue }
            seen.insert(identity)
            samples.append(TemperatureSample(key: entry.key, label: entry.label,
                                            group: entry.group, celsius: value))
        }
        return samples
    }

    /// The channel monitoring apps quote as "the CPU temperature".
    public var cpuTemperature: Double? {
        read().first { $0.group == .cpu }?.celsius
    }

    public var gpuTemperature: Double? {
        read().first { $0.group == .gpu }?.celsius
    }

    private func discover() -> [(key: String, label: String, group: TemperatureSample.Group, rank: Int)] {
        let count = smc.keyCount
        guard count > 0, count < 4096 else { return [] }

        var results: [(key: String, label: String, group: TemperatureSample.Group, rank: Int)] = []

        for index in 0..<count {
            guard let key = smc.key(at: index), key.hasPrefix("T") else { continue }
            guard let (size, type) = smc.info(for: key), size <= 4 else { continue }
            guard type == "sp78" || type == "flt " else { continue }

            guard let value = smc.read(key)?.number, value >= 8, value <= 120 else { continue }
            let (label, group, rank) = Self.classify(key)
            results.append((key: key, label: label, group: group, rank: rank))
        }

        // Headline channel first inside each group, the rest as detail.
        return results.sorted { lhs, rhs in
            if lhs.group != rhs.group {
                return Self.priority(lhs.group) < Self.priority(rhs.group)
            }
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.key < rhs.key
        }
    }

    private static func priority(_ group: TemperatureSample.Group) -> Int {
        switch group {
        case .cpu: return 0
        case .gpu: return 1
        case .drive: return 2
        case .memory: return 3
        case .board: return 4
        case .other: return 5
        }
    }

    /// Rank 0 marks the channel worth showing on its own; higher ranks are
    /// filtered detail. The documented meanings come from Intel's SMC key
    /// database (`TG0D` is the GPU die, `TG0P` the proximity sensor, and so on),
    /// which is what SMCSuperIO and SMCRadeonSensors follow when naming keys.
    static func classify(_ key: String) -> (label: String, group: TemperatureSample.Group, rank: Int) {
        // Intel publishes each channel twice: upper-case is the filtered value
        // used for fan control, lower-case the raw reading. Both mean the same
        // sensor, so they share a label and collapse in `read()`.
        let canonical = key.uppercased()
        switch canonical {
        case "TC0P": return (String(localized: "temp.cpu.package", defaultValue: "CPU Package"), .cpu, 0)
        case "TC0D", "TC0E", "TC0F", "TC0H": return (String(localized: "temp.cpu.core", defaultValue: "CPU Core"), .cpu, 1)
        case "TCXC": return (String(localized: "temp.cpu.hotspot", defaultValue: "CPU Hotspot"), .cpu, 1)
        case "TCAD", "TC0A": return (String(localized: "temp.cpu.aux", defaultValue: "CPU Aux"), .cpu, 3)
        case "TG0D", "TGDD", "TG0C": return (String(localized: "temp.gpu.core", defaultValue: "GPU Core"), .gpu, 0)
        case "TG0P": return (String(localized: "temp.gpu.proximity", defaultValue: "GPU Proximity"), .gpu, 1)
        case "TG0M", "TG0R", "TG0V": return (String(localized: "temp.gpu.vram", defaultValue: "GPU VRAM"), .gpu, 1)
        case "TG0H": return (String(localized: "temp.gpu.heatpipe", defaultValue: "GPU Heatpipe"), .gpu, 3)
        case "TA2P", "TAMB", "TA0P": return (String(localized: "temp.ambient", defaultValue: "Ambient"), .board, 0)
        case "TN0P", "TN0D": return (String(localized: "temp.northbridge", defaultValue: "Northbridge"), .board, 0)
        case "TS0D", "TS0P": return (String(localized: "temp.southbridge", defaultValue: "Southbridge"), .board, 0)
        case "TPSP", "TP0P", "TCSP": return ("PCH", .board, 2)
        case "TM0P", "TM0S": return (String(localized: "temp.memory", defaultValue: "Memory"), .memory, 0)
        case "TB0T", "TB0S": return (String(localized: "temp.battery", defaultValue: "Battery"), .board, 3)
        case "TW0P": return (String(localized: "temp.wireless", defaultValue: "Wireless"), .board, 3)
        default: break
        }

        // `TC0C`…`TC8C` are per-core channels on Intel desktop SMCs.
        if canonical.count == 4, canonical.hasPrefix("TC"), canonical.hasSuffix("C"),
           let core = Int(canonical.dropFirst(2).dropLast()) {
            return (String(format: String(localized: "temp.core", defaultValue: "Core %ld"), core + 1), .cpu, 2)
        }

        guard canonical.count >= 2 else { return (key, .other, 4) }
        let domain = canonical[canonical.index(after: canonical.startIndex)]
        let suffix = canonical.dropFirst(2)
        switch domain {
        case "C": return (String(format: String(localized: "temp.cpu.channel", defaultValue: "CPU %@"), String(suffix)), .cpu, 2)
        case "G": return (String(format: String(localized: "temp.gpu.channel", defaultValue: "GPU %@"), String(suffix)), .gpu, 2)
        case "H": return (String(format: String(localized: "temp.drive", defaultValue: "Drive %@"), String(suffix)), .drive, 0)
        case "M": return (String(format: String(localized: "temp.memory.channel", defaultValue: "Memory %@"), String(suffix)), .memory, 0)
        case "N": return (String(localized: "temp.northbridge", defaultValue: "Northbridge"), .board, 2)
        case "S": return (String(localized: "temp.southbridge", defaultValue: "Southbridge"), .board, 2)
        case "P": return ("PCH", .board, 3)
        case "A": return (String(localized: "temp.ambient", defaultValue: "Ambient"), .board, 2)
        case "V": return (String(localized: "temp.powerStage", defaultValue: "Power Stage"), .board, 3)
        case "B": return (String(localized: "temp.battery", defaultValue: "Battery"), .board, 3)
        case "W": return (String(localized: "temp.wireless", defaultValue: "Wireless"), .board, 3)
        case "Y": return (String(localized: "temp.driveBay", defaultValue: "Drive Bay"), .board, 3)
        default: return (key, .other, 4)
        }
    }
}
