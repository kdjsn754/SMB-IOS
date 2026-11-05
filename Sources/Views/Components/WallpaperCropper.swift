import SwiftUI
import UIKit

/// 壁纸裁切页。
///
/// 交互就是系统相册那一套：**双指缩放 + 单指拖动**，屏幕可视区域就是最终壁纸区域，
/// 所见即所得。缩放/拖动的物理手感全部交给 `UIScrollView` —— 弹回、惯性、
/// 捏合锚点都是原生的，不自己写手势（本项目 1.3.x 手搓手势吃过大亏）。
///
/// 裁剪结果 = 当前 scrollView 可视矩形换算回原图坐标，用 `CGImage.cropping` 取像素，
/// 不做重绘、不缩放，出来的就是原图那块像素。
@MainActor
struct WallpaperCropperView: View {
    let image: UIImage
    let onCancel: () -> Void
    let onDone: (UIImage) -> Void

    @State private var cropper = CropperBox()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CropScrollHost(image: image, box: cropper)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                toolbar
                Spacer(minLength: 0)
            }
        }
        .background(Color.black)
    }

    private var toolbar: some View {
        HStack {
            Button(action: onCancel) {
                Text("取消")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(.black.opacity(0.42), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            Text("裁切")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 4, y: 1)

            Spacer(minLength: 8)

            Button(action: finish) {
                Text("完成")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(Color.accentColor, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private func finish() {
        guard let cropped = cropper.croppedImage() else {
            onCancel()
            return
        }
        onDone(cropped)
    }
}

// MARK: - UIKit 承载

/// 只用来在 SwiftUI 里拿住 `CropScrollView` 的引用。
/// 普通 class（不是 `ObservableObject`）—— 赋值不会触发 body 重算。
@MainActor
final class CropperBox {
    weak var view: CropScrollView?

    func croppedImage() -> UIImage? { view?.croppedImage() }
}

@MainActor
private struct CropScrollHost: UIViewRepresentable {
    let image: UIImage
    let box: CropperBox

    func makeUIView(context: Context) -> CropScrollView {
        let view = CropScrollView(image: image)
        box.view = view
        return view
    }

    func updateUIView(_ uiView: CropScrollView, context: Context) {}
}

// MARK: - 原生缩放 / 拖动

/// 图片视图的尺寸就是**原图像素尺寸**（scale = 1 的 UIImage），
/// 于是 `contentOffset / zoomScale` 直接就是原图坐标，裁切时不用再乘一次缩放比。
@MainActor
final class CropScrollView: UIScrollView, UIScrollViewDelegate {

    private let source: UIImage
    private let imageView = UIImageView()
    /// 只在第一次布局时把画面摆到正中，之后跟着用户的手指走
    private var didCenterInitially = false

    init(image: UIImage) {
        source = image
        super.init(frame: .zero)

        delegate = self
        backgroundColor = .black
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        bouncesZoom = true
        decelerationRate = .fast
        // 刻意不开 `alwaysBounce`：图片正好填满视口时允许拖出黑边，
        // 用户会以为裁到了图外面。缩放比例本身已经把边界钳死了。

        imageView.image = image
        imageView.contentMode = .scaleToFill
        imageView.frame = CGRect(origin: .zero, size: image.size)
        addSubview(imageView)
        contentSize = image.size
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let minScale = minimumScale()
        guard minScale.isFinite, minScale > 0 else { return }

        if abs(minimumZoomScale - minScale) > 0.001 {
            // 旋转屏幕 / 分屏导致视口变了：原来贴在最小比例上的，重新贴住新的最小比例
            let wasAtMinimum = zoomScale <= minimumZoomScale + 0.001
            minimumZoomScale = minScale
            maximumZoomScale = minScale * 5
            if wasAtMinimum || zoomScale < minScale {
                zoomScale = minScale
            }
        }
        centerImage()

        if !didCenterInitially, zoomScale > 0 {
            didCenterInitially = true
            // aspectFill 之后总有一个方向是溢出的，默认停左上角会让人以为图被裁掉了左边/上边，
            // 首帧摆到正中更接近「打开相册看到这张图」的直觉
            let scaled = CGSize(
                width: source.size.width * zoomScale,
                height: source.size.height * zoomScale
            )
            let x = max(0, (scaled.width - bounds.width) / 2)
            let y = max(0, (scaled.height - bounds.height) / 2)
            setContentOffset(CGPoint(x: x, y: y), animated: false)
        }
    }

    /// 让图片**填满**可视区的最小缩放（aspectFill）
    private func minimumScale() -> CGFloat {
        let width = source.size.width
        let height = source.size.height
        guard width > 0, height > 0, bounds.width > 0, bounds.height > 0 else { return 1 }
        return max(bounds.width / width, bounds.height / height)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
    }

    /// 图片比可视区小（只在放大前的边缘状态出现）时居中，其余方向靠 inset 兜住弹性
    private func centerImage() {
        let scaled = CGSize(
            width: source.size.width * zoomScale,
            height: source.size.height * zoomScale
        )
        let insetX = max(0, (bounds.width - scaled.width) / 2)
        let insetY = max(0, (bounds.height - scaled.height) / 2)
        let target = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
        if contentInset != target {
            contentInset = target
        }
    }

    /// 当前可视区对应的原图矩形，直接裁像素
    func croppedImage() -> UIImage? {
        guard bounds.width > 0, bounds.height > 0, zoomScale > 0, let cgImage = source.cgImage else {
            return nil
        }

        // contentInset 非 0 时 contentOffset 的原点是 -inset，所以要把 inset 加回来
        let visible = CGRect(
            x: (contentOffset.x + contentInset.left) / zoomScale,
            y: (contentOffset.y + contentInset.top) / zoomScale,
            width: bounds.width / zoomScale,
            height: bounds.height / zoomScale
        )

        // 浮点误差可能让矩形探出图片 1 像素，先夹进边界再裁
        let canvas = CGRect(origin: .zero, size: source.size)
        let rect = visible.intersection(canvas)
        guard rect.width >= 1, rect.height >= 1 else { return nil }

        let pixelRect = rect.applying(CGAffineTransform(scaleX: source.scale, y: source.scale))
        guard let cropped = cgImage.cropping(to: pixelRect) else { return nil }
        return UIImage(cgImage: cropped, scale: 1, orientation: .up)
    }
}
