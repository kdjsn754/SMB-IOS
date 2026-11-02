import SwiftUI
import UIKit

// MARK: - SwiftUI 入口

/// 全屏看图的分页 + 缩放层：**外层分页滚动，每页一个内层缩放滚动**（UIKit 单一手势权威）。
///
/// ## 为什么重写成 UIKit（1.4.3）
///
/// 1.4.2 之前是 SwiftUI `ScrollView(.horizontal) + .scrollTargetBehavior(.paging)`，
/// 缩放自己算：`MagnifyGesture` 算锚点补偿、`DragGesture` 在放大后当 pan，
/// 两者靠 `.gesture(pan, including: scale > 1.01 ? .all : .none)` 和外层滚动分工。
/// 这套结构有四个绕不过去的冲突：
///
/// 1. **`including:` 是安装手势那一刻求值的**，不是每帧求值。捏合刚到 1.4 倍时
///    pan 还处在「不参与」状态，手指同时平移就被外层翻页吃掉，画面一边缩一边横向漂；
///    缩回 1x 那一刻又反不过来，得等下一次 body 重算 —— 用户感受到的就是「时灵时不灵」。
/// 2. **捏合和外层滚动的 pan 是两条互不知情的识别器**。SwiftUI 的 ScrollView 底层
///    也是 UIScrollView，双指落下时它的 pan 同样成立。捏合的两指只要不同步，
///    就会出现「缩放还在进行、页面已经滑走半张」。
/// 3. **缩放上限/回弹/惯性全得自己写**。自己算的钳制只能做到「不越界」，
///    做不到 UIScrollView 的橡皮筋、甩动、缩放回弹。
/// 4. 双击、单击、拖动、捏合四条 SwiftUI 手势叠在同一层，
///    优先级只能靠 `simultaneousGesture` / `including` 猜，没有任何确定性。
///
/// 换成苹果「照片」、`PhotoScroller`、MWPhotoBrowser 的经典结构：
/// - **外层** `UIScrollView(isPagingEnabled)`：只管横向翻页；
/// - **内层**每页一个 `UIScrollView`（min 1 / max 6）：只管缩放和放大后的平移。
///
/// 分工不是我们判断出来的，是 UIKit 的识别顺序给的：
/// - 1x 时内层**没有可滚动内容**，它的 pan 根本不成立 → 拖动落到外层翻页
///   （PhotoScroller 的原样行为，见 `ZoomScrollView` 注释）；
/// - 双指落下 → 内层 pinch 成立，`scrollViewWillBeginZooming` 里**立刻把外层
///   `isScrollEnabled = false`** —— 捏合期间外层收不到 pan，画面绝不会被两指带跑；
/// - 放大后内层有内容 → 拖动归内层平移；要翻页先缩回 1x（照片 App 同款）；
/// - 双击 → `zoom(to:animated:)`，缩放、回弹、锚点全是系统行为；
/// - 缩回 1x 后内层重新「无内容」→ 外层翻页自动恢复。
///
/// 一句话：**手势不再互相抢，而是各管一段有明确边界的区域。**
struct ZoomablePager: UIViewRepresentable {
    let items: [FileItem]
    let serverID: UUID
    let connection: SMBConnection
    /// 当前页。滚动落定时回写（只在这一刻改一次 SwiftUI 状态）。
    @Binding var index: Int
    /// 单击画面（切浮层显隐）。识别放在 UIKit 层，不再和 SwiftUI 手势抢。
    let onTap: () -> Void

    func makeUIView(context: Context) -> PagerView {
        let view = PagerView()
        view.configure(items: items, serverID: serverID, connection: connection)
        view.onTap = onTap
        view.onPageChanged = { page in
            if index != page { index = page }
        }
        view.prepare(startAt: index)
        return view
    }

    func updateUIView(_ uiView: PagerView, context: Context) {
        // 闭包每次更新都换新（捕获的 @State / dismiss 都是稳定的，换掉没有代价）
        uiView.onTap = onTap
        uiView.onPageChanged = { page in
            if index != page { index = page }
        }
        // 只有「外部要求换页」才动偏移；用户正在拖/正在惯性时就别碰，
        // 否则会把正在进行的翻页硬拽回去（那一下就是「翻页抽一下」）。
        uiView.applyExternalIndex(index)
    }
}

// MARK: - 分页容器

/// 外层分页滚动 + 每页缩放视图的宿主。
///
/// 页是**按需创建**的：只为「当前页 ±1」建视图、离得远的回收（全分辨率位图一张
/// 一两百 MB，几百张的目录不能整目录都留在内存里 —— 这条和 1.3.x 的
/// `LazyHStack` 是同一个约束）。
@MainActor
final class PagerView: UIView {
    /// 外层分页滚动的唯一职责：横向翻页。
    private let pager = UIScrollView()
    private var pages: [Int: PhotoPageView] = [:]

    private var items: [FileItem] = []
    private var serverID: UUID?
    private var connection: SMBConnection?

    var onPageChanged: ((Int) -> Void)?
    var onTap: (() -> Void)?

    private(set) var currentIndex = 0
    private var laidOutSize: CGSize = .zero
    private var prepared = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false

        pager.backgroundColor = .clear
        pager.isPagingEnabled = true
        pager.showsHorizontalScrollIndicator = false
        pager.showsVerticalScrollIndicator = false
        // 内层没有任何可滚动内容时不要靠橡皮筋「假装能滚」——
        // 那会让内层 pan 成立、把横向拖动从外层手里抢走（翻页就废了）
        pager.alwaysBounceHorizontal = false
        pager.alwaysBounceVertical = false
        // 只锁方向：斜着划时要么翻页、要么留给系统下拉退出，不会两件事一起做
        pager.isDirectionalLockEnabled = true
        pager.contentInsetAdjustmentBehavior = .never
        // 触摸立刻下发给子视图：单击切浮层不用等滚动容器的延迟
        pager.delaysContentTouches = false
        pager.canCancelContentTouches = true
        pager.scrollsToTop = false
        pager.delegate = self
        addSubview(pager)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(items: [FileItem], serverID: UUID, connection: SMBConnection) {
        self.items = items
        self.serverID = serverID
        self.connection = connection
    }

    func prepare(startAt index: Int) {
        guard !prepared else { return }
        prepared = true
        guard !items.isEmpty else { return }
        currentIndex = min(max(0, index), items.count - 1)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = bounds.size
        guard size.width > 1, size.height > 1, !items.isEmpty else { return }

        if size != laidOutSize {
            let resized = laidOutSize != .zero
            laidOutSize = size
            pager.frame = bounds
            pager.contentSize = CGSize(width: size.width * CGFloat(items.count), height: size.height)
            for (i, page) in pages {
                page.frame = CGRect(x: CGFloat(i) * size.width, y: 0,
                                    width: size.width, height: size.height)
                // 旋转后旧的缩放比例和偏移全部失效：归位重算，别把图留在屏幕外
                if resized { page.resetZoomForResize() }
            }
            pager.setContentOffset(CGPoint(x: CGFloat(currentIndex) * size.width, y: 0), animated: false)
        }
        ensurePages(around: currentIndex)
    }

    // MARK: 页面生命周期

    private func ensurePages(around page: Int) {
        guard !items.isEmpty, laidOutSize.width > 1,
              let serverID, let connection else { return }

        let first = max(0, page - 1)
        let last = min(items.count - 1, page + 1)
        if first <= last {
            for i in first...last where pages[i] == nil {
                let view = PhotoPageView(item: items[i], serverID: serverID, connection: connection)
                view.frame = CGRect(x: CGFloat(i) * laidOutSize.width, y: 0,
                                    width: laidOutSize.width, height: laidOutSize.height)
                view.onTap = { [weak self] in self?.onTap?() }
                // 捏合起手就把外层关掉：这一步必须发生在识别阶段，
                // 等 `didZoom` 再关就已经被外层的 pan 吃掉几十个点位移了
                view.onZoomBegin = { [weak self] in
                    self?.pager.isScrollEnabled = false
                }
                view.onZoomEnd = { [weak self] zoomed in
                    // 只有回到 1x 才把翻页还回去；放大状态下手势归页内平移
                    self?.pager.isScrollEnabled = !zoomed
                }
                pager.addSubview(view)
                pages[i] = view
            }
        }

        let stale = pages.keys.filter { abs($0 - page) > 3 }
        for i in stale {
            guard let page = pages.removeValue(forKey: i) else { continue }
            page.tearDown()
            page.removeFromSuperview()
        }

        applyActivePage()
    }

    private func applyActivePage() {
        for (i, page) in pages {
            page.setActive(i == currentIndex)
        }
    }

    /// 外部要求跳页（比如将来点「上一张/下一张」）。用户手正在屏幕上时不接管。
    func applyExternalIndex(_ external: Int) {
        guard prepared, items.indices.contains(external),
              external != currentIndex,
              !pager.isTracking, !pager.isDragging, !pager.isDecelerating else { return }
        currentIndex = external
        ensurePages(around: external)
        pager.setContentOffset(CGPoint(x: CGFloat(external) * laidOutSize.width, y: 0), animated: false)
        applyActivePage()
    }
}

// MARK: - 分页滚动代理

extension PagerView: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === pager, laidOutSize.width > 1, !items.isEmpty else { return }
        // 过半就算翻到了：新页提前开始读原图，落定时第一帧就是清晰的
        let raw = Int((scrollView.contentOffset.x / laidOutSize.width).rounded())
        let page = min(max(0, raw), items.count - 1)
        guard page != currentIndex else { return }
        currentIndex = page
        ensurePages(around: page)
        applyActivePage()
        // 每翻一页只回调一次，不是每帧
        onPageChanged?(page)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === pager, !decelerate else { return }
        settleOnNearestPage()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === pager else { return }
        settleOnNearestPage()
    }

    private func settleOnNearestPage() {
        guard laidOutSize.width > 1, !items.isEmpty else { return }
        let raw = Int((pager.contentOffset.x / laidOutSize.width).rounded())
        let page = min(max(0, raw), items.count - 1)
        let target = CGPoint(x: CGFloat(page) * laidOutSize.width, y: 0)
        if pager.contentOffset != target {
            pager.setContentOffset(target, animated: false)
        }
        if page != currentIndex {
            currentIndex = page
            ensurePages(around: page)
            applyActivePage()
            onPageChanged?(page)
        }
    }
}

// MARK: - 单页（缩放 + 加载）

/// 一页：内层缩放滚动 + 缩略图占位 + 原图淡入。
///
/// 内层滚动只做两件事：捏合缩放、放大后拖动画像。其余全部交给外层与系统。
@MainActor
final class PhotoPageView: UIView, UIScrollViewDelegate {
    private let scrollView = ZoomScrollView()
    /// `viewForZooming` 返回的视图。它的 frame 就是**图片适配后的实际尺寸**（不是容器），
    /// 这样放大后的平移边界正好是图片边缘，不会像按容器算那样能拖出黑边。
    private let zoomView = UIView()
    private let placeholderView = UIImageView()
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let failureView = UILabel()

    private let item: FileItem
    private let serverID: UUID
    private let connection: SMBConnection

    var onTap: (() -> Void)?
    var onZoomBegin: (() -> Void)?
    var onZoomEnd: ((Bool) -> Void)?

    private var fullImage: UIImage?
    private var isActive = false
    private var isLoading = false
    private var loadTask: Task<Void, Never>?
    private var releaseTask: Task<Void, Never>?
    private var cancellation: CancellationBox?
    private var laidOutSize: CGSize = .zero

    init(item: FileItem, serverID: UUID, connection: SMBConnection) {
        self.item = item
        self.serverID = serverID
        self.connection = connection
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        clipsToBounds = true

        zoomView.backgroundColor = .clear
        placeholderView.contentMode = .scaleAspectFit
        placeholderView.backgroundColor = .clear
        // 缩略图**全程不透明**：原图淡入时只是把它盖住。
        // 两层同时半透明叠黑底，中间那刻合成覆盖率不够，画面会先暗一下再亮回来（「闪一下」）。
        placeholderView.isOpaque = false
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .clear
        imageView.alpha = 0

        scrollView.backgroundColor = .clear
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 6
        scrollView.bouncesZoom = true
        scrollView.bounces = true
        scrollView.alwaysBounceHorizontal = false
        scrollView.alwaysBounceVertical = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delaysContentTouches = false

        addSubview(scrollView)
        scrollView.addSubview(zoomView)
        zoomView.addSubview(placeholderView)
        zoomView.addSubview(imageView)

        spinner.color = .white
        spinner.hidesWhenStopped = true
        addSubview(spinner)

        failureView.text = "图片加载失败"
        failureView.textColor = UIColor.white.withAlphaComponent(0.7)
        failureView.font = .preferredFont(forTextStyle: .footnote)
        failureView.textAlignment = .center
        failureView.isHidden = true
        addSubview(failureView)

        // 双击缩放 / 单击浮层：单击等双击失败再触发，双击才不会顺带把浮层切一下
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        preloadCachedImage()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: 布局

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 1, bounds.height > 1 else { return }
        let resized = laidOutSize != .zero && laidOutSize != bounds.size
        laidOutSize = bounds.size
        scrollView.frame = bounds
        if resized {
            scrollView.zoomScale = 1
            scrollView.contentInset = .zero
        }
        layoutContentIfPossible()
        centerContent()
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
        failureView.frame = CGRect(x: 0, y: bounds.midY - 12, width: bounds.width, height: 24)
    }

    /// 把 zoomView 摆成「图片按 aspect-fit 适配后」的尺寸，原点固定在内容坐标 (0,0)，
    /// 居中交给 `contentInset`（UIScrollView 缩放的官方做法，见 `centerContent`）。
    /// 只在 1x 时调用：缩放中改 zoomable view 的 frame 会把它弹回原位。
    private func layoutContentIfPossible() {
        guard scrollView.zoomScale <= 1.001 else { return }
        let container = scrollView.bounds.size
        guard container.width > 1, container.height > 1 else { return }

        var fitted = container
        if let size = displayedImageSize, size.width > 1, size.height > 1 {
            let factor = min(container.width / size.width, container.height / size.height)
            fitted = CGSize(width: max(1, size.width * factor), height: max(1, size.height * factor))
        }
        // 缩放视图的实际尺寸 = 图片适配后的尺寸（不是容器）：放大后的平移边界
        // 正好是图片边缘，不会像按容器算那样能拖出黑边。
        zoomView.transform = .identity
        zoomView.frame = CGRect(origin: .zero, size: fitted)
        scrollView.contentSize = fitted
        placeholderView.frame = zoomView.bounds
        imageView.frame = zoomView.bounds
    }

    /// 内容比容器小时居中：靠 `contentInset`。
    /// 不用 `scrollView.contentSize` 反推，是因为它要等 UIScrollView 自己刷新，
    /// 首帧/换图那一拍会算到旧值，画面先贴左上角再跳回中间。
    private func centerContent() {
        let scale = scrollView.zoomScale
        let scaled = CGSize(width: zoomView.bounds.width * scale,
                            height: zoomView.bounds.height * scale)
        let slackX = max(0, (scrollView.bounds.width - scaled.width) / 2)
        let slackY = max(0, (scrollView.bounds.height - scaled.height) / 2)
        let inset = UIEdgeInsets(top: slackY, left: slackX, bottom: slackY, right: slackX)
        if scrollView.contentInset != inset {
            scrollView.contentInset = inset
        }
    }

    private var displayedImageSize: CGSize? {
        (imageView.image ?? placeholderView.image)?.size
    }

    // MARK: 手势

    @objc private func handleSingleTap() {
        onTap?()
    }

    /// 双击：1x → 2.5x（以双击点为锚），放大 → 回 1x。全部走系统缩放，自带动画和回弹。
    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > 1.01 {
            scrollView.setZoomScale(1, animated: true)
            return
        }
        let point = gesture.location(in: zoomView)
        let target: CGFloat = 2.5
        let width = max(1, scrollView.bounds.width / target)
        let height = max(1, scrollView.bounds.height / target)
        let rect = CGRect(x: point.x - width / 2, y: point.y - height / 2,
                          width: width, height: height)
        scrollView.zoom(to: rect, animated: true)
    }

    // MARK: 缩放代理

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { zoomView }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        onZoomBegin?()
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        let zoomed = scrollView.zoomScale > 1.001
        onZoomEnd?(zoomed)
        if !zoomed {
            // 回弹到 1x 之后重新贴合一次：缩略图/原图尺寸可能在这一刻才对齐
            layoutContentIfPossible()
            centerContent()
        }
    }

    // MARK: 页活跃度

    func setActive(_ active: Bool) {
        guard active != isActive else {
            if active { loadIfNeeded() }
            return
        }
        isActive = active
        if active {
            releaseTask?.cancel()
            releaseTask = nil
            loadIfNeeded()
        } else {
            scheduleImageRelease()
        }
    }

    func resetZoomForResize() {
        scrollView.zoomScale = 1
        scrollView.contentInset = .zero
        // 旋转时缩放被强制归 1，`scrollViewDidEndZooming` 不一定会回来 ——
        // 这里必须自己把翻页还给外层，否则「放大状态下转个屏，左右就再也滑不动」
        onZoomEnd?(false)
        setNeedsLayout()
    }

    func tearDown() {
        loadTask?.cancel()
        loadTask = nil
        cancellation?.cancel()
        cancellation = nil
        releaseTask?.cancel()
        releaseTask = nil
        imageView.image = nil
        placeholderView.image = nil
        fullImage = nil
    }

    // MARK: 加载

    /// 缩略图在 `init` 里就铺上：`.onAppear`（UIKit 的 `didMoveToWindow`）要等视图挂上去
    /// 才开始跑，那之前的一两帧只有黑底，缩略图随后「啪」地出现 —— 翻页时的「闪一下」。
    private func preloadCachedImage() {
        if let cached = MediaStore.shared.cachedPreview(for: item, serverID: serverID) {
            fullImage = cached
            imageView.image = cached
            imageView.alpha = 1
            return
        }
        placeholderView.image = ThumbnailStore.shared.cachedThumbnail(for: item, serverID: serverID)
        if placeholderView.image == nil {
            spinner.startAnimating()
        }
    }

    private func loadIfNeeded() {
        guard fullImage == nil, !isLoading else { return }
        if let cached = MediaStore.shared.cachedPreview(for: item, serverID: serverID) {
            apply(full: cached, animated: false)
            return
        }
        if placeholderView.image == nil {
            placeholderView.image = ThumbnailStore.shared.cachedThumbnail(for: item, serverID: serverID)
        }
        // 已经有缩略图铺底就不要再转圈，否则会在缩略图上盖一个加载指示器
        if placeholderView.image == nil {
            spinner.startAnimating()
        }
        isLoading = true

        loadTask?.cancel()
        let box = CancellationBox()
        cancellation = box
        loadTask = Task { [weak self] in
            guard let self else { return }
            let loaded = await withTaskCancellationHandler {
                await MediaStore.shared.image(
                    for: self.item,
                    serverID: self.serverID,
                    connection: self.connection,
                    cancel: box
                )
            } onCancel: {
                box.cancel()
            }
            guard !Task.isCancelled else { return }
            self.isLoading = false
            self.loadTask = nil
            self.cancellation = nil
            self.spinner.stopAnimating()
            if let loaded {
                self.apply(full: loaded, animated: true)
            } else if self.placeholderView.image == nil {
                self.failureView.isHidden = false
            }
        }
    }

    private func apply(full image: UIImage, animated: Bool) {
        fullImage = image
        imageView.image = image
        layoutContentIfPossible()
        centerContent()
        guard animated else {
            imageView.alpha = 1
            return
        }
        // 原图淡入盖住缩略图，而不是「啪」地换一张
        imageView.alpha = 0
        UIView.animate(withDuration: 0.18) { [weak self] in
            self?.imageView.alpha = 1
        } completion: { [weak self] _ in
            guard let self, self.fullImage != nil else { return }
            // 淡入结束后再丢缩略图（省内存）：这一步没有动画，原图也已不透明，看不出变化。
            // 同一个事务里一起清就会又变成两层交叉淡出。
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let self, self.fullImage != nil else { return }
                self.placeholderView.image = nil
            }
        }
    }

    /// 翻走的页把全分辨率位图放掉（一张一两百 MB）。
    /// 但如果它正躺在解码缓存里（刚看过的那张），放掉也省不到内存 ——
    /// 缓存拿着同一个对象 —— 反而会让翻回来时先看到糊的缩略图。那就留着。
    private func scheduleImageRelease() {
        releaseTask?.cancel()
        releaseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard let self, !Task.isCancelled, !self.isActive, self.fullImage != nil else { return }
            guard MediaStore.shared.cachedPreview(for: self.item, serverID: self.serverID) == nil else { return }
            self.placeholderView.image = ThumbnailStore.shared.cachedThumbnail(for: self.item, serverID: self.serverID)
            self.imageView.image = nil
            self.imageView.alpha = 0
            self.fullImage = nil
        }
    }
}

// MARK: - 内层缩放滚动

/// 内层缩放滚动。
///
/// 1x 时它没有可滚动内容，`UIScrollView` 自己就不会让 pan 成立，横向拖动自然落到
/// 外层分页滚动上 —— 这是苹果 `PhotoScroller` 示例二十年来的行为，也是这里分工的依据。
///
/// 下面这个 override 只是**兜底**，不是主要机制：
/// 系统若因为 `contentInset`/浮点误差把这一页判成「可以滚」，内层就会把横向拖动
/// 从外层手里抢走 —— 表现是「左右完全滑不动」，比任何手感问题都严重。
/// 所以显式再问一次「真的有多少内容可滚」，没有就放行给外层。
///
/// 只在 1x 判：放大之后内容一定超出视口（`zoomScale > 1` 直接放行），
/// 这样「捏合放大、手指不抬起继续拖」也不会被这条判断挡掉。
private final class ZoomScrollView: UIScrollView {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer, zoomScale <= 1.001 {
            let reachable = CGSize(
                width: contentSize.width + contentInset.left + contentInset.right,
                height: contentSize.height + contentInset.top + contentInset.bottom
            )
            // 容差 0.5：留白是按「刚好补满一屏」算的，浮点误差不该被当成可滚动
            if reachable.width <= bounds.width + 0.5, reachable.height <= bounds.height + 0.5 {
                return false
            }
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}
