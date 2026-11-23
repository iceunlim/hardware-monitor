import SwiftUI
import Core

struct GPUCard: View {
    let gpus: [GPUSnapshot]
    @Binding var selection: String?
    let usageHistory: [String: [Double]]
    var tempHistory: [String: [Double]] = [:]

    /// One GPU at a time: every field and both curves come from the device
    /// selected here, never from a mixture of accelerators.
    private var gpu: GPUSnapshot {
        gpus.first { $0.id == selection } ?? gpus.first ?? GPUSnapshot()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            HStack(alignment: .center, spacing: 10) {
                UsageRing(percent: gpu.utilization ?? 0, color: Accent.gpu,
                          label: "\(Num.percent(gpu.utilization))%")
                    .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 3) {
                    if !gpu.isIntegrated || gpu.temperatureC != nil {
                        MetricRow(label: L10n.t("metric.temperature"), value: Num.celsius(gpu.temperatureC))
                    }
                    if showsPower {
                        MetricRow(label: L10n.t("metric.power"), value: Num.watts(gpu.powerW))
                    }
                    if !gpu.isIntegrated {
                        MetricRow(label: L10n.t("metric.fan"), value: fanText)
                    }
                    // 核显没有温度/功耗/风扇通道，改用当前曲线窗口的峰值/平均
                    // 占用填充，避免整张卡只剩一个“—”。
                    if gpu.isIntegrated {
                        MetricRow(label: L10n.t("metric.peak"), value: "\(Num.percent(usagePeak))%")
                        MetricRow(label: L10n.t("metric.average"), value: "\(Num.percent(usageAverage))%")
                    }
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 8) {
                if let memory = memoryUsage {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(L10n.t("metric.vram")).font(.mono(11)).foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            Text(memory.text).font(.mono(11, .medium))
                        }
                        LevelBar(fraction: memory.fraction, color: Accent.gpu)
                    }
                }

                // 核显用共享内存：放在独显“显存”的位置，填补卡片下半部分的空白。
                if gpu.isIntegrated, let shared = gpu.sharedMemoryBytes {
                    HStack(spacing: 6) {
                        Text(L10n.t("metric.sharedMemory")).font(.mono(11)).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text(ByteFormat.string(shared)).font(.mono(11, .medium))
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 10) {
                        MiniLegend(color: Accent.gpu,
                                   text: L10n.format("legend.usage", "\(Num.percent(gpu.utilization))%"))
                        if gpu.temperatureC != nil {
                            MiniLegend(color: Accent.thermal,
                                       text: L10n.format("legend.temperature", Num.degrees(gpu.temperatureC)))
                        }
                        Spacer(minLength: 6)
                        if let clock = gpu.coreClockMHz, clock > 0 {
                            Text(Num.megahertz(clock))
                                .font(.mono(9))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    DualSparkline(usage: usageHistory[gpu.id] ?? [],
                                  temperature: gpu.temperatureC == nil
                                      ? [] : tempHistory[gpu.id] ?? [],
                                  usageColor: Accent.gpu)
                        .frame(height: 30)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .glassCard(Accent.gpu)
    }

    /// With a second GPU the title becomes a pop-up list of devices; with one
    /// GPU it stays a plain header so the usual layout is untouched.
    @ViewBuilder private var header: some View {
        if gpus.count > 1 {
            Menu {
                ForEach(gpus) { candidate in
                    Toggle(candidate.displayName, isOn: Binding(
                        get: { candidate.id == gpu.id },
                        set: { _ in selection = candidate.id }))
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "display")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Accent.gpu)
                    Text(gpu.displayName).font(.mono(12, .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            CardHeader(title: gpu.displayName, systemImage: "display", tint: Accent.gpu)
        }
    }

    private var fanText: String {
        guard let rpm = gpu.fanRPM else { return "—" }
        return rpm > 0 ? "\(Int(rpm.rounded())) RPM" : L10n.t("fan.stopped")
    }

    /// 核显没有独立风扇，功耗也通常不发布；只在驱动确实给出数值时占用一行，
    /// 避免整张卡变成一列“—”。
    private var showsPower: Bool {
        !gpu.isIntegrated || gpu.powerW != nil
    }

    /// 曲线窗口内的占用统计，用来填充核显卡片（它没有温度/功耗/风扇）。
    private var usageSeries: [Double] {
        usageHistory[gpu.id] ?? []
    }

    private var usagePeak: Double? {
        let values = gpu.utilization.map { usageSeries + [$0] } ?? usageSeries
        return values.max()
    }

    private var usageAverage: Double? {
        let values = gpu.utilization.map { usageSeries + [$0] } ?? usageSeries
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// 显存只对发布 VRAM 计数的设备显示。核显用的是共享内存，那些字节计数
    /// 描述的是 GART 映射窗口而不是显存占用，拿来当“显存”会误导。
    private var memoryUsage: (text: String, fraction: Double)? {
        guard let used = gpu.vramUsedBytes, let total = gpu.vramTotalBytes, total > 0 else { return nil }
        return ("\(ByteFormat.string(used)) / \(ByteFormat.string(total))", used / total)
    }
}
