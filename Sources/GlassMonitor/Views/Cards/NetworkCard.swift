import SwiftUI
import Core

struct NetworkCard: View {
    let snapshot: NetworkSnapshot
    let download: [Double]
    let upload: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(title: L10n.format("network.titleWithInterface", snapshot.activeInterface ?? ""),
                       systemImage: "network", tint: Accent.network)

            HStack(alignment: .top, spacing: 8) {
                direction(bytes: snapshot.downloadBps, session: snapshot.sessionInBytes,
                          arrow: "arrow.down.left", color: Accent.network, trailing: false)
                Spacer(minLength: 0)
                direction(bytes: snapshot.uploadBps, session: snapshot.sessionOutBytes,
                          arrow: "arrow.up.right", color: Accent.thermal, trailing: true)
            }

            ThroughputChart(download: download, upload: upload)
                .frame(minHeight: 48, maxHeight: .infinity)
        }
        .glassCard(Accent.network)
    }

    /// Fixed-width value and unit columns: traffic can swing from 0 to gigabits
    /// without the card changing shape by a single point. Widths are sized for
    /// the widest glyph run (`999.9` / `Gbps` / `MB`) plus slack, never less.
    private func direction(bytes: Double, session: Double,
                           arrow: String, color: Color, trailing: Bool) -> some View {
        let rate = Num.fixedRate(bytes)
        let total = Num.fixedBytes(session)
        return VStack(alignment: trailing ? .trailing : .leading, spacing: 2) {
            HStack(spacing: 2) {
                if !trailing { arrowGlyph(arrow, color) }
                Text(rate.value)
                    .font(.mono(TypeScale.headline, .semibold))
                    .lineLimit(1)
                    .frame(width: 52, alignment: .trailing)
                Text(rate.unit)
                    .font(.mono(TypeScale.unit, .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 30, alignment: .leading)
                if trailing { arrowGlyph(arrow, color) }
            }
            HStack(spacing: 2) {
                Text(total.value)
                    .font(.mono(TypeScale.caption))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
                Text(total.unit)
                    .font(.mono(TypeScale.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 16, alignment: .leading)
            }
        }
    }

    private func arrowGlyph(_ name: String, _ color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: TypeScale.caption, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 8)
    }
}

/// Download above the axis, upload below, sharing one time base and one scale
/// so the two directions stay comparable.
struct ThroughputChart: View {
    let download: [Double]
    let upload: [Double]

    var body: some View {
        Canvas { context, size in
            let midpoint = size.height / 2
            context.stroke(Path { path in
                path.move(to: CGPoint(x: 0, y: midpoint))
                path.addLine(to: CGPoint(x: size.width, y: midpoint))
            }, with: .color(.white.opacity(0.16)), lineWidth: 1)

            let peak = max(download.max() ?? 0, upload.max() ?? 0, 1)
            draw(download, in: &context, size: size, mid: midpoint, upward: true,
                 scale: peak, color: Accent.network)
            draw(upload, in: &context, size: size, mid: midpoint, upward: false,
                 scale: peak, color: Accent.thermal)
        }
    }

    private func draw(_ values: [Double], in context: inout GraphicsContext, size: CGSize,
                      mid: CGFloat, upward: Bool, scale: Double, color: Color) {
        guard values.count > 1 else { return }
        let step = size.width / CGFloat(values.count - 1)
        let span = mid - 1

        var line = Path()
        var area = Path()
        area.move(to: CGPoint(x: 0, y: mid))

        for (index, value) in values.enumerated() {
            let height = CGFloat(min(value / scale, 1)) * span
            let point = CGPoint(x: CGFloat(index) * step,
                                y: upward ? mid - height : mid + height)
            if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            area.addLine(to: point)
        }
        area.addLine(to: CGPoint(x: size.width, y: mid))
        area.closeSubpath()

        context.fill(area, with: .color(color.opacity(0.32)))
        context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
    }
}
