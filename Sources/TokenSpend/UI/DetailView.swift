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
            if !state.waiting.isEmpty {
                waitingBanner
            }
            if let storeError = state.storeError {
                storeErrorBanner(storeError)
            }
            if let codexStatus = state.codexUsageStatus {
                codexUsageBanner(codexStatus)
            }
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
            Text("token 数量，不等同费用或账户额度")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    private var waitingBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "hourglass")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.orange)
            Text(bannerText)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.orange)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.14)))
    }

    private func storeErrorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.red)
            Text("本地存储异常：" + message)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.red)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            Button {
                Task { await state.refreshAll(force: true) }
            } label: {
                Text("重试")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.12)))
        .accessibilityLabel("本地存储异常：" + message)
    }

    private func codexUsageBanner(_ status: String) -> some View {
        let message: String
        if status == "rebuilding" {
            message = "Codex 统计正在重算"
        } else if status.hasPrefix("incomplete:") {
            message = "Codex 统计未完成，保留上次结果"
        } else {
            message = "Codex 统计状态：" + status
        }
        return HStack(spacing: 6) {
            Image(systemName: status == "rebuilding" ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.orange)
            Text(message)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.orange)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            if status.hasPrefix("incomplete:") {
                Button {
                    Task { await state.refreshLocal() }
                } label: {
                    Text("重试")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        .accessibilityLabel(message)
    }

    private var sortedWaiting: [(tool: Tool, info: WaitingInfo)] {        state.waiting
            .map { ($0.key, $0.value) }
            .sorted { a, b in
                if a.info.kind != b.info.kind {
                    return a.info.kind.priority < b.info.kind.priority
                }
                return a.info.since < b.info.since
            }
    }

    private var bannerText: String {
        sortedWaiting.map { tool, info in
            switch info.kind {
            case .question, .permission:
                return "\(tool.displayName) \(info.kind.label)"
            case .stalled:
                let secs = Int(Date().timeIntervalSince(info.since))
                return "\(tool.displayName) 疑似 \(secs)s"
            }
        }
        .joined(separator: " · ")
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
                Text(item.tool == .cursor && state.cursorQuota?.isUnified == true ? "Cursor / Grok" : item.tool.displayName)
                    .font(.system(size: 11, weight: .medium))
                if state.activeTools.contains(item.tool) {
                    Circle()
                        .fill(item.tool.color)
                        .frame(width: 5, height: 5)
                        .modifier(PulseEffect())
                }
                if let info = state.waiting[item.tool] {
                    Image(systemName: "hourglass")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.orange)
                        .help(item.tool.displayName + " " + info.kind.label)
                }
                Spacer()
                if item.amount.cost > 0 {
                    Text(Fmt.money(item.amount.cost))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Text(Fmt.tokens(value))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                // No +xx/m per tool. Rate UI was removed on purpose; do not restore.
                if let since = state.activeSince[item.tool] {
                    let secs = Int(Date().timeIntervalSince(since))
                    HStack(spacing: 3) {
                        Circle()
                            .fill(item.tool.color)
                            .frame(width: 6, height: 6)
                            .shadow(color: item.tool.color.opacity(0.85), radius: 4)
                            .overlay(Circle().fill(.white).frame(width: 2.2, height: 2.2))
                        Text("消耗中·\(secs)s")
                            .font(.system(size: 9, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                    }
                    .foregroundStyle(item.tool.color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [item.tool.color.opacity(0.18), item.tool.color.opacity(0.06)],
                                    startPoint: .leading, endPoint: .trailing
                                )
                            )
                            .overlay(Capsule().stroke(item.tool.color.opacity(0.28), lineWidth: 0.8))
                            .shadow(color: item.tool.color.opacity(0.35), radius: 5)
                    )
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

            if item.tool == .codex, let quota = state.codexQuota {
                codexQuotaBlock(quota)
            }
            if item.tool == .cursor, let quota = state.cursorQuota {
                cursorQuotaBlock(quota)
            }
        }
    }

    private func codexQuotaBlock(_ quota: CodexQuota) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let window = quota.primary {
                QuotaBar(
                    label: window.shortLabel, valueText: "剩 \(Fmt.percent(window.leftPercent))%",
                    fraction: window.leftPercent / 100, color: .codex,
                    detailText: window.resetText, barWidth: 110
                )
            }
            if let window = quota.secondary {
                QuotaBar(
                    label: window.shortLabel, valueText: "剩 \(Fmt.percent(window.leftPercent))%",
                    fraction: window.leftPercent / 100, color: .codex,
                    detailText: window.resetText, barWidth: 110
                )
            }
        }
        .padding(.leading, 13)
    }

    private func cursorQuotaBlock(_ quota: CursorQuota) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if quota.isUnified {
                QuotaBar(
                    label: "共享周",
                    valueText: "已用 \(Fmt.percent(quota.totalPercentUsed ?? 0))%",
                    fraction: (quota.totalPercentUsed ?? 0) / 100,
                    color: .cursor,
                    detailText: quota.cycleEnd.map { "重置 " + Fmt.shortDate($0) } ?? "",
                    barWidth: 76,
                    labelWidth: 36,
                    helpText: "Cursor、Grok、Grok Bot 共用周额度"
                )
                Text(quota.sharedToolsDescription ?? "Cursor、Grok、Grok Bot 共用")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 42)
                Text(tokenCoverageText)
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 42)
                if let error = state.cursorQuotaSyncError {
                    Text(error)
                        .font(.system(size: 8))
                        .foregroundStyle(.orange)
                        .padding(.leading, 42)
                } else if let observed = state.cursorQuotaObservedAt {
                    Text("额度查询 " + Fmt.time(observed))
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 42)
                }
                if let error = state.cursorEventsSyncError {
                    Text(error)
                        .font(.system(size: 8))
                        .foregroundStyle(.orange)
                        .padding(.leading, 42)
                }
            } else {
                HStack(spacing: 6) {
                    Text("月度")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .leading)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.06))
                        Capsule()
                            .fill(Color.cursor.opacity(0.85))
                            .frame(width: max(2, 110 * CGFloat(min(1, (quota.totalPercentUsed ?? 0) / 100))))
                    }
                    .frame(width: 110, height: 4)
                    Text("已用 \(Fmt.percent(quota.totalPercentUsed ?? 0))%")
                        .font(.system(size: 9, weight: .semibold))
                        .monospacedDigit()
                    Spacer(minLength: 4)
                    if let end = quota.cycleEnd {
                        Text("至 " + Fmt.shortDate(end))
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 6) {
                    poolLine("自家模型池", percent: quota.autoPercentUsed)
                    poolLine("三方模型池", percent: quota.apiPercentUsed)
                    if let bonus = quota.bonus, bonus > 0 {
                        Text("+bonus").font(.system(size: 8)).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 34)
            }
        }
        .padding(.leading, 13)
    }

    private var tokenCoverageText: String {
        let latest = state.cursorLatestEventAt.map { "，最新 \(Fmt.shortDate($0))" } ?? "，暂无已返回记录"
        let observed = state.cursorEventsObservedAt.map { "（查询 \(Fmt.time($0))）" } ?? ""
        return "Token 按已返回明细统计\(latest)\(observed)"
    }

    @ViewBuilder
    private func poolLine(_ name: String, percent: Double?) -> some View {
        if let percent {
            Text("\(name) 已用 \(Fmt.percent(percent))%")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
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
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(authColor)
                .frame(width: 6, height: 6)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text("cursor: " + state.cursorAuth.message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let extra = footerMeta, !extra.isEmpty {
                    Text(extra)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
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

    private var footerMeta: String? {
        var parts: [String] = []
        if case .ok(let expiry) = state.cursorAuth, let expiry {
            parts.append("过期 " + Fmt.shortDate(expiry))
        }
        if let sync = state.cursorLastSync {
            parts.append("同步 " + Fmt.time(sync))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var authColor: Color {
        switch state.cursorAuth {
        case .ok: return .green
        case .needsRelogin, .keychainDenied, .unsupportedCookie: return .orange
        case .noChrome, .error, .unknown: return .gray
        }
    }

    private var total: Int64 {
        state.summary?.total.total(mode: state.mode) ?? 0
    }

    private var cost: Double {
        state.summary?.total.cost ?? 0
    }
}
