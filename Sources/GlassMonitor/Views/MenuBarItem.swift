import SwiftUI
import Core

/// One toggleable readout in the menu bar. Any combination can be active at
/// once; readouts of the same domain share one glyph and sit side by side,
/// told apart by their unit (°C vs %), so the label never jumps around.
enum MenuBarItem: String, CaseIterable, Identifiable {
    case cpuTemp
    case gpuTemp
    case cpuLoad
    case gpuLoad
    case memory
    case net

    var id: String { rawValue }

    /// The hardware domain a readout belongs to; one glyph per domain.
    enum Domain: CaseIterable {
        case cpu, gpu, memory, net

        var symbol: String {
            switch self {
            case .cpu: "cpu"
            case .gpu: "display"
            case .memory: "memorychip"
            case .net: "network"
            }
        }
    }

    var domain: Domain {
        switch self {
        case .cpuTemp, .cpuLoad: .cpu
        case .gpuTemp, .gpuLoad: .gpu
        case .memory: .memory
        case .net: .net
        }
    }

    var title: String {
        switch self {
        case .cpuTemp: L10n.t("menubar.cpuTemp")
        case .gpuTemp: L10n.t("menubar.gpuTemp")
        case .cpuLoad: L10n.t("menubar.cpuLoad")
        case .gpuLoad: L10n.t("menubar.gpuLoad")
        case .memory: L10n.t("menubar.memory")
        case .net: L10n.t("menubar.net")
        }
    }

    /// Fixed-character tokens so the status item never changes width as values
    /// move — a jittering menu bar pushes every neighbouring icon around.
    /// Returns nil for a metric the hardware does not publish, so the caller can
    /// omit the readout instead of showing a fabricated zero.
    func text(_ snapshot: SystemSnapshot) -> String? {
        switch self {
        case .cpuTemp:
            return Self.degrees(snapshot.cpu.temperatureC)
        case .gpuTemp:
            return Self.degrees(snapshot.gpu.temperatureC)
        case .cpuLoad:
            return String(format: "%3.0f%%", snapshot.cpu.totalUsage)
        case .gpuLoad:
            guard let utilization = snapshot.gpu.utilization else { return nil }
            return String(format: "%3.0f%%", utilization)
        case .memory:
            return String(format: "%3.0f%%", snapshot.memory.pressurePercent)
        case .net:
            return "↓ \(Self.rate(snapshot.network.downloadBps)) ↑ \(Self.rate(snapshot.network.uploadBps))"
        }
    }

    /// Same one-decimal precision as the cards, padded to a stable width.
    private static func degrees(_ value: Double?) -> String {
        guard let value else { return "  -- °C" }
        return String(format: "%4.1f °C", value)
    }

    /// Bit/s at 1000-based units, the same `Num.fixedRate` the network card
    /// uses — a byte/binary rendering here made the two readouts differ by 8x.
    private static func rate(_ bytesPerSecond: Double) -> String {
        let rate = Num.fixedRate(bytesPerSecond)
        return "\(rate.value) \(rate.unit)"
    }
}
