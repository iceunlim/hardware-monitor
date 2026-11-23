import Foundation
import IOKit

/// Reads fan tachometers, preferring named super-IO channels.
///
/// SMCSuperIO publishes a `Sensors` dictionary in the IORegistry whose keys
/// carry the board's header names (`CPUFAN`, `SYSFAN`, `AUXFAN0`, …) next to
/// live RPM values — names and readings from one source, no guesswork. Plain
/// SMC `F0Ac` tachometers are the fallback for firmware without that plug-in.
public final class FanReader {
    private let smc = SMCClient.shared
    private var cachedFanKeys: [Int] = []
    private var didDiscover = false
    /// Optional per-fan channels, absent on many super-IO plug-ins.
    private let optionalSuffixes = ["Mn", "Mx", "Tg"]
    /// The plug-in node is often `!registered`, so service matching misses it;
    /// locate it once by walking the registry and keep the handle.
    private var superIOEntry: io_registry_entry_t = 0
    private var didSearchSuperIO = false

    public init() {}

    deinit {
        if superIOEntry != 0 { IOObjectRelease(superIOEntry) }
    }

    /// Discovers available fans once, then simply re-reads their tachometers.
    public func read() -> [FanSample] {
        if let named = readSuperIO() { return named }
        if !didDiscover {
            cachedFanKeys = discoverFanIndices()
            didDiscover = true
        }

        return cachedFanKeys.map { index in
            let prefix = "F\(index)"
            let actual = smc.read("\(prefix)Ac")
            var sample = FanSample(index: index,
                                   name: name(for: index),
                                   channel: "\(prefix)Ac",
                                   currentRPM: actual?.fanRPM ?? actual?.number,
                                   minRPM: nil, maxRPM: nil, targetRPM: nil)

            for suffix in optionalSuffixes {
                let value = smc.read("\(prefix)\(suffix)")
                let rpm = value?.fanRPM ?? value?.number
                switch suffix {
                case "Mn": sample.minRPM = rpm
                case "Mx": sample.maxRPM = rpm
                case "Tg": sample.targetRPM = rpm
                default: break
                }
            }
            return sample
        }
    }

    /// Whether this machine publishes any tachometer at all.
    public var hasFans: Bool {
        if !didDiscover { cachedFanKeys = discoverFanIndices(); didDiscover = true }
        return !cachedFanKeys.isEmpty
    }

    private func discoverFanIndices() -> [Int] {
        // Fast path: the declared fan count.
        if let declared = smc.readNumber("FNum"), declared > 0, declared < 32 {
            let candidates = Set(0..<Int(declared))
            let present = candidates.filter { smc.info(for: "F\($0)Ac") != nil }
            if !present.isEmpty { return present.sorted() }
        }

        // Slow path: some firmware lies about `FNum`, so scan the key space.
        let count = smc.keyCount
        guard count > 0, count < 4096 else { return [] }
        var indices: Set<Int> = []
        for index in 0..<count {
            guard let key = smc.key(at: index) else { continue }
            guard key.last == "c", key.hasPrefix("F"), key.hasSuffix("Ac") else { continue }
            let digits = key.dropFirst().dropLast(2)
            if let value = Int(digits), value >= 0, value < 32 { indices.insert(value) }
        }
        return indices.sorted()
    }

    private func name(for index: Int) -> String {
        if let labeled = smc.read("F\(index)ID")?.text { return labeled }
        return String(format: String(localized: "fan.numbered", defaultValue: "Fan %ld"), index + 1)
    }

    private func readSuperIO() -> [FanSample]? {
        if !didSearchSuperIO {
            didSearchSuperIO = true
            superIOEntry = Self.findSuperIO()
        }
        guard superIOEntry != 0 else { return nil }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(superIOEntry, &properties, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let dictionary = properties?.takeRetainedValue() as? [String: Any],
              let sensors = dictionary["Sensors"] as? [String: Any]
        else { return nil }

        let keys = sensors.keys.filter { $0.contains("FAN") }.sorted()
        guard !keys.isEmpty else { return nil }
        return keys.enumerated().map { index, key in
            FanSample(index: index,
                      name: Self.label(for: key),
                      channel: key,
                      currentRPM: (sensors[key] as? NSNumber)?.doubleValue,
                      minRPM: nil, maxRPM: nil, targetRPM: nil)
        }
    }

    private static func findSuperIO() -> io_registry_entry_t {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return 0 }
        defer { IOObjectRelease(root) }
        return search(root)
    }

    private static func search(_ entry: io_registry_entry_t) -> io_registry_entry_t {
        var name = [CChar](repeating: 0, count: 128)
        if IORegistryEntryGetName(entry, &name) == kIOReturnSuccess,
           String(cString: name) == "SMCSuperIO" {
            IOObjectRetain(entry)
            return entry
        }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == kIOReturnSuccess
        else { return 0 }
        defer { IOObjectRelease(iterator) }
        while case let child = IOIteratorNext(iterator), child != 0 {
            let found = search(child)
            IOObjectRelease(child)
            if found != 0 { return found }
        }
        return 0
    }

    private static func label(for key: String) -> String {
        switch key {
        case "CPUFAN": return String(localized: "fan.cpu", defaultValue: "CPU Fan")
        case "SYSFAN": return String(localized: "fan.system", defaultValue: "System Fan")
        default:
            if key.contains("PUMP") {
                return String(localized: "fan.pump", defaultValue: "Pump")
            }
            if key.hasPrefix("AUXFAN"), let number = Int(key.dropFirst(6)) {
                return String(format: String(localized: "fan.aux", defaultValue: "Aux Fan %ld"), number + 1)
            }
            return key
        }
    }
}
