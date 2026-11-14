import SwiftUI

/// 「播放手势」设置页的内容，设置页直接用；`header` 传 nil 时不重复写标题。
///
/// 1.7.6 不再用 `Section` / 系统 `Picker`：整页在统一卡片里，行用 `AppRow`，
/// 选项用 `Menu` 自绘（`List` 行上 `Menu` 锚点跑偏的问题不存在了，见 1.4.6 第 7 节）。
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
        AppGroup(header) {
            AppRow(icon: "hand.draw.fill", iconTint: .orange, title: "启用手势") {
                Toggle("", isOn: $gestures.isEnabled).labelsHidden()
            }

            menuRow(
                icon: "hand.tap.fill",
                tint: .blue,
                title: "双击画面",
                options: DoubleTapAction.allCases.map { ($0.shortTitle, $0) },
                selection: $gestures.doubleTap
            )

            menuRow(
                icon: "goforward",
                tint: .teal,
                title: "快进 / 快退",
                options: PlayerGestureSettings.seekStepChoices.map { ("\(Int($0)) 秒", $0) },
                selection: $gestures.seekStep
            )

            menuRow(
                icon: "arrow.left.and.right",
                tint: .indigo,
                title: "左右拖动",
                options: HorizontalDragAction.allCases.map { ($0.title, $0) },
                selection: $gestures.horizontal
            )

            menuRow(
                icon: "arrow.up.and.down",
                tint: .purple,
                title: "上下拖动",
                options: VerticalDragAction.allCases.map { ($0.title, $0) },
                selection: $gestures.vertical
            )

            menuRow(
                icon: "hand.point.up.left.fill",
                tint: .pink,
                title: "长按画面",
                options: LongPressAction.allCases.map { ($0.title, $0) },
                selection: $gestures.longPress
            )

            menuRow(
                icon: "arrow.up.left.and.arrow.down.right",
                tint: .green,
                title: "双指捏合",
                options: PinchAction.allCases.map { ($0.title, $0) },
                selection: $gestures.pinch,
                showsSeparator: false
            )
        }

        AppGroup {
            Button {
                gestures.resetToDefaults()
                onReset?()
            } label: {
                AppRow(title: "恢复默认手势", showsSeparator: false) {
                    EmptyView()
                }
            }
            .buttonStyle(AppRowPressStyle())
        }
    }

    /// 一行「标题 + 当前值」，点开是选项菜单。
    private func menuRow<T: Hashable>(
        icon: String,
        tint: Color,
        title: String,
        options: [(String, T)],
        selection: Binding<T>,
        showsSeparator: Bool = true
    ) -> some View {
        AppRow(
            icon: icon,
            iconTint: tint,
            title: title,
            showsSeparator: showsSeparator
        ) {
            Menu {
                ForEach(options.indices, id: \.self) { index in
                    let option = options[index]
                    Button {
                        selection.wrappedValue = option.1
                    } label: {
                        if option.1 == selection.wrappedValue {
                            Label(option.0, systemImage: "checkmark")
                        } else {
                            Text(option.0)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(currentLabel(options, selection.wrappedValue))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .disabled(!gestures.isEnabled)
        }
    }

    private func currentLabel<T: Hashable>(_ options: [(String, T)], _ value: T) -> String {
        options.first { $0.1 == value }?.0 ?? ""
    }
}
