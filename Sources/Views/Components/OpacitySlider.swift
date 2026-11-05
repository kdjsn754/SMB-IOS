import SwiftUI

/// 自绘的 0–100 滑杆。
///
/// 为什么不用系统 `Slider`（用户 1.7.2 明确要求自绘）：
/// - 系统滑块在 `List` 行里上下留白很挤，轨道细到看不清「已经拖了多少」；
/// - 系统滑块只能改 `.tint()`，改不了轨道粗细、滑块的描边和按下时的放大反馈。
///
/// 交互刻意做得和系统一致：**按住任意位置直接跳过去**（`minimumDistance: 0`），
/// 不是必须先抓到滑块才能拖 —— 轨道只有几 pt 高，要求精准抓取会很难用。
struct OpacitySlider: View {
    /// 0…1
    @Binding var value: Double

    /// 轨道高度
    var trackHeight: CGFloat = 8
    /// 滑块直径
    var knobSize: CGFloat = 26

    @State private var isDragging = false

    /// 每 5% 一次轻触反馈：滑到头 / 拖过头都有手感，又不至于每 1% 都震
    private var step: Int { Int((value * 20).rounded()) }

    var body: some View {
        GeometryReader { proxy in
            let usable = max(proxy.size.width - knobSize, 1)
            let knobX = usable * CGFloat(value)

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: trackHeight)

                // 已选的一段：宽度画到滑块圆心，视觉上滑块「踩着」进度
                Capsule(style: .continuous)
                    .fill(Color.accentColor)
                    .frame(width: knobX + knobSize / 2, height: trackHeight)
                    .opacity(value <= 0.001 ? 0 : 1)

                knob
                    .offset(x: knobX)
            }
            .frame(width: proxy.size.width, height: knobSize)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        isDragging = true
                        setValue(from: gesture.location.x, usable: usable)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
        }
        .frame(height: knobSize)
        .sensoryFeedback(.selection, trigger: step)
        .accessibilityElement()
        .accessibilityLabel("控件透明度")
        .accessibilityValue("\(Int((value * 100).rounded()))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(value + 0.05, 1)
            case .decrement: value = max(value - 0.05, 0)
            @unknown default: break
            }
        }
    }

    private var knob: some View {
        Circle()
            .fill(Color(uiColor: .systemBackground))
            .frame(width: knobSize, height: knobSize)
            .overlay(
                Circle().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.18), radius: isDragging ? 6 : 3, y: isDragging ? 3 : 1)
            .scaleEffect(isDragging ? 1.12 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isDragging)
    }

    private func setValue(from x: CGFloat, usable: CGFloat) {
        // 手指位置换算成「圆心应该在的位置」：减去半个滑块，两端才会真的顶到 0 / 100
        let raw = (x - knobSize / 2) / usable
        let clamped = min(max(Double(raw), 0), 1)
        if abs(clamped - value) > 0.0005 {
            value = clamped
        }
    }
}
