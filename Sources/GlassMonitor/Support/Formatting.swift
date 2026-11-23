import Foundation
import Core

enum Num {
    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value >= 99.95 ? "100" : String(format: "%.0f", value)
    }

    static func celsius(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f °C", value)
    }

    static func watts(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value > 0, value < 10 { return String(format: "%.1f W", value) }
        return String(format: "%.0f W", value)
    }

    static func megahertz(_ value: Double?) -> String {
        guard let value, value > 0 else { return "—" }
        return "\(Int(value.rounded())) MHz"
    }

    static func gigahertz(_ value: Double?) -> String {
        guard let value, value > 0 else { return "—" }
        return String(format: "%.2f GHz", value)
    }

    /// 开机时长，按中文习惯保留最大两个单位。
    static func uptime(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds >= 60 else { return L10n.t("header.uptime.justStarted") }
        let total = Int(seconds)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return L10n.format("header.uptime.daysHours", days, hours) }
        if hours > 0 { return L10n.format("header.uptime.hoursMinutes", hours, minutes) }
        return L10n.format("header.uptime.minutes", minutes)
    }

    /// Base clock, plus the firmware turbo ceiling when one is declared —
    /// e.g. `3.70~4.70 GHz`. Without a ceiling only the base clock is shown;
    /// with neither (Apple Silicon) the caller hides the label entirely.
    static func frequencyRange(base: Double?, ceiling: Double?) -> String {
        guard let base, base > 0 else {
            guard let ceiling, ceiling > 0 else { return "" }
            return gigahertz(ceiling)
        }
        if let ceiling, ceiling > base + 0.05 {
            return String(format: "%.2f~%.2f GHz", base, ceiling)
        }
        return String(format: "%.2f GHz", base)
    }

    static func degrees(_ value: Double?) -> String {
        guard let value else { return "--°" }
        return String(format: "%.0f°", value)
    }

    /// Bit/s in 1000-based units, shared by the card (full unit) and the menu
    /// bar (single-letter unit) so both always derive from the same ladder.
    static func bitRate(_ bytesPerSecond: Double) -> (value: Double, unit: String) {
        let bits = max(0, bytesPerSecond) * 8
        let ladder: [(scale: Double, unit: String)] = [(1e9, "Gbps"), (1e6, "Mbps"), (1e3, "Kbps")]
        var index = ladder.count - 1
        for (candidate, entry) in ladder.enumerated() where bits >= entry.scale {
            index = candidate
            break
        }
        var scaled = bits / ladder[index].scale
        // 999.5 起再格式化就会进位成四位数，固定宽度会破；提前升一档。
        if scaled >= 999.5, index > 0 {
            index -= 1
            scaled = bits / ladder[index].scale
        }
        return (scaled, ladder[index].unit)
    }

    /// Fixed-shape bit rate: five characters of value plus a four-letter unit,
    /// used by the network card where there is room for `Mbps`.
    static func fixedRate(_ bytesPerSecond: Double) -> (value: String, unit: String) {
        let rate = bitRate(bytesPerSecond)
        return (String(format: "%5.1f", rate.value), rate.unit)
    }

    /// Fixed-shape byte total: six characters of value plus a two-letter unit.
    static func fixedBytes(_ bytes: Double) -> (value: String, unit: String) {
        let units = ["KB", "MB", "GB", "TB"]
        var value = max(0, bytes) / 1024
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return (String(format: "%6.1f", value), units[index])
    }
}
