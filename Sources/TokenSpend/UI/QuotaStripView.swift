import SwiftUI

// Wrapper that scales the strip with the widget scale setting.
struct ScaledQuotaStripView: View {
    @ObservedObject var state: AppState
    var body: some View {
        let s = CGFloat(state.widgetScale)
        QuotaStripView(state: state)
            .scaleEffect(s, anchor: .topLeading)
            .frame(width: 116 * s, height: 84 * s, alignment: .topLeading)
    }
}

// Compact quota rows shared by the circle-widget strip and the hover panel.
// Width budget: the circle window is 136pt wide, so bars stay small and
// reset-time detail lives in the detail panel instead.
struct QuotaStripView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let quota = state.codexQuota {
                if let primary = quota.primary {
                    QuotaBar(
                        label: primary.shortLabel,
                        valueText: "剩 \(Int(primary.leftPercent))%",
                        fraction: primary.leftPercent / 100,
                        color: .codex,
                        detailText: "",
                        barWidth: 32
                    )
                }
                if let secondary = quota.secondary {
                    QuotaBar(
                        label: secondary.shortLabel,
                        valueText: "剩 \(Int(secondary.leftPercent))%",
                        fraction: secondary.leftPercent / 100,
                        color: .codex,
                        detailText: "",
                        barWidth: 32
                    )
                }
            }
            if let quota = state.cursorQuota {
                if let auto = quota.autoPercentUsed {
                    QuotaBar(label: "自家", valueText: "\(Int(auto))%", fraction: auto / 100, color: .cursor, detailText: "", barWidth: 32)
                }
                if let api = quota.apiPercentUsed {
                    QuotaBar(label: "三方", valueText: "\(Int(api))%", fraction: api / 100, color: .cursor, detailText: "", barWidth: 32)
                }
                if quota.autoPercentUsed == nil && quota.apiPercentUsed == nil, let total = quota.totalPercentUsed {
                    QuotaBar(label: "月度", valueText: "\(Int(total))%", fraction: total / 100, color: .cursor, detailText: "", barWidth: 32)
                }
            }
            if state.codexQuota == nil && state.cursorQuota == nil {
                Text("暂无额度数据")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct QuotaBar: View {
    let label: String
    let valueText: String
    let fraction: Double
    let color: Color
    let detailText: String
    var barWidth: CGFloat = 48

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule().fill(color.opacity(0.85)).frame(width: max(2, barWidth * CGFloat(min(1, max(0, fraction)))))
            }
            .frame(width: barWidth, height: 4)
            Text(valueText)
                .font(.system(size: 9, weight: .semibold))
                .monospacedDigit()
            if !detailText.isEmpty {
                Text(detailText)
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }
}
