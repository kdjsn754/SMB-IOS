import PhotosUI
import SwiftUI
import UIKit

/// 设置 → 外观 → 自定义背景。
///
/// 三段：
/// - 顶部预览：把当前背景 + 一张样张卡片叠起来，滑杆一拖就能看出「控件变透明」是什么样；
/// - 背景：从相册选图（选完进裁切页）或直接挑一个纯色；
/// - 控件：0…100 的透明度 —— 调的是**控件层**的不透明度，背景本身不动。
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
            Section {
                preview
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section {
                PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                    SettingsRow(
                        icon: "photo.fill",
                        tint: .indigo,
                        title: settings.kind == .image ? "更换图片" : "选择图片",
                        value: settings.kind == .image ? "已设置" : ""
                    )
                }

                ColorPicker(selection: colorBinding, supportsOpacity: false) {
                    HStack(spacing: 12) {
                        SettingsIcon(symbol: "paintpalette.fill", tint: .purple)
                        Text("背景颜色")
                    }
                }
            } header: {
                SettingsSectionTitle("背景")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("控件透明度")
                        Spacer(minLength: 8)
                        Text("\(Int((settings.controlOpacity * 100).rounded()))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Slider(value: $settings.controlOpacity, in: 0...1)
                        .tint(.accentColor)
                }
                .padding(.vertical, 4)
            } header: {
                SettingsSectionTitle("控件")
            }

            if settings.kind != .none {
                Section {
                    Button {
                        settings.clear()
                    } label: {
                        SettingsRow(
                            icon: "xmark.circle.fill",
                            tint: .red,
                            title: "清除背景",
                            titleTint: .red
                        )
                    }
                    .buttonStyle(.plain)
                }
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

    // MARK: - 预览

    private var preview: some View {
        ZStack {
            previewBase

            VStack(alignment: .leading, spacing: 10) {
                Text("资源库")
                    .font(.system(size: 22, weight: .bold))

                sampleCard(title: "我的 NAS", detail: "192.168.1.10")

                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    .frame(height: 52)
            }
            .padding(16)
            .opacity(settings.controlOpacity)
        }
        .frame(height: 208)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
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
            Color(uiColor: .secondarySystemGroupedBackground),
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
        } else if settings.kind == .color {
            Color(hex: settings.colorHex)
        } else {
            Color(uiColor: .systemGroupedBackground)
        }
    }

    // MARK: - 选图与裁切

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: settings.colorHex) },
            set: { settings.setColor(UIColor($0).hexRGB) }
        )
    }

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
