import SwiftUI

/// Filled history line. Values are normalised against `ceiling` when given so
/// a usage series does not jump every tick, or against their own maximum for
/// bursty series such as network throughput.
struct Sparkline: View {
    var values: [Double]
    var color: Color
    var ceiling: Double? = nil
    var lineWidth: CGFloat = 1.6

    var body: some View {
        Canvas { context, size in
            guard values.count > 1, let top = scale(for: size.height) else { return }
            let step = size.width / CGFloat(values.count - 1)
            var line = Path()
            var area = Path()

            for (index, value) in values.enumerated() {
                let point = CGPoint(x: CGFloat(index) * step,
                                    y: size.height - min(max(value, 0) / top, 1) * size.height)
                if index == 0 {
                    line.move(to: point)
                    area.move(to: CGPoint(x: 0, y: size.height))
                    area.addLine(to: point)
                } else {
                    line.addLine(to: point)
                    area.addLine(to: point)
                }
            }
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.closeSubpath()

            context.fill(area, with: .linearGradient(
                Gradient(colors: [color.opacity(0.34), color.opacity(0.02)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(color.opacity(0.95)),
                           style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round))
        }
    }

    private func scale(for height: Double) -> Double? {
        if let ceiling, ceiling > 0 { return ceiling }
        let peak = values.max() ?? 0
        return peak > 0 ? peak * 1.15 : nil
    }
}

/// Two histories in one strip: utilisation as a filled area on a fixed 0…100
/// scale, temperature as a bare line on its own snapped scale, so a hot idle
/// machine and a cool busy one both read clearly.
struct DualSparkline: View {
    var usage: [Double]
    var temperature: [Double]
    var usageColor: Color

    var body: some View {
        Canvas { context, size in
            if usage.count > 1 {
                let step = size.width / CGFloat(usage.count - 1)
                var line = Path()
                var area = Path()
                for (index, value) in usage.enumerated() {
                    let point = CGPoint(x: CGFloat(index) * step,
                                        y: size.height - min(max(value, 0) / 100, 1) * size.height)
                    if index == 0 {
                        line.move(to: point)
                        area.move(to: CGPoint(x: 0, y: size.height))
                    }
                    line.addLine(to: point)
                    area.addLine(to: point)
                }
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .linearGradient(
                    Gradient(colors: [usageColor.opacity(0.30), usageColor.opacity(0.02)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                context.stroke(line, with: .color(usageColor.opacity(0.95)),
                               style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }

            guard temperature.count > 1 else { return }
            let range = tempRange
            let step = size.width / CGFloat(temperature.count - 1)
            var line = Path()
            for (index, value) in temperature.enumerated() {
                let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
                let point = CGPoint(x: CGFloat(index) * step,
                                    y: size.height - min(max(fraction, 0), 1) * size.height)
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            context.stroke(line, with: .color(Accent.thermal.opacity(0.95)),
                           style: StrokeStyle(lineWidth: 1.4, lineJoin: .round, dash: [4, 3]))
            if let last = temperature.last {
                let fraction = (last - range.lowerBound) / (range.upperBound - range.lowerBound)
                let point = CGPoint(x: size.width,
                                    y: size.height - min(max(fraction, 0), 1) * size.height)
                context.fill(Path(ellipseIn: CGRect(x: point.x - 2, y: point.y - 2,
                                                    width: 4, height: 4)),
                             with: .color(Accent.thermal))
            }
        }
    }

    private var tempRange: ClosedRange<Double> {
        guard let lo = temperature.min(), let hi = temperature.max() else { return 30...70 }
        let lower = max(0, ((lo - 4) / 10).rounded(.down) * 10)
        let span = max(40, ((hi + 4 - lower) / 40).rounded(.up) * 40)
        let upper = min(120, lower + span)
        return max(0, upper - span)...upper
    }
}

/// Dot + caption used above the dual sparklines.
struct MiniLegend: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 4, height: 4)
            Text(text)
                .font(.mono(TypeScale.caption))
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
    }
}

/// Circular gauge — the headline utilisation number sits inside it.
struct UsageRing: View {
    var percent: Double
    var color: Color
    var lineWidth: CGFloat = 5
    var label: String

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(color.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(percent / 100, 0), 1))
                .stroke(AngularGradient(colors: [color.opacity(0.55), color], center: .center),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth(duration: 0.45), value: percent)
            VStack(spacing: -1) {
                Text(label)
                    .font(.mono(TypeScale.ring, .semibold))
            }
        }
    }
}

/// Horizontal 0…100 bar, used for VRAM, memory segments and fan duty.
struct LevelBar: View {
    var fraction: Double
    var color: Color
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.18))
                Capsule()
                    .fill(color)
                    .frame(width: max(0, min(1, fraction)) * proxy.size.width)
                    .animation(.smooth(duration: 0.4), value: fraction)
            }
        }
        .frame(height: height)
    }
}
