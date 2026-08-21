import SwiftUI

struct DetailView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            pickers
            totalBlock
            toolRows
            chart
            footer
        }
        .padding(16)
        .frame(width: 320)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack {
            Text("Token 消耗")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if let updated = state.lastUpdated {
                Text("更新于 " + Fmt.time(updated))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var pickers: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: Binding(get: { state.period }, set: { state.period = $0 })) {
                ForEach(Period.allCases, id: \.self) { Text($0.shortName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack {
                Picker("", selection: Binding(get: { state.mode }, set: { state.mode = $0 })) {
                    ForEach(UsageMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(state.mode.explanation)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var totalBlock: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(Fmt.tokens(total))
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text("tokens")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            if cost > 0 {
                Text(Fmt.money(cost))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var toolRows: some View {
        VStack(spacing: 7) {
            ForEach(state.summary?.perTool ?? []) { item in
                row(item)
            }
        }
    }

    private func row(_ item: ToolSummary) -> some View {
        let value = item.amount.total(mode: state.mode)
        let share = total > 0 ? Double(value) / Double(total) : 0
        return VStack(spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(item.tool.color).frame(width: 7, height: 7)
                Text(item.tool.displayName)
                    .font(.system(size: 11, weight: .medium))
                if state.activeTools.contains(item.tool) {
                    Circle()
                        .fill(item.tool.color)
                        .frame(width: 5, height: 5)
                        .modifier(PulseEffect())
                }
                Spacer()
                if item.tool == .opencode && item.amount.cost > 0 {
                    Text(Fmt.money(item.amount.cost))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Text(Fmt.tokens(value))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                if let rate = state.liveRates[item.tool] {
                    Text("+" + Fmt.tokens(rate) + "/m")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(item.tool.color)
                        .modifier(PulseEffect())
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06))
                    Capsule()
                        .fill(item.tool.color.opacity(0.85))
                        .frame(width: max(2, geo.size.width * share))
                }
            }
            .frame(height: 3)
        }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("近 7 天")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Canvas { context, size in
                let buckets = Array((state.summary?.daily ?? []).suffix(7))
                guard !buckets.isEmpty else { return }
                let maxValue = buckets.map { bucket in
                    bucket.amounts.values.reduce(0) { $0 + $1.total(mode: state.mode) }
                }.max() ?? 0
                guard maxValue > 0 else { return }

                let gap: CGFloat = 5
                let barWidth = (size.width - gap * CGFloat(buckets.count - 1)) / CGFloat(buckets.count)
                for (index, bucket) in buckets.enumerated() {
                    var y = size.height
                    let x = CGFloat(index) * (barWidth + gap)
                    for tool in Tool.allCases {
                        let value = (bucket.amounts[tool] ?? .zero).total(mode: state.mode)
                        guard value > 0 else { continue }
                        let h = size.height * CGFloat(value) / CGFloat(maxValue)
                        y -= h
                        let rect = CGRect(x: x, y: y, width: barWidth, height: h)
                        context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(tool.color.opacity(0.85)))
                    }
                }
            }
            .frame(height: 64)
            HStack {
                ForEach(Array((state.summary?.daily ?? []).suffix(7).enumerated()), id: \.offset) { _, bucket in
                    Text(String(bucket.dayString.suffix(2)))
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(authColor)
                .frame(width: 6, height: 6)
            Text("cursor: " + state.cursorAuth.message)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button {
                Task { await state.refreshAll(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private var authColor: Color {
        switch state.cursorAuth {
        case .ok: return .green
        case .needsRelogin, .keychainDenied: return .orange
        case .noChrome, .error: return .gray
        }
    }

    private var total: Int64 {
        state.summary?.total.total(mode: state.mode) ?? 0
    }

    private var cost: Double {
        state.summary?.total.cost ?? 0
    }
}
