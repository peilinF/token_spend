import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("偏好设置")
                .font(.system(size: 13, weight: .semibold))

            Picker("动画帧率", selection: Binding(
                get: { state.animationFPS },
                set: { state.animationFPS = $0 }
            )) {
                Text("30 fps（省电）").tag(30)
                Text("60 fps（流畅）").tag(60)
            }
            .pickerStyle(.menu)

            Divider()

            ForEach(Tool.allCases, id: \.self) { tool in
                HStack(spacing: 6) {
                    Circle()
                        .fill(state.toolColor(tool))
                        .frame(width: 8, height: 8)
                    Text(tool.displayName)
                        .font(.system(size: 11))
                    Spacer()
                    ColorPicker("", selection: Binding(
                        get: { state.toolColor(tool) },
                        set: { state.setToolColor(tool, $0) }
                    ), supportsOpacity: false)
                    .labelsHidden()
                    .fixedSize()
                }
            }

            Divider()

            Button("恢复默认颜色") {
                state.resetToolColors()
            }
            .font(.system(size: 11))
        }
        .padding(14)
        .frame(width: 220)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
}
