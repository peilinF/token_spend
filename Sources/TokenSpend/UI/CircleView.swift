import SwiftUI

extension Tool {
    var color: Color {
        switch self {
        case .opencode: return Color(red: 0.20, green: 0.78, blue: 0.40)
        case .codex: return Color(red: 1.00, green: 0.30, blue: 0.55)
        case .cursor: return Color(red: 0.72, green: 0.42, blue: 0.98)
        }
    }
}

struct CircleView: View {
    @ObservedObject var state: AppState
    @State private var blink = false

    private var isWaiting: Bool { !state.waiting.isEmpty }

    private var sortedWaitingTools: [Tool] {
        state.waiting.keys.sorted(by: { $0.rawValue < $1.rawValue })
    }

    private var waitingNamesText: Text {
        var result = Text("")
        for (index, tool) in sortedWaitingTools.enumerated() {
            if index > 0 { result = result + Text("·").foregroundColor(.secondary) }
            result = result + Text(tool.displayName).foregroundColor(tool.color)
        }
        return result
    }

    var body: some View {
        ZStack {
            ActivityArcsView(tools: state.activeTools.sorted(by: { $0.rawValue < $1.rawValue }))
                .allowsHitTesting(false)

            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                Circle()
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)

                Circle()
                    .trim(from: 0, to: state.summary?.progress ?? 0)
                    .stroke(
                        ringStyle,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .padding(7)
                    .opacity(blink ? 0.35 : 1)
                    .animation(
                        isWaiting
                            ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                            : .default,
                        value: blink
                    )

                VStack(spacing: 1) {
                    Text(Fmt.tokens(total))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 10)
                    if isWaiting {
                        if sortedWaitingTools.count == 1, let tool = sortedWaitingTools.first {
                            VStack(spacing: 1) {
                                HStack(spacing: 3) {
                                    Circle()
                                        .fill(tool.color)
                                        .frame(width: 4.5, height: 4.5)
                                        .modifier(PulseEffect())
                                    Text(tool.displayName)
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(tool.color)
                                }
                                Text(state.waiting[tool]?.kind == .question ? "等你回答" : "等你确认")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(.orange)
                            }
                        } else {
                            VStack(spacing: 1) {
                                Text("⏳ \(state.waiting.count) 个在等你")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.orange)
                                waitingNamesText
                                    .font(.system(size: 8, weight: .bold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                                    .padding(.horizontal, 10)
                            }
                        }
                    } else {
                        Text(state.period.displayName)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    // No +xx/m on the circle. Rate UI was removed on purpose; do not restore.
                }
            }
            .frame(width: 92, height: 92)
            .contentShape(Circle())
            .onTapGesture { PanelController.shared.toggleDetail() }
            .contextMenu { ContextMenus.view(state: state) }
        }
        .frame(width: 136, height: 136)
        .onAppear { blink = isWaiting }
        .onChange(of: isWaiting) { blink = $0 }
    }

    private var ringStyle: AnyShapeStyle {
        if isWaiting {
            return AnyShapeStyle(LinearGradient(colors: [.orange.opacity(0.6), .orange], startPoint: .top, endPoint: .bottom))
        }
        return AnyShapeStyle(AngularGradient(colors: [.accentColor.opacity(0.55), .accentColor], center: .center))
    }

    private var total: Int64 {
        guard let summary = state.summary else { return 0 }
        return summary.total.total(mode: state.mode)
    }
}

struct ActivityArcsView: View {
    let tools: [Tool]
    @State private var glowPulse = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: tools.isEmpty)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let spin = (t * 115).truncatingRemainder(dividingBy: 360)
            let wobble = sin(t * 3.2) * 0.7 + 0.3

            ZStack {
                if !tools.isEmpty {
                    ambientGlow(intensity: wobble)

                    ZStack {
                        ForEach(Array(tools.enumerated()), id: \.element) { index, _ in
                            arc(for: index, glow: true)
                        }
                    }
                    .blur(radius: 7)
                    .opacity(0.85)

                    ZStack {
                        ForEach(Array(tools.enumerated()), id: \.element) { index, _ in
                            arc(for: index, glow: false)
                        }
                    }

                    ForEach(Array(tools.enumerated()), id: \.element) { index, _ in
                        cometHead(for: index)
                    }

                    scanSweep
                }
            }
            .frame(width: 92, height: 92)
            .rotationEffect(.degrees(spin))
            .scaleEffect(glowPulse ? 1.02 : 0.985)
            .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: glowPulse)
            .onAppear { glowPulse = true }
        }
    }

    private func ambientGlow(intensity: Double) -> some View {
        let colors = tools.map { $0.color.opacity(0.22 * intensity) }
        let gradientColors: [Color] = colors.isEmpty ? [.clear] : colors + [colors[0].opacity(0.06), .clear]
        return Circle()
            .fill(
                RadialGradient(
                    colors: gradientColors,
                    center: .center,
                    startRadius: 14,
                    endRadius: 44
                )
            )
            .frame(width: 96, height: 96)
            .blur(radius: 9)
    }

    private var scanSweep: some View {
        Circle()
            .trim(from: 0, to: 0.18)
            .stroke(
                AngularGradient(
                    gradient: Gradient(colors: [.clear, .white.opacity(0.7), .clear]),
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
            )
            .frame(width: 90, height: 90)
            .opacity(0.5)
            .blur(radius: 0.5)
    }

    private func arc(for index: Int, glow: Bool) -> some View {
        let n = Double(max(1, tools.count))
        let spanDegrees: Double = tools.count == 1 ? 118 : max(68, 360 / n - 18)
        let gap = 14.0
        let startFraction = Double(index) / n + gap / 720
        let endFraction = min(startFraction + spanDegrees / 360, startFraction + 0.96)
        let color = tools[index].color

        let gradient = AngularGradient(
            gradient: Gradient(stops: [
                .init(color: color.opacity(0.0), location: 0),
                .init(color: color.opacity(glow ? 0.55 : 0.95), location: 0.35),
                .init(color: color, location: 0.78),
                .init(color: .white.opacity(glow ? 0.35 : 0.9), location: 1.0),
            ]),
            center: .center,
            startAngle: .degrees(startFraction * 360),
            endAngle: .degrees(endFraction * 360)
        )

        return Circle()
            .trim(from: startFraction, to: endFraction)
            .stroke(
                gradient,
                style: StrokeStyle(lineWidth: glow ? 9 : 4.2, lineCap: .round)
            )
            .shadow(color: color.opacity(glow ? 0.0 : 0.92), radius: glow ? 0 : 7)
            .shadow(color: color.opacity(glow ? 0.0 : 0.55), radius: glow ? 0 : 14)
    }

    private func cometHead(for index: Int) -> some View {
        let n = Double(max(1, tools.count))
        let spanDegrees: Double = tools.count == 1 ? 118 : max(68, 360 / n - 18)
        let startFraction = Double(index) / n + 14.0 / 720
        let endFraction = startFraction + spanDegrees / 360
        let headAngle = endFraction * 360
        let color = tools[index].color

        return ZStack {
            Circle()
                .fill(color)
                .frame(width: 7.5, height: 7.5)
                .shadow(color: color, radius: 6)
                .shadow(color: .white.opacity(0.9), radius: 2)
            Circle()
                .fill(.white)
                .frame(width: 3.2, height: 3.2)
        }
        .offset(y: -45.5)
        .rotationEffect(.degrees(headAngle))
    }
}

struct PulseEffect: ViewModifier {
    @State private var pulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(pulsing ? 1.6 : 0.7)
            .opacity(pulsing ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}

struct ContextMenus {
    @MainActor
    @ViewBuilder
    static func view(state: AppState) -> some View {
        Picker("统计周期", selection: Binding(get: { state.period }, set: { state.period = $0 })) {
            ForEach(Period.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        .pickerStyle(.menu)
        Picker("统计口径", selection: Binding(get: { state.mode }, set: { state.mode = $0 })) {
            ForEach(UsageMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        .pickerStyle(.menu)
        Menu("等待检测阈值") {
            ForEach([30.0, 60.0, 120.0], id: \.self) { seconds in
                Button(state.waitThreshold == seconds ? "✓ \(Int(seconds))s" : "\(Int(seconds))s") {
                    state.waitThreshold = seconds
                }
            }
        }
        Menu("Cursor 活跃同步间隔") {
            ForEach([3.0, 8.0, 15.0, 30.0], id: \.self) { seconds in
                Button(state.cursorActiveInterval == seconds ? "✓ \(Int(seconds))s" : "\(Int(seconds))s") {
                    state.cursorActiveInterval = seconds
                }
            }
        }
        Divider()
        Button("立即刷新") {
            Task { await state.refreshAll(force: true) }
        }
        Toggle("开机自启", isOn: Binding(
            get: { LaunchAtLogin.isEnabled },
            set: { LaunchAtLogin.isEnabled = $0 }
        ))
        Divider()
        Button("退出") { NSApp.terminate(nil) }
    }
}
