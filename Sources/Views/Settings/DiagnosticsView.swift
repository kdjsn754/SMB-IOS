import SwiftUI
import UIKit

/// 设置 → 诊断：看上次会话是怎么结束的。
///
/// 侧载包装完后常见的情况是「打开就退回桌面，但设置里的分析数据一条都没有」——
/// 没有系统 `.ips` 时，只能靠 App 自己记。这里展示的就是那份自记的结果。
@MainActor
struct DiagnosticsView: View {
    @State private var text = ""
    @State private var confirmClear = false
    @State private var toast: String?

    private var store: DiagnosticsStore { .shared }

    var body: some View {
        SettingsDetail(title: "诊断") {
            Section {
                LabeledContent("当前版本", value: AppInfo.version)
                LabeledContent("记录时间", value: exitTime)
                LabeledContent("判定", value: store.previousExit.title)
            } footer: {
                Text(store.previousExit.hint)
            }

            Section {
                ScrollView {
                    Text(text.isEmpty ? "暂无记录。" : text)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)

                Button("复制全部") {
                    UIPasteboard.general.string = text
                    toast = "已复制"
                }
                .disabled(text.isEmpty)
            } header: {
                Text("记录")
            }

            Section {
                Button("清除记录", role: .destructive) {
                    confirmClear = true
                }
                .disabled(text.isEmpty)
            } footer: {
                Text("只在崩溃后才有内容。清除不影响任何缓存和设置。")
            }
        }
        .toast($toast)
        .onAppear { text = store.reportText }
        .alert("清除诊断记录？", isPresented: $confirmClear) {
            Button("清除", role: .destructive) {
                store.clear()
                text = store.reportText
                toast = "已清除"
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删掉本地的会话/崩溃记录，不动服务器、密码和缓存。")
        }
    }

    private var exitTime: String {
        guard let date = store.previousExitAt else { return "-" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
