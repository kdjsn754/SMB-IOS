import SwiftUI

/// 「播放手势」设置的 Form 内容，设置页和播放页右上角共用同一份，
/// 两处改的是同一个 `PlayerGestureSettings.shared`，改完立刻生效。
@MainActor
struct PlayerGestureSettingsSections: View {
    @ObservedObject private var gestures = PlayerGestureSettings.shared
    /// 恢复默认之后要做什么（设置页用来弹 toast，播放页可以传 nil）
    var onReset: (() -> Void)?

    init(onReset: (() -> Void)? = nil) {
        self.onReset = onReset
    }

    var body: some View {
        Section {
            Toggle("启用手势控制", isOn: $gestures.isEnabled)

            Picker("双击画面", selection: $gestures.doubleTap) {
                ForEach(DoubleTapAction.allCases) { action in
                    Text(action.title).tag(action)
                }
            }
            .disabled(!gestures.isEnabled)

            Picker("快进 / 快退跨度", selection: $gestures.seekStep) {
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

            Button {
                gestures.resetToDefaults()
                onReset?()
            } label: {
                Text("恢复默认手势")
            }
        } header: {
            Text("播放手势")
        } footer: {
            Text("""
            单击画面：显示 / 隐藏控件（始终有效）。
            \(gestures.doubleTap.detail)。
            左右拖动：拖动时只预览目标时间，松手才真正跳转（远端流每帧都跳会卡）。
            长按：按住期间倍速播放，松手恢复原速率。
            双指捏合：放大画面，最大 4 倍；右上角的缩放按钮随时可以还原。
            """)
        }
    }
}

/// 播放页右上角「手势」按钮弹出的设置面板
@MainActor
struct PlayerGestureSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("这里改完立刻生效，不用退出播放。", systemImage: "bolt.horizontal")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
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
