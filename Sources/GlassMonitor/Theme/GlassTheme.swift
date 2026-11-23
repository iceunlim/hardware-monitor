import SwiftUI

/// The panel speaks in one instrument voice: SF Mono for every figure, unit and
/// label so columns align and nothing reflows as values change. CJK glyphs fall
/// back to the system face, which keeps Chinese legible at small sizes.
extension Font {
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// A small scale covers every label in the cards; keeping the sizes named
/// stops a stray 10 pt or 13 pt label from making one card look different.
enum TypeScale {
    static let display: CGFloat = 30
    static let headline: CGFloat = 16
    static let ring: CGFloat = 15
    static let title: CGFloat = 12
    static let body: CGFloat = 11
    static let unit: CGFloat = 10
    static let caption: CGFloat = 9
    static let micro: CGFloat = 8
}

/// One tint per domain, chosen to stay legible over any wallpaper.
enum Accent {
    static let cpu = Color(red: 0.36, green: 0.66, blue: 1.0)
    static let gpu = Color(red: 0.78, green: 0.55, blue: 1.0)
    static let memory = Color(red: 1.0, green: 0.70, blue: 0.42)
    static let network = Color(red: 0.42, green: 0.86, blue: 0.60)
    static let thermal = Color(red: 1.0, green: 0.52, blue: 0.52)
}

enum Panel {
    static let corner: CGFloat = 22
    static let spacing: CGFloat = 14
    static let padding: CGFloat = 14
    static let cardWidth: CGFloat = 226
    /// 四张卡统一尺寸。高度按内容最高的一张（独显卡片约 189pt）留出余量后固定，
    /// 数据变化、切换每核心负载或增减指标都不会让某张卡变高、网格抖动。
    static let cardHeight: CGFloat = 192
}

extension View {
    /// The card shell: Liquid Glass with a faint colour wash and the
    /// specular response to the pointer that makes the material read as glass.
    /// 尺寸固定为 `Panel.cardWidth × Panel.cardHeight`，内容多少都不改变卡片外框。
    func glassCard(_ tint: Color) -> some View {
        padding(Panel.padding)
            .frame(width: Panel.cardWidth, height: Panel.cardHeight, alignment: .topLeading)
            .glassEffect(.regular.tint(tint.opacity(0.28)).interactive(),
                         in: .rect(cornerRadius: Panel.corner))
    }
}

/// Large figure + unit, the visual anchor of every card.
struct MetricValue: View {
    let value: String
    var unit: String?
    var font: Font = .mono(TypeScale.display, .semibold)

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value).font(font)
            if let unit {
                Text(unit).font(.mono(TypeScale.title, .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// `label …… value` line used for all secondary metrics.
struct MetricRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.mono(TypeScale.body)).foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 2)
            Text(value).font(.mono(TypeScale.body, .medium))
                .foregroundStyle(.primary.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}

struct CardHeader: View {
    let title: String
    var systemImage: String
    var tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: TypeScale.body, weight: .semibold))
                .foregroundStyle(tint)
            Text(title).font(.mono(TypeScale.title, .semibold)).lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}
