import SwiftUI
import Core

struct CPUCard: View {
    let snapshot: SystemSnapshot
    let history: [Double]
    var tempHistory: [Double] = []
    var showsPerCore: Bool
    /// 设置里指定或自动判断出的 CPU 风扇，由 PanelBody 统一解析后传入。
    let coolerFan: FanSample?

    private var cores: [CoreLoad] { snapshot.cpu.cores }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(title: DeviceInfo.shared.shortCPUName, systemImage: "cpu", tint: Accent.cpu)

            HStack(alignment: .center, spacing: 10) {
                UsageRing(percent: snapshot.cpu.totalUsage, color: Accent.cpu,
                          label: "\(Num.percent(snapshot.cpu.totalUsage))%")
                    .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 3) {
                    MetricRow(label: L10n.t("metric.temperature"), value: Num.celsius(snapshot.cpuTemperature))
                    MetricRow(label: L10n.t("cpu.busiestCore"),
                              value: "\(Num.percent(cores.map(\.usage).max() ?? 0))%")
                    // 无风扇机型（MacBook Air、部分无风扇迷你主机）不占一行 “—”。
                    if coolerFan != nil {
                        MetricRow(label: L10n.t("metric.fan"), value: coolerText)
                    }
                }
                Spacer(minLength: 0)
            }

            if showsPerCore, !cores.isEmpty {
                CoreBars(cores: cores, color: Accent.cpu)
                    .frame(height: 20)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    MiniLegend(color: Accent.cpu,
                               text: L10n.format("legend.usage", "\(Num.percent(snapshot.cpu.totalUsage))%"))
                    MiniLegend(color: Accent.thermal,
                               text: L10n.format("legend.temperature", Num.degrees(snapshot.cpuTemperature)))
                    Spacer(minLength: 4)
                    if !frequencyText.isEmpty {
                        Text(frequencyText)
                            .font(.mono(TypeScale.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                DualSparkline(usage: history, temperature: tempHistory, usageColor: Accent.cpu)
                    .frame(height: 30)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .glassCard(Accent.cpu)
    }

    private var coolerText: String {
        guard let coolerFan else { return "—" }
        let rpm = coolerFan.currentRPM ?? 0
        return rpm > 0 ? "\(Int(rpm.rounded())) RPM" : L10n.t("fan.stopped")
    }

    /// Apple Silicon 不发布基础频率，也没有固件 P-State 表；两个值都缺失时
    /// 留空，而不是在卡片角落固定显示一个 “—”。
    private var frequencyText: String {
        Num.frequencyRange(base: snapshot.cpu.frequencyGHz, ceiling: snapshot.cpu.turboGHz)
    }
}

/// One bar per logical processor — the quickest way to spot a single busy
/// thread that the aggregate percentage hides.
struct CoreBars: View {
    let cores: [CoreLoad]
    let color: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(cores) { core in
                GeometryReader { proxy in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(color.opacity(0.16))
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(color.opacity(0.35 + core.usage / 100 * 0.65))
                            .frame(height: max(1.5, proxy.size.height * CGFloat(min(core.usage, 100) / 100)))
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}
