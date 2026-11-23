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
    func text(_ snapshot: SystemSnapshot) -> String {
        switch self {
        case .cpuTemp:
            return Self.degrees(snapshot.cpu.temperatureC)
        case .gpuTemp:
            return Self.degrees(snapshot.gpu.temperatureC)
        case .cpuLoad:
            return String(format: "%3.0f%%", snapshot.cpu.totalUsage)
        case .gpuLoad:
            return String(format: "%3.0f%%", snapshot.gpu.utilization ?? 0)
        case .memory:
            return String(format: "%3.0f%%", snapshot.memory.pressurePercent)
        case .net:
            return "↓\(Self.rate(snapshot.network.downloadBps)) ↑\(Self.rate(snapshot.network.uploadBps))"
        }
    }

    /// Units keep the same one-space policy as the cards; percentages stay
    /// attached (`35 °C` but `53%`).
    private static func degrees(_ value: Double?) -> String {
        guard let value else { return " -- °C" }
        return String(format: "%3.0f °C", value)
    }

    /// Fixed width: the value and its unit letter. The separator is part of
    /// the token so the status item never jumps as traffic changes.
    private static func rate(_ bytesPerSecond: Double) -> String {
        let units: [(Double, String)] = [(1_073_741_824, "G"), (1_048_576, "M"), (1024, "K")]
        for (scale, suffix) in units where bytesPerSecond >= scale {
            let value = bytesPerSecond / scale
            let body = value >= 9.95 ? String(format: "%3.0f", value) : String(format: "%3.1f", value)
            return body + " " + suffix
        }
        return String(format: "%3.1f K", bytesPerSecond / 1024)
    }
}
