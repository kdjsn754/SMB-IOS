import AVFoundation
import AVKit
import Combine
import SwiftUI

@MainActor
final class VideoPlaybackModel: ObservableObject {
    let player = AVPlayer()

    @Published var errorMessage: String?
    @Published var downloadProgress: Double?
    @Published var isDownloading = false
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    /// 拖动进度条时暂停刷新，避免手指被时间回调抢走
    @Published var isSeeking = false

    private var currentAsset: AVURLAsset?
    private var statusCancellable: AnyCancellable?
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?

    init() {
        player.actionAtItemEnd = .pause
        player.preventsDisplaySleepDuringVideoPlayback = true
        installTimeObserver()
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPlaying = false
            }
        }
    }

    func start(item: FileItem, serverID: UUID, connection: SMBConnection) async {
        configureAudioSession()
        // 不使用 AVKit 的播放器，也绝不注册「正在播放」信息，
        // 否则系统会在灵动岛弹一块媒体胶囊（用户明确要求去掉）。
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

        var size = item.size
        if size <= 0 {
            size = (try? await connection.fileSize(item.path)) ?? 0
        }
        guard size > 0 else {
            errorMessage = "无法获取视频大小，文件可能为空或没有读取权限。"
            return
        }

        let asset = MediaAssetFactory.shared.makeAsset(
            connection: connection,
            path: item.path,
            fileSize: size,
            fileExtension: item.fileExtension
        )
        currentAsset = asset

        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 5
        observe(playerItem)

        player.replaceCurrentItem(with: playerItem)
        player.play()
        isPlaying = true
    }

    func downloadAndPlay(item: FileItem, serverID: UUID, connection: SMBConnection) async {
        guard !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0
        errorMessage = nil

        do {
            let url = try await MediaStore.shared.localVideoURL(
                for: item,
                serverID: serverID,
                connection: connection
            ) { [weak self] value in
                Task { @MainActor in
                    self?.downloadProgress = value
                }
            }
            let localItem = AVPlayerItem(url: url)
            observe(localItem)
            player.replaceCurrentItem(with: localItem)
            player.play()
            isPlaying = true
            downloadProgress = nil
        } catch {
            errorMessage = "下载失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            downloadProgress = nil
        }

        isDownloading = false
    }

    func togglePlay() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            // 播到最后再点播放就从头来
            if duration > 0, currentTime >= duration - 0.3 {
                player.seek(to: .zero)
                currentTime = 0
            }
            player.play()
            isPlaying = true
        }
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        currentTime = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        statusCancellable = nil
        isPlaying = false
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let currentAsset {
            MediaAssetFactory.shared.release(currentAsset)
        }
        currentAsset = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - 观察

    private func installTimeObserver() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, !self.isSeeking else { return }
                self.currentTime = time.seconds
                self.isPlaying = self.player.timeControlStatus == .playing
                if let seconds = self.player.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 {
                    self.duration = seconds
                }
            }
        }
    }

    private func observe(_ item: AVPlayerItem) {
        statusCancellable = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] status in
                guard status == .failed else { return }
                let reason = item?.error?.localizedDescription ?? "编码格式不受支持或网络中断"
                self?.errorMessage = "无法播放：\(reason)"
            }
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }
}

/// 只用 AVPlayerLayer 铺画面，不带 AVKit 的播放器外壳（也就不会注册系统媒体活动）
private final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    private var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }

    var player: AVPlayer? {
        get { playerLayer?.player }
        set { playerLayer?.player = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer?.videoGravity = .resizeAspect
        playerLayer?.backgroundColor = UIColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .black
        playerLayer?.videoGravity = .resizeAspect
        playerLayer?.backgroundColor = UIColor.black.cgColor
    }
}

private struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        if uiView.player !== player {
            uiView.player = player
        }
    }
}

@MainActor
struct VideoPlayerView: View {
    let item: FileItem
    let serverID: UUID
    let connection: SMBConnection

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = VideoPlaybackModel()
    @State private var chromeVisible = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                PlayerSurface(player: model.player)
                    .ignoresSafeArea()

                // 透明层专门接点击（UIViewRepresentable 上的手势不一定生效）
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            chromeVisible.toggle()
                        }
                        scheduleHide()
                    }

                if chromeVisible {
                    controls
                        .transition(.opacity)
                }

                if let progress = model.downloadProgress {
                    VStack(spacing: 10) {
                        ProgressView(value: progress)
                            .tint(.white)
                            .frame(width: 180)
                        Text("正在下载到本地… \(Int(progress * 100))%")
                            .font(.footnote)
                            .foregroundStyle(.white)
                    }
                    .padding(20)
                    .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                if let message = model.errorMessage {
                    errorOverlay(message)
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            Task { await model.downloadAndPlay(item: item, serverID: serverID, connection: connection) }
                        } label: {
                            Label("下载到本地播放", systemImage: "arrow.down.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await model.start(item: item, serverID: serverID, connection: connection)
            scheduleHide()
        }
        .onDisappear {
            hideTask?.cancel()
            model.stop()
        }
    }

    // MARK: - 控件

    private var controls: some View {
        ZStack {
            Button {
                model.togglePlay()
                scheduleHide()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 62, height: 62)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)

            VStack {
                Spacer()
                progressBar
            }
        }
    }

    private var progressBar: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { model.duration > 0 ? min(model.currentTime, model.duration) : 0 },
                    set: { model.seek(to: $0) }
                ),
                in: 0...max(model.duration, 0.1),
                onEditingChanged: { editing in
                    model.isSeeking = editing
                }
            )
            .tint(.white)

            HStack(spacing: 6) {
                Text(Format.duration(model.currentTime))
                Text("/")
                    .foregroundStyle(.white.opacity(0.5))
                Text(Format.duration(model.duration))
                Spacer()
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 28)
        .padding(.top, 10)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.65)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard model.isPlaying else { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if Task.isCancelled { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                chromeVisible = false
            }
        }
    }

    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.85))
            Button {
                Task { await model.downloadAndPlay(item: item, serverID: serverID, connection: connection) }
            } label: {
                Label("下载到本地播放", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isDownloading)
        }
        .padding(24)
        .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(24)
    }
}
