import SwiftUI
import Core

/// The card stack shown inside the menu bar panel.
struct PanelBody: View {
    let snapshot: SystemSnapshot
    var histories = PanelBody.Histories()
    var interval: TimeInterval = 2
    var onOpenSettings: (() -> Void)? = nil
    @EnvironmentObject private var settings: AppSettings

    struct Histories {
        var cpu: [Double] = []
        var gpu: [String: [Double]] = [:]
        var memory: [Double] = []
        var download: [Double] = []
        var upload: [Double] = []
        var cpuTemp: [Double] = []
        var gpuTemp: [String: [Double]] = [:]
    }

    var body: some View {
        GlassEffectContainer(spacing: Panel.spacing) { cards }
    }

    @ViewBuilder private var cards: some View {
        let histories = windowed
        VStack(alignment: .leading, spacing: Panel.spacing) {
            header
            HStack(spacing: Panel.spacing) {
                CPUCard(snapshot: snapshot, history: histories.cpu,
                        tempHistory: histories.cpuTemp,
                        showsPerCore: settings.showsPerCore,
                        coolerFan: snapshot.coolingFan(preferring: settings.cpuFanChannel))
                GPUCard(gpus: displayedGPUs, selection: $settings.selectedGPU,
                        usageHistory: histories.gpu, tempHistory: histories.gpuTemp)
            }
            HStack(spacing: Panel.spacing) {
                MemoryCard(snapshot: snapshot, history: histories.memory)
                NetworkCard(snapshot: snapshot.network,
                            download: histories.download, upload: histories.upload)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(identityLine)
                    .font(.mono(TypeScale.body, .semibold))
                    .lineLimit(1)
                FanFlow(spacing: 6, lineSpacing: 4) {
                    Text(Num.uptime(DeviceInfo.shared.uptime))
                        .font(.mono(TypeScale.caption))
                        .foregroundStyle(.secondary)
                    ForEach(headerFans, id: \.channel) { fan in
                        FanChip(fan: fan)
                    }
                }
            }

            Spacer(minLength: 6)

            Button {
                onOpenSettings?()
                NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .accessibilityLabel(L10n.t("settings.open"))
            .fixedSize()
        }
        .controlSize(.small)
        .buttonStyle(.glass)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
    }

    /// 顶栏只放卡片里没有的信息：机型、系统版本、开机时长与风扇转速。
    /// CPU、内存、网卡等卡片已有的读数不再重复。
    private var identityLine: String {
        let info = DeviceInfo.shared
        var parts = [info.macModel, "macOS \(info.shortOSVersion)"]
        if info.isHackintosh { parts.append("Hackintosh") }
        return parts.joined(separator: " · ")
    }

    /// 自动模式只列当前在转的风扇；关掉自动后完全按用户勾选显示。
    private var headerFans: [FanSample] {
        if settings.headerFansAuto {
            return snapshot.fans.filter { ($0.currentRPM ?? 0) > 0 }
        }
        return snapshot.fans.filter { settings.headerFanChannels.contains($0.channel) }
    }

    /// One card per GPU, not per accelerator: when no accelerator answered, the
/// fallback identity is still shown as the only card.
    private var displayedGPUs: [GPUSnapshot] {
        snapshot.gpus.isEmpty ? [snapshot.gpu] : snapshot.gpus
    }

    /// Every strip chart shows the same recent window, chosen in Settings.
    private var windowed: Histories {
        let count = max(2, Int((settings.curveMinutes * 60 / max(0.5, interval)).rounded()))
        func window(_ series: [Double]) -> [Double] { Array(series.suffix(count)) }
        return Histories(cpu: window(histories.cpu), gpu: histories.gpu.mapValues(window),
                         memory: window(histories.memory),
                         download: window(histories.download), upload: window(histories.upload),
                         cpuTemp: window(histories.cpuTemp), gpuTemp: histories.gpuTemp.mapValues(window))
    }
}

private struct PanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct RootView: View {
    var maxHeight: CGFloat = .greatestFiniteMagnitude
    var onHeight: ((CGFloat) -> Void)? = nil
    var onOpenSettings: (() -> Void)? = nil
    @State private var measured: CGFloat?
    @EnvironmentObject private var monitor: HardwareMonitor
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        ZStack {
            BlurBackground()

            ScrollView(.vertical) {
                panel.background(GeometryReader { proxy in
                    Color.clear.preference(key: PanelHeightKey.self, value: proxy.size.height)
                })
            }
            .frame(height: min(measured ?? maxHeight, maxHeight))
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .onPreferenceChange(PanelHeightKey.self) { height in
            measured = height
            onHeight?(min(height, maxHeight))
        }
    }

    private var panel: some View {
        PanelBody(snapshot: monitor.snapshot, histories: .init(
            cpu: monitor.cpuHistory,
            gpu: monitor.gpuHistories,
            memory: monitor.memoryHistory,
            download: monitor.downloadHistory,
            upload: monitor.uploadHistory,
            cpuTemp: monitor.cpuTempHistory,
            gpuTemp: monitor.gpuTempHistories
        ), interval: monitor.interval, onOpenSettings: onOpenSettings)
        .environmentObject(settings)
        .padding(Panel.spacing)
    }
}
/// 顶栏的风扇标签流式布局：一行放不下就换行，面板高度跟着内容增长。
private struct FanFlow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var width: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            width = max(width, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(width, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .init(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// 顶栏里的一路风扇读数：通道名 + 当前转速，用户可在齿轮菜单里选择显示哪些。
private struct FanChip: View {
    let fan: FanSample

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "fanblades")
                .font(.system(size: TypeScale.micro, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(fan.name)
                .font(.mono(TypeScale.caption))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.mono(TypeScale.caption, .medium))
        }
        .lineLimit(1)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
    }

    private var value: String {
        guard let rpm = fan.currentRPM else { return "—" }
        return rpm > 0 ? "\(Int(rpm.rounded())) RPM" : L10n.t("fan.stopped")
    }
}
