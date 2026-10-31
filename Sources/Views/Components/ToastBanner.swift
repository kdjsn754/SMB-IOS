import SwiftUI

/// 底部轻提示：设置二级页里「已重新排队 / 已清理」这类反馈统一走它。
struct ToastBanner: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
            .padding(.bottom, 32)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

extension View {
    func toast(_ message: Binding<String?>) -> some View {
        overlay(alignment: .bottom) {
            if let text = message.wrappedValue {
                ToastBanner(text: text)
                    .task(id: text) {
                        try? await Task.sleep(nanoseconds: 1_800_000_000)
                        withAnimation(.easeOut(duration: 0.2)) {
                            message.wrappedValue = nil
                        }
                    }
            }
        }
    }
}
