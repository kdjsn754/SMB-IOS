import SwiftUI

/// 自绘的「左滑露出删除」行。
///
/// 为什么不用 `List` 的 `.swipeActions`：那一套只有 `List` 里才有，而 `List` 会画
/// 自己的一套行背景与分隔线，正是这轮要清掉的东西（见 `AppSurface.swift`）。
/// 这里把同一套交互自己实现，卡片、行线、底色就能和其它页完全一致。
///
/// 实现要点：
/// - 只接管**水平**位移（`|dx| > |dy|`），垂直方向交给外层 `ScrollView`，
///   所以列表照常滚动；
/// - 删除按钮压在行下面、右侧，行左移露出；
/// - 已展开时点行内任意位置先收起，不会误触发这一行本身的动作。
struct SwipeDeleteRow<Content: View>: View {
    var actionTitle: String
    let onDelete: () -> Void
    let content: Content

    @ObservedObject private var background = BackgroundSettings.shared

    @State private var offset: CGFloat = 0
    @State private var lastTranslation: CGFloat = 0

    private let buttonWidth: CGFloat = 84
    private let openThreshold: CGFloat = 42

    init(
        actionTitle: String = "删除",
        onDelete: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.actionTitle = actionTitle
        self.onDelete = onDelete
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button {
                close()
                onDelete()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .semibold))
                    Text(actionTitle)
                        .font(.caption2.weight(.medium))
                }
                .foregroundStyle(.white)
                .frame(width: buttonWidth)
                .frame(maxHeight: .infinity)
                .background(Color.red)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(offset < -4 ? 1 : 0)
            .accessibilityHidden(offset > -4)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
                // 行底和卡片同色：滑开时挡住下面的红色删除块
                .background(background.surfaces.card)
                .offset(x: offset)
                .overlay {
                    if offset < -4 {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { close() }
                    }
                }
        }
        .clipped()
        .simultaneousGesture(drag)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                let delta = value.translation.width - lastTranslation
                lastTranslation = value.translation.width
                // 垂直为主的手势不接管，让 ScrollView 正常滚
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                offset = min(0, max(-buttonWidth, offset + delta))
            }
            .onEnded { _ in
                lastTranslation = 0
                withAnimation(.snappy(duration: 0.2)) {
                    offset = offset < -openThreshold ? -buttonWidth : 0
                }
            }
    }

    private func close() {
        withAnimation(.snappy(duration: 0.2)) { offset = 0 }
    }
}
