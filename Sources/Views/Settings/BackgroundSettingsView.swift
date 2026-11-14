import PhotosUI
import SwiftUI
import UIKit

/// 设置 → 外观 → 自定义背景。
///
/// 三段：
/// - 顶部预览：把当前壁纸 + 一张样张卡片叠起来，滑杆一拖就能看出「控件变透明」是什么样；
/// - 背景：从相册选图（选完进裁切页）、清除；
/// - 控件：0…100 的**透明度** —— 100 = 卡片白底全透只剩壁纸，0 = 原来的实心卡片。
///   淡的只有白底，文字始终实心。滑杆是自绘的（`OpacitySlider`），不是系统 `Slider`。
///
/// 1.7.6 去掉「纯色背景」：只剩壁纸一条路，设置项少一个「我到底选了哪种」的问题。
@MainActor
struct BackgroundSettingsView: View {
    @ObservedObject private var settings = BackgroundSettings.shared

    @State private var pickerItem: PhotosPickerItem?
    @State private var cropRequest: CropRequest?

    /// 选完图先压到长边 2600 再裁：相册原图动辄 4000+ 万像素，
    /// 裁切时整张铺进 `UIScrollView` 会白白吃掉几百 MB。
    private let maxPixel = 2600

    private struct CropRequest: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    var body: some View {
        SettingsDetail(title: "自定义背景") {
            preview

            AppGroup("背景") {
                PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                    AppRow(
                        icon: "photo.fill",
                        iconTint: .indigo,
                        title: settings.kind == .image ? "更换壁纸" : "选择壁纸",
                        subtitle: "从相册选一张图片，可以缩放裁切",
                        value: settings.kind == .image ? "已设置" : nil,
                        showsSeparator: settings.kind == .image
                    )
                }
                .buttonStyle(AppRowPressStyle())

                if settings.kind == .image {
                    Button {
                        settings.clear()
                    } label: {
                        AppRow(
                            icon: "xmark.circle.fill",
                            iconTint: .red,
                            title: "移除壁纸",
                            titleColor: .red,
                            showsSeparator: false
                        )
                    }
                    .buttonStyle(AppRowPressStyle())
                }
            }

            AppGroup("控件", footer: "数值越大卡片越透明，壁纸越清楚；文字始终是实心的。") {
                opacityRow
            }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            load(item)
        }
        .fullScreenCover(item: $cropRequest) { request in
            WallpaperCropperView(image: request.image) {
                cropRequest = nil
            } onDone: { cropped in
                settings.setImage(cropped)
                cropRequest = nil
            }
        }
    }

    // MARK: - 控件透明度

    private var opacityRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("控件透明度")
                Spacer(minLength: 8)
                Text("\(Int((settings.controlOpacity * 100).rounded()))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            // 自绘滑杆（用户要求不用系统 `Slider`，见 `OpacitySlider`）
            OpacitySlider(value: $settings.controlOpacity)
                .padding(.top, 2)

            // 两端各标一句：1.7.2 数值方向翻成「越大越透明」，不写清楚容易拖反
            HStack {
                Text("不透明")
                Spacer(minLength: 8)
                Text("透明")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, AppSurfaces.cardPadding)
        .padding(.vertical, 14)
    }

    // MARK: - 预览

    private var preview: some View {
        ZStack {
            previewBase

            VStack(alignment: .leading, spacing: 10) {
                Text("资源库")
                    .font(.system(size: 22, weight: .bold))

                sampleCard(title: "我的 NAS", detail: "192.168.1.10")

                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(settings.surfaces.card)
                    .frame(height: 52)
            }
            .padding(16)
        }
        .frame(height: 208)
        .clipShape(RoundedRectangle(cornerRadius: AppSurfaces.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppSurfaces.cardRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    private func sampleCard(title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.accentColor.opacity(0.14))
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: "externaldrive.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            settings.surfaces.card,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    @ViewBuilder
    private var previewBase: some View {
        if settings.kind == .image, let image = settings.image {
            GeometryReader { proxy in
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            }
        } else {
            Color(uiColor: .systemGroupedBackground)
        }
    }

    // MARK: - 选图与裁切

    private func load(_ item: PhotosPickerItem) {
        Task {
            // 读完立刻清掉选择，否则再选同一张不会触发 onChange
            defer { pickerItem = nil }

            guard let data = try? await item.loadTransferable(type: Data.self) else { return }

            // 解码 + 缩放在后台做：相机原图十几兆，放在主线程会把选择器关掉的动画卡住
            let limit = maxPixel
            let image = await Task.detached(priority: .userInitiated) {
                ImageDownsampler.downsample(data: data, maxPixel: limit)
            }.value

            guard let image else { return }
            cropRequest = CropRequest(image: image)
        }
    }
}
