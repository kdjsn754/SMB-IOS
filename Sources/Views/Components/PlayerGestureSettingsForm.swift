import SwiftUI

/// 「播放手势」设置的 Form 内容，设置页和播放页共用同一份，
/// 两处改的是同一个 `PlayerGestureSettings.shared`，改完立刻生效。
@MainActor
struct PlayerGestureSettingsSections: View {
    @ObservedObject private var gestures = PlayerGestureSettings.shared
    /// 分组标题；二级页自己的导航标题已经写了「播放手势」，传 nil 就不重复显示
    var header: String? = "播放手势"
    /// 恢复默认之后要做什么（设置页用来弹 toast，播放页可以传 nil）
    var onReset: (() -> Void)?

    init(header: String? = "播放手势", onReset: (() -> Void)? = nil) {
        self.header = header
        self.onReset = onReset
    }

    var body: some View {
        Section {
            Toggle("启用手势", isOn: $gestures.isEnabled)

            DoubleTapMenuRow()
                .disabled(!gestures.isEnabled)

            Picker("快进 / 快退", selection: $gestures.seekStep) {
                ForEach(PlayerGestureSettings.seekStepChoices, id: \.self) { step in
                    Text("\(Int(step)) 秒").tag(step)
                }
            }
            .disabled(!gestures.isEnabled || gestures.doubleTap == .none)

            Picker("左右拖动", selection: $gestures.horizontal) {
                ForEach(HorizontalDragAction.allCases) { action in
                    Text(action.title).tag(action)
                }
            }
            .disabled(!gestures.isEnabled)

            Picker("上下拖动", selection: $gestures.vertical) {
                ForEach(VerticalDragAction.allCases) { action in
                    Text(action.title).tag(action)
                }
            }
            .disabled(!gestures.isEnabled)

            Picker("长按画面", selection: $gestures.longPress) {
                ForEach(LongPressAction.allCases) { action in
                    Text(action.title).tag(action)
                }
            }
            .disabled(!gestures.isEnabled)

            Picker("双指捏合", selection: $gestures.pinch) {
                ForEach(PinchAction.allCases) { action in
                    Text(action.title).tag(action)
                }
            }
            .disabled(!gestures.isEnabled)

            Toggle("显示手势诊断", isOn: $gestures.showDiagnostics)
        } header: {
            if let header {
                Text(header)
            }
        }

        Section {
            Button("恢复默认手势") {
                gestures.resetToDefaults()
                onReset?()
            }
        }
    }
}

/// 「双击画面」单独用 `Menu`，不用 `Picker(.menu)`。
///
/// 这个动作的选项文案最长（「两侧快退/快进，中间播放暂停」），系统 menu picker 会把选中值
/// 挤到标题下面折行，看着像多冒出来一行副标题（1.3.35 用户截图：「双击画面这个看着很别扭」）。
/// 改成自绘 Menu：行尾只显示短文案（`shortTitle`，如「两侧快进」），
/// 点开的菜单里仍然列完整描述，选完立刻生效。
@MainActor
private struct DoubleTapMenuRow: View {
    @ObservedObject private var gestures = PlayerGestureSettings.shared

    var body: some View {
        Menu {
            ForEach(DoubleTapAction.allCases) { action in
                Button {
                    gestures.doubleTap = action
                } label: {
                    if gestures.doubleTap == action {
                        Label(action.title, systemImage: "checkmark")
                    } else {
                        Text(action.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text("双击画面")
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                Text(gestures.doubleTap.shortTitle)
                    .foregroundStyle(.secondary)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .opacity(gestures.isEnabled ? 1 : 0.45)
    }
}

/// 播放页「⋯ → 播放手势设置」弹出的面板
@MainActor
struct PlayerGestureSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                PlayerGestureSettingsSections()
            }
            .navigationTitle("播放手势")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
