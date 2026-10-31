# 交接说明（HANDOFF）

> **这个文件是唯一权威的交接文档。每次改动 / 发版都必须更新它**，尤其是文末的「版本记录」和「当前状态」。
> 新会话接手时：先读本文件 → 再读 `README.md` → 需要动代码时按「文件地图」定位，不要全仓库瞎找。

---

## 1. 一句话定位

iOS 端的 SMB 客户端（SwiftUI + AMSMB2），连局域网 NAS 看图片、放视频，自带缩略图与缓存管理；工程不带任何签名配置，用 GitHub Actions 产出**未签名 IPA**，用户自己重签安装。

- **仓库**：`https://github.com/kdjsn754/SMB-IOS`（本地工作目录 `E:\githubjob\SMB-IOS`，分支 `main`）
- **产物**：Actions Artifact `SMBViewer-unsigned-ipa` → 解压得 `SMBViewer-unsigned.ipa`
- **Bundle ID**：`com.smbviewer.app`；**最低系统**：iOS 16.0；**设备族**：iPhone + iPad

---

## 2. 当前状态（截至 2026-10-31）

| 项 | 值 |
| --- | --- |
| 版本 | `1.0.15`（build 16），见 `project.yml` 的 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` |
| 构建 | ✅ 1.0.15 由 run **#22**（sha `719a251`）全绿产出（含「自检：包结构与依赖」） |
| 产物自检 | 1.0.15：`Info.plist` = 1.0.15 / build 16、`MinimumOSVersion` 16.0、可执行文件 arm64（1.31 MB）、**Payload 内无 `Frameworks` 目录**；已交付 `D:\下载\互传\SMBViewer-v1.0.15-unsigned.ipa` |
| 验证方式 | CI 编译通过即视为可编译；**未在真机上做过功能回归**（无设备/无 Mac），功能层面属于「代码审查过、逻辑自洽」状态 |
| 已知待办 | 见第 7 节 |

> 如果 CI 红了，第一件事是看 `归档构建（不签名）` 那一步的日志，Xcode 报错通常集中在那里。

---

## 3. 技术栈与关键决策

- **UI**：SwiftUI，`NavigationStack` + `@MainActor` 观察模型，无第三方 UI 库。
- **SMB**：[AMSMB2](https://github.com/amosavian/AMSMB2)（封装 libsmb2），**已 vendor 到 `Packages/AMSMB2` 并改成静态链接**（见第 7 节 1.0.1 修复）。**只用到** `connectShare` / `contentsOfDirectory` / `contents(atPath:range:)` / `downloadItem` / `attributesOfItem`，升级上游时要重点核这几个签名。
- **工程生成**：XcodeGen（`project.yml` 是唯一工程定义，`SMBViewer.xcodeproj` 被 `.gitignore` 排除，**不要提交 pbxproj**）。
- **视频边下边播**：自定义 scheme `smbstream://` + `AVAssetResourceLoaderDelegate`，把 AVFoundation 的字节请求翻译成 SMB 区间读取（每次 1 MB，减少 SMB 文件句柄开关次数）。加载器支持 **字节预算（`ByteBudget`）** 与 **取消（`CancellationBox`）**，1.0.2 起用它兜住「抽帧时被要求读到文件尾」的坑。
- **播放器**（1.0.7）：**不再用 AVKit 的 `VideoPlayer`**，改成 `AVPlayerLayer`（`PlayerSurface`）+ 自定义控件（居中播放/暂停、底部进度条、时间、4 秒自动隐藏）。原因：AVKit 会自动把播放注册成系统「正在播放」，iOS 26 会在灵动岛弹出媒体胶囊；换成裸 `AVPlayerLayer` 后系统不会再起这个活动，同时代码里显式把 `MPNowPlayingInfoCenter.nowPlayingInfo` 置空兜底。1.0.15 起叠加一层**可配置手势**：`PlayerGestureLayer`（UIKit 手势，不是 SwiftUI `.gesture`，避免和 `AVPlayerLayer` 抢 touches、也才能用 `require(toFail:)` 让单击等双击失败）负责识别，`PlayerGestureSettings`（`@MainActor` 单例 + `UserDefaults`）负责「哪个手势做什么」，设置页「播放手势」可逐项改：双击（两侧快进快退/中间暂停 · 播放暂停 · 单向左/右 · 关闭）、快进跨度（5/10/15/30 秒）、左右拖动（拖动进度/关闭）、上下拖动（左亮度右音量/纯音量/纯亮度/关闭）、长按（1.5×/2×/3× 倍速按住、松手恢复）、双指捏合（缩放 1~4 倍）。几个取舍：**拖进度只在松手时 seek 一次**（远端流每帧 seek 会把 SMB 打爆）、**亮度用黑色遮罩而不是 `UIScreen.main.brightness`**（不改系统亮度、不影响其它 App、iPad 也一致）、**音量用 `AVPlayer.volume` 而不是 `MPVolumeView`**（不弹系统音量条、不碰音频会话）。
- **目录页布局**（1.0.4，1.0.6 调整，1.0.9 定框，1.0.10 去灰底+居中）：固定三列网格、同一行顶部对齐（`LazyVGrid` + `GridItem(alignment: .top)`），单元格为「缩略图 + 两行文件名（中间省略）+ 大小 + 日期」，与常见 NAS 客户端一致；导航栏提供搜索（当前目录内过滤）、排序（名称/时间/大小）、网格⇄列表切换。**1.0.9 起缩略图展示框高度固定**（`TileAspect.box = 0.87`，即宽:高 ≈ 1:1.15，照片/视频/文件夹/其它文件共用同一个框）；**1.0.10 起框内不再铺灰底**——有图时只在图片自身范围内画圆角，空格子是页面底色；图片 `.scaledToFit()` 完整显示后**在框内居中**（横屏上下留白、竖屏左右留白都均匀），播放角标跟着图片左下角走。`FileNameLabel` 固定两行高度，所以同一行三列的图片顶端成一条线、下面的文件名/大小/日期也齐平。1.0.6 的 `.scaledToFill` 裁切、1.0.8 的按真实比例撑格子均已废弃。
  - ⚠️ `LazyVGrid` 的 `alignment` 参数是 **`HorizontalAlignment`**（不是 `VerticalAlignment`），传 `.top` 编译不过；行内垂直对齐要靠 `GridItem(alignment: .top)` 或单元格内部的 `frame(alignment:)`。
- **缩略图**（1.0.2 重写，1.0.6 修正读取，1.0.7 换镜像实现）：同一文件只生成一份 480px 缩略图供网格/列表共用；`NSCache` + 磁盘双层；**图片和视频共用一道有序闸门（`OrderedLimiter(limit: 1, settleMilliseconds: 250)`，一次只跑一个，按格子序号放行，1.0.11 起）**，所以缩略图严格按「左上→右下」依次出现；1.0.14 起闸门**空闲后先聚集 250 ms 再挑最小序号**（否则「谁先跑到闸门」取决于 SwiftUI 起 `.task` 的顺序，会先冒出一张靠后的图）；**图片一律整份读满再解码**（分块 8 MB，读不满就放弃、绝不拿残缺数据解码；上限 160 MB，超过 24 MB 的改为边读边落临时文件、让 ImageIO 从文件解码，避免「几十兆 Data + 几十兆位图」同时占内存）；**视频封面一律走「迷你镜像」**：先用 `MP4Inspector` 摸清盒子结构（moov/mdat/moof 位置、首个视频样本落点、编码 fourcc），**普通 MP4** 取文件头 12→24→40 MB（按首帧落点可自动加大）+ 末尾接 moov，并把 mdat 声明长度改成实际字节数；**分片 MP4**（moof+mdat）切在**完整 fragment 边界**上、一个字节都不截断；抽帧本身**先 `AVAssetReader` 顺着样本读第一帧**（不 seek，和播放同一条路），失败才退回 `AVAssetImageGenerator` 取最靠前的关键帧。见第 7 节 11/15/18。**1.0.13 起按文件大小分流**：≤ 64 MB 走本地镜像（整份读进来、不截断），> 64 MB 直接走 `smbstream://`，并**优先用播放器管线取帧**（`AVPlayer` + `AVPlayerItemVideoOutput`，与 App 里播放完全同一条路），失败才退回 `AVAssetReader` / `AVAssetImageGenerator`—— 因为截断的镜像会让 `moov` 里的样本偏移越界，AVFoundation 一律判损坏（`-11821`）；失败进 180 秒负缓存并记录原因（设置页可见）；视图划走即取消传输。
- **缓存**：`Library/Caches/SMBViewer/{Thumbnails,Media}`，文件名 = `SHA256(服务器ID + 路径 + 大小 + 修改时间)`，服务器文件变了自动失效；上限 200MB/500MB/1GB/2GB/5GB/不限，超限按写入时间删到 80%，启动/进后台/写缓存时触发。
- **密码**：优先钥匙串；不可用（自签名场景常见）时退化为本地混淆存储 → 属于**已知安全折中**，UI 里已提示。
- **主题**：`@AppStorage` + `preferredColorScheme`，三档（跟随系统/浅色/深色）。

---

## 4. 文件地图

```
docs/开发建议-远端媒体与缩略图踩坑复盘.md   1.0.0~1.0.14 全部踩坑的根因/取证/修法，跨平台对照（新人先读这个）
project.yml                     工程定义（依赖、Build Settings、scheme）★改配置先看这里
Config/Info.plist               权限文案、URL scheme、文件共享开关
Packages/AMSMB2/                 vendored 依赖（静态）：AMSMB2/*.swift + Dependencies/libsmb2/{lib,include}
Sources/
  App/SMBViewerApp.swift        @main，注入 AppModel / 缓存
  App/RootView.swift            TabView：服务器列表 + 设置
  App/AppModel.swift            服务器列表持久化（UserDefaults）、连接状态
  Models/SMBServer.swift        服务器配置模型 + 地址归一化（粘贴 smb:// 也能识别）
  Models/FileItem.swift         SMB 目录项解析、MediaKind 判定（按扩展名）
  Models/PreviewRequests.swift  预览页的跳转参数
  Models/PlayerGestureSettings.swift 播放器手势配置（UserDefaults，播放器与设置页共用）
  Services/SMBConnection.swift  ★actor，AMSMB2 的唯一直连封装
  Services/SMBAssetLoader.swift ★AVPlayer 的 SMB 区间读取代理（边下边播核心）
  Services/ThumbnailStore.swift 缩略图生成 + 双层缓存
  Services/MediaStore.swift     大图 / 下载到本地播放
  Services/CacheManager.swift   缓存统计、清理、上限策略（@MainActor 可观察）
  Services/CredentialStore.swift 密码存取（钥匙串 + 退化）
  Services/AsyncLimiter.swift   async 信号量，限并发
  ViewModels/BrowserModel.swift 目录列举、排序、加载状态
  Views/*.swift                 服务器列表/编辑、浏览、看图、播放、设置
  Views/Components/PlayerGestureLayer.swift UIKit 手势层（单击/双击/拖动/长按/捏合 → 事件）
  Views/Components/MediaTiles.swift 网格/列表单元格 + FileNameLabel（中间省略）/ TileCaption
  Services/VideoThumbnailMirror.swift 大文件视频封面的稀疏镜像抽帧（moov + 关键帧）
  Utilities/Formatters.swift     字节、时间（短日期 yyyy/MM/dd）格式化
  Utilities/AppTheme.swift      主题枚举
  Utilities/Formatters.swift    大小/日期/时长格式化
  Utilities/ImageDownsampler.swift ImageIO 降采样
  Resources/Assets.xcassets     AppIcon（1024 png，由 scripts/make_icon.py 生成）/ AccentColor
scripts/build-ipa.sh            本地 macOS 构建（默认挑 Xcode 27，可用 XCODE_VERSION/XCODE_APP 覆盖）
scripts/make_icon.py            重新生成图标
.github/workflows/build-ipa.yml CI：xcode-27 运行器 → 未签名 IPA
```

---

## 5. 构建

### CI（主路径）

`push main` / 打 `v*` tag / 手动 Run workflow 都会触发。关键点：

- 运行器：`xcode-27`（macOS 27 + Xcode 27 + iOS 27 SDK，2026-10-15 起 GA；**arm64**）
- 版本选择：workflow 顶层 `env.XCODE_VERSION: "27"`，步骤「选择 Xcode 27」扫 `/Applications/Xcode_27*.app`，优先正式版、没有才退回 beta
- 缺 Metal 工具链时会自动 `xcodebuild -downloadComponent MetalToolchain`（该步骤 `continue-on-error`）
- 「Set up job / Post Checkout / Complete job」是 GitHub 内置步骤，名字由平台固定，**改不成中文**
- 打包方式：`CODE_SIGNING_ALLOWED=NO` archive → 组 `Payload/` → zip，所以产物是无签名 IPA

**换 Xcode 版本**：改 `runs-on`（`macos-26` / `macos-15`）+ `env.XCODE_VERSION`（`"26.6"` / `"16.4"`）两处即可。

### 查 CI 结果（本机没有 `gh` 也能查）

本机 Git Credential Manager 里已存 `github.com` 凭据（scope: `gist, repo, workflow`），
可以直接把令牌取出来调 REST API，不需要装 `gh`、也不需要 GitHub connector：

```bash
GH=$(cd E:/githubjob/SMB-IOS && printf 'protocol=https\nhost=github.com\n\n' | git credential fill | sed -n 's/^password=//p')
curl -s -H "Authorization: Bearer $GH" \
  "https://api.github.com/repos/kdjsn754/SMB-IOS/actions/runs?per_page=5"   # 最近运行
# 拉产物：先 GET .../actions/runs/<run_id>/artifacts 拿 artifact id，
# 再 curl -L -H "Authorization: Bearer $GH" -o artifact.zip \
#   "https://api.github.com/repos/kdjsn754/SMB-IOS/actions/artifacts/<id>/zip"
```


### 本地 macOS

```bash
brew install xcodegen
./scripts/build-ipa.sh                        # 自动使用最新 Xcode 27
XCODE_VERSION=26.6 ./scripts/build-ipa.sh     # 换版本
XCODE_APP=/Applications/Xcode_27.0.app ./scripts/build-ipa.sh
# 产物：build/SMBViewer-unsigned.ipa
```

---

## 6. 安装（给用户的话术）

未签名 IPA 必须重签：Sideloadly / AltStore / 爱思助手（个人 Apple ID，7 天重签一次）、TrollStore（免签，限支持版本）、或自有证书 `codesign` 全量重签。1.0.1 起 App 里没有内嵌动态框架（AMSMB2 静态链接），重签工具不会漏签框架。首次连接局域网需允许「本地网络」权限。

---

## 7. 已知限制 / 待办

1. **MKV/AVI 等容器播不了** —— AVFoundation 解码头限制，不是连接问题；播放页已提供「下载到本地播放」兜底。可考虑后续接 VLCKit（会显著增加包体积与 LGPL 复杂度）。
2. **只读**：不做上传/删除/重命名，是刻意设计（降低误操作风险）。要加的话从 `SMBConnection` 扩方法 + `BrowserView` 长按菜单入手。
3. **单共享**：一台服务器只连一个共享名，没有「先列共享再选」的流程。
4. **无真机回归**：功能正确性依赖代码审查，用户反馈时优先怀疑 `SMBConnection` 的路径拼接与 `SMBAssetLoader` 的 range 换算。
5. **缩略图首次慢**：视频要读 `moov`（在尾部时还要读末尾）+ 关键帧附近数据，首次加载 1～3 秒属正常；已有磁盘缓存，二次进入是本地读取。
6. **✅ 已修（1.0.1）：iOS 27 上用轻松签 / ESign 安装后点开闪退**
   - 现象：构建成功、安装成功，点图标后立即退回桌面。
   - 根因：AMSMB2 的 SPM 产物声明了 `type: .dynamic`，IPA 里带 `Frameworks/AMSMB2.framework`；轻松签 / ESign 这类工具默认只签主程序、**不签嵌套框架**，iOS 启动时 dyld 校验失败 → 直接杀进程。
   - 修复：把 AMSMB2 连同 libsmb2 vendor 到 `Packages/AMSMB2`，`Package.swift` 里 product 改为 `.static`，并去掉 swift-system / swift-atomics 外部依赖；`project.yml` 的 `packages` 改为本地 `path`。产物里只剩一个可执行文件。
   - 防回归：CI「自检：包结构与依赖」步骤里加了硬断言——一旦 `Frameworks/AMSMB2.framework` 再次出现就 `::error::` 失败。
   - 代码侧已排查：启动路径只渲染 `ServerListView`（空态）+ `SettingsView`，无网络、无强制解包、无 `fatalError`；SwiftUI `App` 生命周期在 iOS 27「必须采用 UIScene」新规里是**豁免**的（该规定只针对 UIKit app-based 生命周期）。

7. **✅ 已修（1.0.2）：缩略图大量显示不出来 + 一打开就一直跑流量**
   - 现象 A：目录里很多图片/视频只有灰色图标或一直转圈。
   - 现象 B：只是打开 App 进目录，NAS 的上传/下载速率就一直居高不下。
   - 根因（按影响排序）：
     1. `SMBAssetLoader` 对「从当前位置读到文件结尾」的请求照单全收 → `AVAssetImageGenerator` 抽一帧等于把整部视频下完；4 个并发槽位被视频占满，图片缩略图全部排在后面等 → 表现为「很多缩略图出不来」+「持续跑流量」。
     2. 图片缩略图用 `readAll` 整文件读取，无上限、无取消；超大图（RAW/大 JPEG）还会撞 30 秒 SMB 超时直接失败。
     3. 失败结果不缓存，`LazyVGrid` 复用时反复重试同一个坏文件。
     4. 视图划走后传输不中断，继续读完。
     5. 看图页 `TabView(.page)` 会把所有页都建出来，`ZoomableImageView` 每页都在 `.task` 里读原图 → 打开一张图等于把整个目录的原图全下一遍。
     6. 每写一张缩略图就调 `autoCleanIfNeeded()`，里面是一次全目录遍历，滑动时持续做无谓 I/O。
   - 修复：`ThumbnailStore` 整体重写（任务去重 + 等待者计数 + 取消传播 + 失败负缓存 + 图片/视频分闸门）；`SMBAssetLoader` 加 `ByteBudget` / `CancellationBox`；`SMBConnection.read` 用 AMSMB2 的 progress 回调实现真正的传输中止（取消不重建会话）；看图页只加载当前页；`CacheManager` 改为 `noteWrite(bytes:)` 累加 + 20 秒节流，目录只建一次。
   - 新增设置：「加载图片缩略图」「加载视频封面」两个开关（关掉视频封面可省掉绝大部分流量），以及「重新尝试加载失败的缩略图」。

8. **✅ 已修（1.0.3）：BMP 缩略图全黑、1GB 以上 MP4 出不来封面**
   - 现象 A：目录里的 `.bmp` 缩略图全是纯黑方块（不是占位图标，说明「解码成功但画面全黑」）。
   - 现象 B：几百兆的 MP4 有封面，1GB 以上的 MP4 一律没有封面。
   - 根因 A：BMP/TIFF 是无压缩/分块存储，必须整份数据才能解码。旧逻辑按 1MB→4MB→16MB 分阶段截断读取，ImageIO 拿到残缺数据**不报错**，而是返回一张主体全黑的图，于是被当成成功结果写进了磁盘缓存。
   - 根因 B：`SMBAssetLoader` 把单次响应砍到 4MB（`min(remaining, 4MB)`），而 1GB 以上视频的 `moov` 索引本身就有十几兆，被砍断后 AVFoundation 解析失败；额度上限 10MB 也不够。
   - 修复 A：`ImageDownsampler.downsample` 增加「完整解码再缩放」兜底（用 `.copy` 混合模式写进无 alpha 的上下文，规避 32 位 BMP 的 alpha=0 变全透明）；`ThumbnailStore` 对 `bmp/dib/tif/tiff` 走完整读取路径（分块 8MB，上限 64MB）。
   - 修复 B：去掉 4MB 单次响应限制，只受总额度约束；视频封面额度 10MB → 32MB。
   - 缓存：`CacheManager.thumbnailVersion` 递增到 2，旧的全黑缩略图自动失效（旧文件变成孤儿，会被缓存上限清理掉）。

8. **✅ 新版式（1.0.4）：目录页改成三列信息流**
   - 需求：显示效果对齐常见 NAS 客户端——三列缩略图，图下方依次是文件名（最多两行、超长中间省略）、大小、日期。
   - 实现：`BrowserView.gridColumns` 固定 3 个 `.flexible()`，行距 16、列距 12、水平边距 12；`MediaTile` / `FolderTile` / `OtherTile` 的 `gridBody` 统一改成 `VStack(spacing: 5)`。
   - 文件名超长（>26 字符）时由 `FileNameLabel` 拆成「前 16 字符 + …后 12 字符」两行，避免只看到一长串前缀。
   - 新增导航栏能力：搜索（`visibleItems` 在当前目录内过滤，大小写不敏感）、排序（`BrowserSort`：名称/名称倒序/时间新→旧/旧→新/大小大→小/小→大，存 `SettingsKey.sortOrder`）、网格⇄列表切换（原「更多」菜单保留）。
   - 注意：排序/搜索只影响当前目录；`open()` 用 `visibleItems` 过滤图片列表，保证看图左右滑动顺序与网格一致。

9. **✅ 已修（1.0.5）：大文件 MP4 没有封面（含 522 MB、moov 在尾部的片子）**
   - 现象：`桃桃酱-白衬无缝肉丝.mp4`（522 MB，`moov` 在文件末尾，offset 547662742，大小 422378）在目录里只显示胶片占位图标。
   - 根因：AVFoundation 抽帧时会发出「从当前偏移一直读到文件尾」的请求。这类请求无法在不读完整个文件的前提下满足，一旦命中 `ByteBudget` 只能提前 `finishLoading()`，AVFoundation 便认为资源被截断、整条解析链失败。小文件能整部读完所以正常，大文件必然失败。
   - 修复：新增 `VideoThumbnailMirror`（稀疏镜像）。流程：① 读 8～16 字节盒子头，顺着顶层盒子找到 `moov`（头尾都支持）；② 读 moov（≤8 MB）、文件头 1 MB；③ 从 moov 的 `stbl` 里取视频轨 `stco`/`co64` 第一个 chunk 偏移，读该位置往前 128 KB、往后 8 MB；④ 按原始偏移写进临时「稀疏文件」（空洞不占磁盘）；⑤ `AVAssetImageGenerator` 对本地文件抽帧，用完即删。
   - 分流：≤24 MB 的视频先走原流式抽帧（一次读完更省请求），失败再镜像；>24 MB 直接镜像，失败再退回流式。
   - 收益：封面流量与文件大小解耦（约 10 MB 封顶），也不再受 AVFoundation 请求策略影响。

10. **✅ 已修（1.0.6）：部分缩略图只显示上半张 / 缩略图被裁成方框**
   - 现象 A：目录里个别图片缩略图只画出上半个身子，下半截是纯灰；同目录另外几张正常。
   - 现象 B：格子里的人像被裁掉头脚，只能看到中间一块（对比同类文件管理软件，它们是完整显示整张图）。
   - 根因 A：`ThumbnailStore.readPlan` 对 16 MB 以上的图片「先读 8 MB 试试能不能解开」。ImageIO 拿到截断的 JPEG **不报错**，而是解出一张「上半张正常、下半张灰」的图并返回非 nil，我们据此认为成功、写进了缓存。19 MB / 17 MB 的那几张正好命中这个分支。
   - 根因 B：`ThumbnailImage` 用了 `.scaledToFill()` + 正方形卡片的组合，等于对图片做居中裁切。
   - 修复 A：删掉分阶段读取，图片统一整份读满（分块 8 MB、上限 64 MB）后再解码；`data.count < size` 直接判失败显示占位图标，宁可没有图也不糊半截图。`CacheManager.thumbnailVersion` 递增到 3，旧残图自动失效。
   - 修复 B：`ThumbnailImage` 改 `.scaledToFit()`；网格卡片比例按类型给（照片 `3:4`、视频 `16:9`、文件夹 `1:1`），照片按竖幅铺满，视频按横幅铺满，都不再裁切。

11. **✅ 已修（1.0.7）：1.0.5/1.0.6 里「大文件视频封面仍然出不来」的真正原因 + 播放时灵动岛弹胶囊 + 缩略图乱序出现**
   - 现象 A：`桃桃酱-白衬无缝肉丝.mp4`（548 MB）、`1.mp4`（1.02 GB、421 MB）在目录里始终只有胶片图标。
   - 根因 A：1.0.5 的镜像方案是「按原始偏移把 moov 写到文件末尾」。这三个片子都是 `ftyp → free → mdat → moov` 布局，moov 在最后，于是临时文件的**逻辑大小直接等于原片大小**（548 MB / 1 GB），中间全是空洞。手机上写这种文件极慢、空间不足时直接抛错，`makeImage` 就只能返回 nil。
   - 现场核对（本地解析真实文件）：三者 moov 分别位于 547662742 / 1024471689 / 420634637，`stco` 首项都是 48（首帧就在文件开头），首个 GOP 分别 16.5 MB / 15.9 MB / 11.7 MB。
   - 修复 A：改成「迷你镜像」——只读**文件头 12 MB** + moov，把 `mdat` 盒子的**声明长度改成实际拿到的字节数**，拼成一个小而连续的文件（不再有空洞、也不再等于原片大小）；抽帧失败时按 1.0 → 0 → 3 秒依次重试。临时文件稳定在 13 MB 左右，与影片大小无关。
   - 现象 B：播放视频时灵动岛弹出一块「喇叭 + 五个点」的媒体胶囊。
   - 根因 B：SwiftUI `VideoPlayer` 背后是 `AVPlayerViewController`，它会自动把播放注册成系统「正在播放」，iOS 26 会为此起一个媒体 Live Activity。
   - 修复 B：播放页改用 `AVPlayerLayer`（`PlayerSurface`）+ 自绘控件，不再经过 AVKit；开始播放与结束时都把 `MPNowPlayingInfoCenter.default().nowPlayingInfo` 置空。
   - 现象 C：进目录时缩略图在随机位置一张张冒出来。
   - 根因 C：几十个格子的请求几乎是同时发出的，`AsyncLimiter` 只按「到达顺序」放行，而 Task 调度顺序并不等于网格顺序。
   - 修复 C：新增 `OrderedLimiter`（按格子序号优先放行），`ThumbnailStore.thumbnail` 增加 `order` 参数，`BrowserView` 用 `visibleItems` 的下标传入，缩略图按「左上 → 右下」填充。
   - 附带：新增 `ThumbnailDiagnostics`，把最近 5 条失败原因（找不到 moov / moov 过大 / 临时文件写失败 / 抽帧失败 / 图片读不全）显示在设置页「缩略图」里，方便下轮直接定位。

12. **✅ 已修（1.0.8）：竖屏视频/照片被压成中间一条、两侧大片留白，整体布局与同类软件对不上**
   - 现象：目录里竖屏内容（竖拍视频、人像照片）在格子里被 `scaledToFit` 缩成中间一条竖幅，左右两侧大片灰白；横屏内容也塞不进合适的格子，整页显得很空、很丑。
   - 根因：1.0.6 给格子比例**写死了**「照片 `3:4`、视频 `16:9`」（`TileAspect`），再用 `.scaledToFit` 把真实图片往这个固定比例框里塞。竖屏视频（9:16）放进 16:9 的横框，自然只剩中间一条。参照软件（用户给的截图）是**按内容真实宽高比给格子高度**——竖屏撑成竖条、横屏撑成横条，同一行顶部对齐、底部随高度错落。
   - 修复：去掉写死的 `TileAspect.photo/video`。`ThumbnailImage` 加载到真实缩略图后，用 `image.size` 算出真实宽高比并通过新增的 `onAspectChange` 回传给 `BrowserView`，父级把它存进 `@State aspects: [String: CGFloat]`（key 为 `item.id`），再喂回 `MediaTile` 的 `.aspectRatio`。加载完成前用正方形（`TileAspect.placeholder = 1`）占位。
   - 附带：文件名 / 大小 / 日期三行字号微调（12→13 / 11→12），整体更接近参照软件的信息密度。
   - ⚠️ **这套「按真实比例撑格子」在 1.0.9 已被废弃**（见下一条），相关代码（`onAspectChange` / `aspects` / `TileAspect.placeholder`）已删除。

13. **✅ 已修（1.0.9）：竖屏缩略图过大、横屏缩略图不与竖屏对顶（看着像在格子里居中）**
   - 现象：1.0.8 按真实宽高比撑格子后，9:16 竖屏视频的格子高度被拉成「列宽 × 1.78」，整页被竖条占满、显得又大又长；同一行里横屏图比竖屏矮，行高被最高的格子撑起，矮的那个看起来像垂直居中，横屏图与竖屏图的顶端没有对齐；三列的「大小 / 日期」也跟着错位。
   - 根因：格子高度由每张图的真实比例分别决定 → 同一行三列高度不等，`LazyVGrid` 只能把矮格子放在被撑高的行里（观感就是居中）；同时竖屏比例 9:16 没有任何上限，格子可以无限高。
   - 修复：改为**固定展示框**——`TileAspect.box = 0.87`（宽:高 ≈ 1:1.15，媒体/文件夹/其它文件共用），`ThumbnailImage` 内部 `Image.scaledToFit()` 后套 `.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)`，让留白只出现在图片下方、绝不上下均分；`FileNameLabel` 加 `minHeight: 32`（固定两行高度），于是同一行三列的图顶端齐平、文字行也齐平。`BrowserView` 删除 `aspects` 状态与 `onAspectChange` 回调，`MediaTile` 不再接收比例参数。
   - 观感取舍：横屏图在竖幅固定框里下方会留白（这是「不裁切 + 全部对顶」的必然代价，参考软件同样如此）。若以后想让内容更满，只改 `TileAspect.box` 一个常量即可（调小→更方、调大→更竖）。

14. **✅ 已修（1.0.10）：格子里出现灰色边、横屏缩略图贴顶应该居中**
   - 现象：1.0.9 的格子里，图片没铺满展示框的部分露出**灰色方块**（横屏图下方一大块灰）；横屏图被顶到框的最上方，看着别扭。
   - 根因：1.0.9 把灰底当作「整格背景」（`Rectangle().fill(secondarySystemFill)`），图片 `.scaledToFit()` 后又被 `alignment: .top` 顶到上面，于是没被图片盖住的区域就是灰的。
   - 修复：`ThumbnailImage` 改成 `ZStack` 两态——**有图时只画图片本身**（圆角裁在图片上，不再有底板），无图/失败时才画灰色占位块；图片在外层 `frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)` 里居中，横屏上下留白均匀、竖屏左右留白均匀。播放角标从「整格左下角」移到**图片自身的左下角**（`overlay` 挂在 `Image` 上），不会飘到留白里。列表页传 `showPlayBadge: false`，避免和文字行里的播放图标重复。
   - 备注：没有图片时的失败占位仍是灰块 + 图标（这是要让人看出「这里有东西但没图」）。

15. **✅ 已修（1.0.10）：个别大文件视频始终抽帧失败（诊断显示「已取 12288 KB + moov」）**
   - 现象：`桃桃酱-白衬无缝肉丝.mp4` 等片子，1.0.7 的迷你镜像已经能拿到 moov，但抽帧还是失败，设置页诊断写「抽帧失败（已取 12288 KB + moov）」。
   - 根因：文件头固定只读 12 MB，而这类片子单个 GOP 就有 16 MB 左右，第一帧（关键帧）的数据被切断，解码器拿不到完整的首帧 → 抽帧必然失败。
   - 修复：`VideoThumbnailMirror` 的头部长度改成**逐级重试**（12 MB → 24 MB → 40 MB，读到文件尾即止），moov 只读一次、多轮复用；`extractFrame` 改成返回 `(image, error)`，把 AVFoundation 的真实报错（含错误码）写进 `ThumbnailDiagnostics`，下一轮出问题能直接看原因而不是靠猜；实测整份读入仍失败才放弃。
   - 代价：失败时最多多读 ~28 MB（仅在 LAN、且只在封面抽不出来时发生），成功路径通常第一轮 12 MB 就够。

16. **✅ 已修（1.0.11）：缩略图仍然不是按顺序一个一个出现**
   - 现象：1.0.7 引入 `OrderedLimiter` 后，进目录时缩略图还是在随机位置冒出来。
   - 根因（三个叠加）：
     1. **图片和视频是两道独立闸门**（图片 `OrderedLimiter(limit: 3)`、视频 `AsyncLimiter(limit: 1)`），跨类型完全没有排序 —— 视频常常比它前面几张图片更早返回。
     2. `OrderedLimiter.acquire` 只要还有空位就**直接放行**，不看序号；开头 3 个名额被谁先抢到取决于 Task 调度。
     3. 放行时只挑「当前队伍里」序号最小的，而同一批格子创建时间相差几毫秒，序号较大的可能先登记进队伍 → 先被放行。
   - 修复：两道闸门合并成**一道**（`displayLimiter = OrderedLimiter(limit: 1, graceMilliseconds: 60)`），图片和视频排队同一条队伍、一次只跑一个；`acquire` 改成「队伍里有人就必须排队」；`release` 在挑下一个之前先等 60 ms 宽限，让同一批格子把序号登记完再选最小的。磁盘/内存命中不进闸门（本来就瞬时返回）。

17. **⏳ 待用户确认（1.0.12）：`桃桃酱-白衬无缝肉丝.mp4` / `1.mp4` 抽帧失败 -11821**
   - 诊断原文（1.0.11）：`抽帧失败（文件头试到 40 MB · 编码 avc1）：无法解码(-11821)` + `流式抽帧也失败：无法解码(-11821)`；用户实测这些文件**点开能正常播放**。
   - `-11821` = `AVError.decodeFailed`（`AVFoundationErrorDomain`）：数据拿到了但解不出来。
   - **已排除**：编码不受支持（fourcc 是 `avc1`，且能播放）、找不到 moov（报错不是这条）。
   - **剩下的两个嫌疑**（1.0.12 同时针对）：
     1. **镜像结构不合法**：分片 MP4（moof+mdat 成对）被我们按「文件头裁断」时，最后一个 mdat 被切开 → 整个文件被判损坏；
        非分片 MP4 也可能因为首个 GOP 的样本落在 40 MB 之外被切掉。
     2. **`AVAssetImageGenerator` 的 seek 语义**：它要按时间找样本，镜像里没有目标时间附近的数据就直接抛 decodeFailed；
        而播放是顺序解码，所以能播。
   - **1.0.12 的实测结果（关键证据）**：诊断升级后拿到结构行
     `ftyp@0 free@32 mdat@40(522MB) moov@547662742(412KB) · 视…` ——
     文件 522 MB、`moov` 在**尾部**、`mdat` 从 40 开始，镜像 48 MB 仍然 `-11821`。
     说明**根因不是「首帧没被覆盖」**，而是：镜像把 `mdat` 砍短后，`moov` 里按原始文件写的样本偏移全部越界，
     AVFoundation 直接判定电影文件损坏 —— 和首帧在不在镜像里无关。**所以对大文件做截断镜像这条路根本走不通。**
   - **1.0.13 的改法**：镜像只用于 ≤ 64 MB（能整份读进来、等于不截断）的片子；
     大文件改走 `smbstream://` + `AVAssetReader` 顺序解码，按样本表逐个区间取数据（只读 `moov` + 第一个 GOP），
     流量通常比 48 MB 的镜像还小。抽帧实现统一抽到 `VideoFrameDecoder`（reader 优先、generator 兜底）。
     诊断也拆成两条短句（`结构 …` / `抽帧失败…`），避免设置页一行显示不下被省略号截掉。
   - 1.0.12 的改法（保留作历史）：
     - 新增 `MP4Inspector`（顶层盒子扫描 + moov 内 trak/stsd/stsz/stco/elst 解析），镜像按结构装配：
       分片文件切在**完整 fragment 结尾**、不修补不改长度；普通文件按 `首个视频样本 offset+size` 保证覆盖到首帧。
     - 抽帧先用 **`AVAssetReader` + `AVAssetReaderTrackOutput`（BGRA）读第一个样本**，用 `CIImage` 套 `preferredTransform` 缩到 480；
       失败才用 generator 取第 0 秒（容差无限）。
     - 失败诊断升级成一行「镜像长度 + 结构摘要 + 解码器报错」，例如
       `抽帧失败（镜像 40 MB · ftyp@0 moov@32(6KB) mdat@6240(512MB) · 视频 avc1 1920×1080 首帧@6240+24576）：…`，
       以后看截图就能判断「首帧落点是否被镜像覆盖」「是不是分片」「编码是什么」。

18. **✅ 已修（1.0.13）：大图（`.bmp` 38–69 MB）有的出不来缩略图**
   - 现象：同目录 `懒懒睡不醒(*).bmp`，37–38.9 MB 的能出，69.1 MB 的全部显示照片占位图标。
   - 根因：`imageHardLimit = 64 MB` 直接把 69 MB 的文件挡掉，而且**挡掉时不写诊断**，所以设置页里看不到任何记录。
   - 修复：
     - 上限 64 → **160 MB**；超过 24 MB 改为**边读边写临时文件**、用 `CGImageSourceCreateWithURL` 解码缩略图
       （`ImageDownsampler.downsample(url:maxPixel:)`），避免 Data 和解码位图同时压在内存里；
     - 失败原因全部写进诊断：超出上限 / 只读到 xMB / 解码失败（带扩展名和大小）/ 读取失败，
       下次同类问题一眼能看出是「太大」还是「ImageIO 解不了这种 BMP 变体」。

19. **✅ 已修（1.0.14）：大文件视频封面仍报 `-11821`，但同一文件点开能正常播放**
   - 诊断（1.0.13）：`流式取帧失败 无法解码(-11821) / 无法解码(-11821)` ——
     **`AVAssetReader` 和 `AVAssetImageGenerator` 都失败**，而播放正常。
   - 结论：不是解码能力问题，是这两种取帧方式**对自定义资源加载器不友好**：
     reader 要按 `moov` 里的样本表逐个区间随机取数、generator 要按时间 seek，
     取不到目标区间就直接抛 `-11821`（`AVError.decodeFailed`）；而播放器是顺序预读，所以能播。
   - 修复：新增 `VideoFrameDecoder.playerFrame`，用 **`AVPlayer` + `AVPlayerItemVideoOutput` 截第一帧**
     —— 与 App 内播放完全同一条管线（`smbstream://` + 同一个 loader），静音、不接管音频会话、
     拿到画面立刻停。取帧顺序按资产类型排：**流式资产 `播放器 → 顺序解码 → 按时间取帧`**，
     本地镜像文件 `顺序解码 → 按时间取帧 → 播放器`。
   - 硬件/后台注意：这条路要「真的播一下」，因此**只在前台、缩略图闸门内（一次一个）**执行；
     12 秒超时，取消立即停。

20. **✅ 已修（1.0.14）：缩略图「先冒出一张靠后的，然后才从第一张开始按顺序」**
   - 根因：闸门 `acquire` 只要发现空闲就**立刻放行**，不看序号。几十个格子的 `.task` 几乎是同时
     发起的，但「谁先跑到闸门」取决于 SwiftUI 起任务的顺序 + 每格读磁盘缓存花的毫秒数，
     没有保证 → 偶尔一张靠后的图抢到第一个名额。
   - 修复：`OrderedLimiter` 改成**先聚集再选拔** —— 从空闲转忙时先睡 `settleMilliseconds`（250 ms），
     等这一批格子把序号登记完，再挑最小的放行；之后队列已排满，逐个挑最小序号即可，不再额外等待。
     连续滚动时（两次请求间隔 < 400 ms）视为同一批，不重复等待。
   - 代码位置：`Sources/Services/AsyncLimiter.swift`；调用点 `ThumbnailStore.displayLimiter`。

21. **✅ 1.0.15 新增：播放器手势 + 手势自定义**
   - 结构：`PlayerGestureLayer`（`UIViewRepresentable` + `UITap×2 / UIPan / UILongPress / UIPinch`）
     只负责把识别结果翻译成 `PlayerGestureEvent`；`VideoPlayerView` 里的 `handle(_:)` 决定动作；
     `PlayerGestureSettings` 存用户选择，播放器和设置页读同一份，改完立刻生效。
   - 关键约束（改这里前必看）：
     - **单击必须 `singleTap.require(toFail: doubleTap)`**，否则每次双击都会先闪一下控制条。
     - **手势层必须放在控件下面**（ZStack 顺序：画面 → 亮度遮罩 → 手势层 → HUD → 控件），
       否则按钮和进度条点不动；遮罩与 HUD 都要 `allowsHitTesting(false)`。
     - **拖动方向在首次位移 > 12pt 时锁定**（横向→进度、纵向→亮度/音量），不做这种锁定的话
       斜着拖会同时改两个值。
     - **拖进度过程中不 seek**，只在 `.ended` 落一次；`model.isSeeking` 在拖动期间为 true，
       用来挡住 0.25 秒的时间回调，否则 HUD 会被真实进度抢回去。
     - **亮度 = 一层黑色 `Color.black.opacity(dimLevel)`**（0~0.85），不改系统亮度：
       不需要权限、退出即恢复、不会影响用户其它 App；代价是不能调得比原始更亮。
     - **音量直接写 `player.volume`**（0~1），不接管系统音量、不弹 HUD。
     - **长按加速**要记录「按住前是否在播」，松手后回到原状态（`wasPlayingBeforeHold`）；
       直接把 `player.rate` 设为 1 会让暂停的片子莫名其妙开始播。
     - **捏合缩放**给承载 `AVPlayerLayer` 的 view 套 `CGAffineTransform`，范围 1~4 倍，
       窗口外自然被屏幕裁掉；退出播放页 `@State` 归零，不会带到下一个视频。
   - 已知取舍：拖动进度 HUD 只显示「目标时间」，没有缩略图预览（SMB 上逐帧预览太重，
     以后要用 1.0.13 的 `VideoFrameDecoder` 做「每 5% 抽一帧」的预览条）。

## 8. 约定（改代码前先看）

- **不要提交 `SMBViewer.xcodeproj`**：改工程必须改 `project.yml`。
- **换行统一 LF**：`.gitattributes` 已强制 `* text=auto eol=lf`，别用会把 `.sh` 变 CRLF 的编辑器保存，否则 macOS 上 `bad interpreter: ^M`。
- **`scripts/build-ipa.sh` 必须保持 100755**（`git update-index --chmod=+x`）。
- **新增文件无需手动加进工程**：`project.yml` 里 `sources: Sources` 是整目录递归。
- **CI 步骤名用中文**；`uses:` 保持官方 action 原样。
- 提交信息沿用 `feat:` / `fix:` / `ci:` / `chore:` 前缀。
- **不要**把 `Packages/AMSMB2/Package.swift` 的 `type: .static` 改回 `.dynamic`，也不要改回远程 URL 依赖，否则闪退问题会复发（CI 有断言兜底）。

### 发版取包（本地交付目录）

CI 通过后把 IPA 交付到 `D:\下载\互传`，命名 `SMBViewer-vX.Y.Z-unsigned.ipa`。

- 该目录**只处理 `SMBViewer-*.ipa`**：保留最新一版、删除其余 SMBViewer 旧包。
- 同目录下的其它项目文件（`LanBox-*.apk`、`Monitor-iOS-*.zip`、`OpenWrt-Monitor-*.apk`、各类 `.md/.txt`）**一律不动**。
- 交付前自检三项并记录：版本号、`Payload` 内是否还有 `Frameworks` 目录（应无）、`otool -L` 是否只剩系统库。

### 依赖升级（AMSMB2）

```bash
git clone --recurse-submodules https://github.com/amosavian/AMSMB2.git /tmp/amsmb2
rm -rf Packages/AMSMB2/AMSMB2 Packages/AMSMB2/Dependencies/libsmb2/lib Packages/AMSMB2/Dependencies/libsmb2/include
cp -r /tmp/amsmb2/AMSMB2/*.swift Packages/AMSMB2/AMSMB2/
cp -r /tmp/amsmb2/Dependencies/libsmb2/lib /tmp/amsmb2/Dependencies/libsmb2/include Packages/AMSMB2/Dependencies/libsmb2/
# 手动核对 Package.swift：保持 type: .static、保持 exclude 列表与上游一致
```

升级后重点回归：`connectShare`、`contentsOfDirectory`、`contents(atPath:range:)`、`downloadItem` 这 4 个 API。

---

## 9. 版本记录

> 每次发版必须在表格顶部追加一行，并同步更新第 2 节「当前状态」。

| 版本 | 日期 | 变更 |
| --- | --- | --- |
| 1.0.11 | 2026-10-31 | 缩略图严格按顺序出现：图片/视频合并成一道有序闸门（`limit: 1` + 60 ms 宽限 + 队伍优先），修掉跨类型乱序与抢名额；视频抽帧先零容差取第 0 秒关键帧，失败信息附编码 fourcc 与流式兜底的报错 |
| 1.0.12 | 2026-10-31 | 视频封面抽帧改为「按结构装配镜像 + 顺序解码」：新增 `MP4Inspector` 解析盒子/轨道/首帧落点，分片 MP4 切在完整 fragment 边界不再截断、普通 MP4 按首帧位置决定镜像长度；抽帧先 `AVAssetReader` 顺读第一帧、失败再退回 `AVAssetImageGenerator`；失败诊断附带结构摘要（盒子布局 + 编码 + 首帧落点）；诊断保留条数 5→8 |
| 1.0.13 | 2026-10-31 | 视频封面按大小分流：≤64MB 走本地镜像、>64MB 走 `smbstream://` + `AVAssetReader` 顺序解码（截断镜像会让样本偏移越界→-11821，大文件镜像方案废弃）；抽帧逻辑统一到 `VideoFrameDecoder`；诊断拆成「结构 / 失败」两条短句；大图上限 64→160MB、>24MB 走临时文件解码，失败原因全部落诊断 |
| 1.0.14 | 2026-10-31 | 大文件视频封面改用**播放器管线**取帧（`AVPlayer` + `AVPlayerItemVideoOutput`，与播放同一条路），修掉 `smbstream://` 上 `AVAssetReader`/`AVAssetImageGenerator` 一律 `-11821` 的问题；`OrderedLimiter` 改为**空闲后先聚集 250 ms 再挑最小序号**，修掉「先冒出一张靠后的缩略图」；诊断按「播放器 / 顺序解码 / 按时间取帧」逐项记录失败原因 |
| 1.0.15 | 2026-11-01 | 播放器新增**可自定义手势**：单击显隐控件、双击（两侧快退/快进 + 中间播放暂停，可改为播放暂停/单向/关闭）、左右拖动拖进度（松手才 seek）、上下拖动（左亮度右音量，可改为纯音量/纯亮度）、长按 1.5×/2×/3× 倍速（松手恢复）、双指捏合缩放 1~4 倍；新增 `PlayerGestureLayer`、`PlayerGestureSettings`，设置页加「播放手势」分组与一键恢复默认 |
| 1.0.10 | 2026-10-31 | 网格去掉灰底：有图时只画图片本身（圆角裁在图上），无图才铺灰块；图片在展示框内居中（横屏上下、竖屏左右留白均匀），播放角标改挂到图片左下角；视频封面镜像的头部长度改为 12→24→40 MB 逐级重试（修复单个 GOP 大于 12 MB 时抽帧失败），并把 AVFoundation 真实报错写进设置页诊断 |
| 1.0.9 | 2026-10-31 | 网格改为固定展示框（`TileAspect.box` 宽:高 ≈ 1:1.15）：缩略图完整显示并贴框顶部，横屏图下方留白、竖屏图不再被撑成过高的竖条，文件名固定两行高度，同一行三列顶端与文字行全部齐平；删除 1.0.8 的 `onAspectChange` / `aspects` 真实比例管线 |
| 1.0.8 | 2026-10-31 | 缩略图网格改为按真实宽高比显示：去掉写死的照片 3:4 / 视频 16:9，`ThumbnailImage` 加载后用 `onAspectChange` 回传真实比例、`BrowserView` 存 `aspects` 再喂 `.aspectRatio`，竖屏撑竖条、横屏撑横条，同一行顶部对齐、底部随内容错落；文件名/大小/日期字号微调（1.0.9 已废弃该方案） |
| 1.0.7 | 2026-10-31 | 修复大文件视频封面始终出不来：镜像改为「文件头 12 MB + moov + 修正 mdat 声明长度」的连续小文件（不再生成与原片等大的稀疏文件）；播放页弃用 AVKit `VideoPlayer`，改 `AVPlayerLayer` + 自绘控件并清空 Now Playing，去掉灵动岛媒体胶囊；缩略图改用 `OrderedLimiter` 按网格顺序加载；设置页新增缩略图失败原因诊断 |
| 1.0.6 | 2026-10-31 | 修复 16 MB 以上图片缩略图「只显示上半张、下半截变灰」：去掉分阶段截断读取，一律读满再解码，读不满直接放弃（缓存版本递增到 3）；缩略图由 `.scaledToFill` 裁切改为 `.scaledToFit` 完整显示，卡片比例按照片 3:4 / 视频 16:9 / 文件夹 1:1 |
| 1.0.5 | 2026-10-31 | 修复大文件 MP4 无封面：视频封面改用「稀疏镜像」抽帧（只读 moov + 首个关键帧，约 10 MB），流式抽帧降为兜底；设置页两个确认框由 confirmationDialog 改为 alert，避免 iOS 26/27 锚定到按钮上方压住开关；清理完成提示改为底部轻提示 |
| 1.0.4 | 2026-10-31 | 目录页改版：三列网格 + 缩略图下方两行文件名（中间省略）/ 大小 / 日期；新增目录内搜索、6 种排序、网格⇄列表切换 |
| 1.0.3 | 2026-10-31 | 修复 BMP/TIFF 缩略图全黑（改为整份读取 + 完整解码兜底）；修复 1GB 以上 MP4 无封面（去掉 4MB 单次响应限制、视频额度 10MB→32MB）；缩略图缓存版本号递增以失效旧的黑图 |
| 1.0.2 | 2026-10-31 | 重写缩略图加载链路：任务去重/取消传播/失败负缓存/图片与视频独立并发闸门；视频封面加 10 MB 字节预算，不再整部下载；`SMBConnection.read` 支持传输中止；看图页只加载当前页；缓存自动清理改为 20 秒节流；设置页新增缩略图开关 |
| 1.0.1 | 2026-10-31 | 修复 iOS 27 上轻松签/ESign 重签后启动闪退：AMSMB2 由 SPM 动态框架改为 vendored 静态链接（`Packages/AMSMB2`），产物不再含 `Frameworks/`；CI 加静态链接断言与包结构自检 |
| 1.0.0 | 2026-10-31 | 首个版本：SMB 浏览、看图（缩放/滑动）、视频边下边播 + 下载兜底、缩略图双层缓存、深浅主题、缓存上限与自动清理、多服务器管理；CI 用 `xcode-27` 出未签名 IPA |

---

## 10. 新会话接手清单

1. 读本文件（尤其第 2 节状态、第 7 节待办）。
2. `git log --oneline` 看最近改动，`git status` 确认工作区干净。
3. 要改 UI → `Sources/Views`；改连接/性能 → `Services`；改版本号 → `project.yml`。
4. 改完：更新本文件第 2/9 节 → commit → push → 等 CI 绿 → 把 Artifact 链接给用户。
5. 用户报「构建失败」时，先要 `归档构建（不签名）` 步骤的日志，不要凭猜改代码。
