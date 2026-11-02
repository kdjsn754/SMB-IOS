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

            // 和下面几行一样用系统 Picker（`.menu` 样式）。
            // 不用自绘 Menu：iOS 26/27 里给 Menu 自定义 label 挂在 List 行上时，
            // 弹出锚点会跑到上方行、并把整行文字糊成玻璃，label 还会被染成 accent 蓝。
            // 折行问题靠「只放超短文案」规避，完整说明留给播放页的诊断与 `detail`。
            Picker("双击画面", selection: $gestures.doubleTap) {
                ForEach(DoubleTapAction.allCases) { action in
                    Text(action.shortTitle).tag(action)
                }
            }
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
