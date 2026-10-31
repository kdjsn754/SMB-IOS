# SMB 播放器（iOS · 未签名 IPA）

一个用 SwiftUI 写的轻量 iOS 客户端，直接连接局域网里的 SMB / SMB2 / SMB3 共享（群晖、威联通、Windows 共享、路由器挂载盘等），用来**看图片、放视频**，并自带完整的缓存管理。

工程里不带任何签名配置，配合 GitHub Actions 直接产出**未签名 IPA**，你再自行重签名安装。

> 接手 / 继续开发请看 [`HANDOFF.md`](HANDOFF.md)：里面有当前版本状态、文件地图、构建细节、已知待办和版本记录，**每次发版都会更新**。

---

## 功能

- **浏览共享目录**：网格 / 列表两种视图，文件夹优先排序，支持刷新与多级目录跳转。
- **看图**：全屏浏览、双指缩放、双击放大、左右滑动切换同目录图片。
- **放视频**：基于 `AVAssetResourceLoader` 的 **SMB 流式播放**，按需读取字节，不需要先下载整个文件（MP4 / MOV / M4V 等系统可解码格式）。若流式播放失败，可一键「下载到本地播放」兜底。
- **缩略图**：图片与视频都会生成缩略图（视频取最近关键帧），内存 `NSCache` + 磁盘缓存双层。图片并发 3、视频封面并发 1 各自限流；每张图读取上限 16 MB、视频封面额度 10 MB；只有屏幕上的项目才会加载，划走立刻中断传输；失败的文件 3 分钟内不再重试。设置页可分别关闭「图片缩略图」「视频封面」。
- **主题**：跟随系统 / 浅色 / 深色，即时切换（设置页）。
- **缓存管理**：
  - 设置页显示当前缓存占用（缩略图 / 图片与视频分开统计）；
  - 可设置上限：200 MB / 500 MB / 1 GB / 2 GB / 5 GB / 不限制；
  - 打开「超过上限自动清理」后，超过上限会按写入时间从旧到新删除，降到上限的 80%；
  - 支持「立即清理全部缓存」「仅清理缩略图」；
  - App 启动、进入后台、写入新缓存时都会自动检查一次。
- **多服务器管理**：保存多台 NAS 配置，密码优先存钥匙串，支持「测试连接」。
- 只读使用，不做任何写 / 删除 / 上传操作，不会影响服务器上的文件。

---

## 目录结构

```
.
├── HANDOFF.md                      # 交接说明（当前状态 / 待办 / 版本记录）
├── project.yml                     # XcodeGen 工程描述（SPM 依赖在这里声明）
├── Config/Info.plist               # 手写 Info.plist（含本地网络权限说明）
├── Sources/
│   ├── App/                         # 入口、全局状态、根视图
│   ├── Models/                      # SMBServer / FileItem / 预览请求
│   ├── Services/
│   │   ├── SMBConnection.swift      # AMSMB2 封装（actor）
│   │   ├── SMBAssetLoader.swift     # AVPlayer 的 SMB 区间读取代理
│   │   ├── ThumbnailStore.swift     # 缩略图调度：去重 / 限流 / 取消 / 负缓存
│   │   ├── CancellationBox.swift    # 传输取消标记与字节预算
│   │   ├── MediaStore.swift         # 大图 / 下载后播放
│   │   ├── CacheManager.swift       # 缓存统计、清理、上限策略
│   │   └── CredentialStore.swift    # 密码存储（钥匙串 + 退化方案）
│   ├── ViewModels/
│   ├── Views/
│   ├── Utilities/
│   └── Resources/Assets.xcassets    # AppIcon / AccentColor
├── Packages/AMSMB2/               # vendored 的 AMSMB2 + libsmb2（改成静态链接）
├── scripts/
│   ├── build-ipa.sh                 # macOS 本地构建未签名 IPA
│   └── make_icon.py                 # 生成 1024 图标（可选）
└── .github/workflows/build-ipa.yml  # 云端构建 + 产出 IPA
```

---

## 构建

### 方式一：GitHub Actions（推荐，不需要 Mac）

1. 新建一个仓库，把本目录所有文件推上去（默认分支 `main`）。
2. 打开仓库的 **Actions** 页面，选择「构建未签名 IPA」，点 **Run workflow**。
3. 构建完成后，在该次运行页面底部 **Artifacts** 下载 `SMBViewer-unsigned-ipa`，解压得到 `SMBViewer-unsigned.ipa`。
4. 如果推送 `v1.0.0` 这类 tag，IPA 会自动附加到对应的 Release 里。

> 云端使用 **`xcode-27` 运行器**（macOS 27 + Xcode 27 + iOS 27 SDK）。依赖已 vendor 进仓库，构建不需要联网拉包，约 6～12 分钟。
>
> 想换版本改 `.github/workflows/build-ipa.yml` 顶部的两处即可：`runs-on: xcode-27` → `macos-26` / `macos-15`，以及 `env.XCODE_VERSION: "27"` → 对应主版本号（工作流会在镜像里自动挑最新的正式版 Xcode，找不到 beta 时才退回 beta）。

### 方式二：本地 macOS

```bash
brew install xcodegen
chmod +x scripts/build-ipa.sh
./scripts/build-ipa.sh          # 默认挑 /Applications 下最新的 Xcode 27
# 产物：build/SMBViewer-unsigned.ipa
```

需要 **Xcode 27**（`DEVELOPER_DIR` 由脚本自动指向 `/Applications/Xcode_27*.app`，优先正式版）。本机装的是别的版本时：

```bash
XCODE_VERSION=26.6 ./scripts/build-ipa.sh
# 或直接指定
XCODE_APP=/Applications/Xcode_27.0.app ./scripts/build-ipa.sh
```

---

## 安装到 iPhone

未签名 IPA **不能直接双击安装**，必须重新签名：

| 工具 | 说明 |
| --- | --- |
| Sideloadly / AltStore / 爱思助手 | 用你自己的 Apple ID 重签后安装，免费证书 7 天需重签一次 |
| TrollStore | 免签名安装（仅支持的 iOS 版本），最省事 |
| 企业证书 / 个人开发者证书 | 用 `codesign` 手动重签整个 IPA 后再安装 |

App 只有一个可执行文件、没有内嵌动态框架（AMSMB2 已静态链接），所以重签工具不会漏签框架。系统要求 **iOS 16.0 及以上**。

首次连接局域网地址时，系统会弹出「本地网络」权限，必须点允许，否则连不上 NAS。

---

## 使用

1. `+` 添加服务器：
   - **主机地址**：`192.168.1.10` 或 `nas.local`（粘贴 `smb://192.168.1.10/Video` 也能自动识别主机）
   - **端口**：默认 445
   - **共享名称**：即 `smb://主机/共享名` 里的共享名，如 `Video`、`homes`、`share`
   - **用户名**：匿名访问填 `guest`
   - **密码**：Windows 微软账户可把用户名写成 `MicrosoftAccount\你的邮箱`
   - **域 / 工作组**：一般留空，域环境填写域名
2. 点「测试连接」确认能读到根目录，再保存。
3. 进入共享后点图片看大图、点视频播放。
4. 设置页可切换主题、调整缓存上限或立即清理缓存。

---

## 常见问题

**连接被拒绝 / 超时**
- 确认 NAS 已开启 SMB 服务、端口 445 可达；
- 群晖：控制面板 → 文件服务 → SMB → 启用；
- Windows：确认共享已开启，且防火墙允许「文件和打印机共享」；
- 部分路由器 / 运营商光猫会屏蔽 445。

**认证失败**
- 域环境要填「域」；
- Windows 微软账户用 `MicrosoftAccount\邮箱@example.com`；
- 关闭「仅允许 SMB2/SMB3 + 需要签名」的强制策略，或确认服务端允许 NTLM。

**MKV / AVI 播放不了**
iOS 的 AVFoundation 不负责这些容器的解码，流式播放会失败。可在播放页右上角选「下载到本地播放」，仍不行就说明系统不支持该编码（例如 DTS 音轨），建议在 NAS 端转成 MP4(H.264/AAC)。

**缩略图很慢 / 不显示**
视频封面需要读 `moov`（在文件尾时还要读末尾）与关键帧附近数据，首次 1～3 秒属正常；生成后写入磁盘缓存，第二次进入目录是秒开。
如果一直是灰色图标：
1. 设置 → 缩略图，确认「加载图片缩略图」开着（视频还要单独开「加载视频封面」）；
2. 点「重新尝试加载失败的缩略图」（失败会有 3 分钟冷却，避免反复打 NAS）；
3. 仍然不行说明该文件本身无法解码（如 RAW / 非常规 JPEG），属预期，可点开看大图验证。

**密码保存失败**
自签名安装时钥匙串可能不可用，此时会自动退化为本地混淆存储（非加密），所以请不要在共享设备上使用重要账号。

---

## 技术说明

- **SMB**：[AMSMB2](https://github.com/amosavian/AMSMB2)（封装 libsmb2），已 vendor 到 `Packages/AMSMB2` 并从 SPM 的 `.dynamic` 改成 **`.static`**，只用到 `connectShare` / `contentsOfDirectory` / `contents(range:)` / `downloadItem`。静态化的原因：动态框架会以 `Frameworks/AMSMB2.framework` 进包，用轻松签 / ESign 这类工具重签时常被漏签，iOS 上点开就闪退。
- **视频流式播放**：自定义 scheme `smbstream://`，`AVAssetResourceLoaderDelegate` 把 AVFoundation 的字节请求翻译成 SMB 的区间读取（每次 1 MB），因此可以边下边播、可拖动进度条。加载器带字节预算与取消机制，抽封面时不会被要求把整部影片读完。
- **缩略图**：图片用 `ImageIO` 降采样到 480px，避免整张大图进内存；视频用 `AVAssetImageGenerator` 走同一套流式读取，但只允许消耗 10 MB 额度。同一文件只生成一份缩略图，网格与列表共用。
- **缓存**：全部落在 `Library/Caches/SMBViewer/`（缩略图与媒体两个子目录），文件名是 `服务器ID + 路径 + 大小 + 修改时间` 的 SHA256，服务器上文件变了会自动失效。

## 自定义

改 `project.yml` 里的 `PRODUCT_BUNDLE_IDENTIFIER`（默认 `com.smbviewer.app`）、`MARKETING_VERSION`；想改 App 名称改 `Config/Info.plist` 的 `CFBundleDisplayName`。

## 许可

本项目代码可自由使用。依赖的 AMSMB2 为 MIT，但其内置的 libsmb2 为 **LGPL v2.1**，因此整体按 LGPL v2.1 对待。

注意：本工程现在是**静态链接** libsmb2，若你要对外分发二进制，LGPL v2.1 要求同时提供可重链接的目标文件（或改为动态链接）；个人自用安装、自己签名自己装不受此约束。
