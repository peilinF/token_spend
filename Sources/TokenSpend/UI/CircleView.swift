import SwiftUI

extension Tool {
    var color: Color {
        switch self {
        case .opencode: return Color(red: 0.20, green: 0.78, blue: 0.40)
        case .codex: return Color(red: 1.00, green: 0.62, blue: 0.10)
        case .cursor: return Color(red: 0.72, green: 0.42, blue: 0.98)
        }
    }
}

struct CircleView: View {
    @ObservedObject var state: AppState
    @State private var blink = false

    private var isWaiting: Bool { !state.waiting.isEmpty }

    private var waitingCaption: String {
        if state.waiting.values.contains(where: { $0.kind == .question }) {
            return "⏳ 等你回答"
        }
        return "⏳ 等你确认"
    }

    var body: some View {
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
                .padding(3)
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
                    .padding(.horizontal, 12)
                if isWaiting {
                    Text(waitingCaption)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.orange)
                } else {
                    Text(state.period.displayName)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                if !state.activeTools.isEmpty || !state.liveRates.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(state.activeTools.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { tool in
                            Circle()
                                .fill(tool.color)
                                .frame(width: 4, height: 4)
                                .modifier(PulseEffect())
                        }
                        if !state.liveRates.isEmpty {
                            Text("+" + Fmt.tokens(state.liveRates.values.reduce(0, +)) + "/m")
                                .font(.system(size: 8, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
        .frame(width: 92, height: 92)
        .contentShape(Circle())
        .onAppear { blink = isWaiting }
        .onChange(of: isWaiting) { blink = $0 }
        .onTapGesture { PanelController.shared.toggleDetail() }
        .contextMenu { ContextMenus.view(state: state) }
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
