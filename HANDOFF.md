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
| 版本 | `1.0.0`（build 1），见 `project.yml` 的 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` |
| 构建 | ✅ 已在 GitHub Actions `xcode-27` 运行器上**全流程跑通**（检出→选 Xcode→XcodeGen→解析依赖→archive→打包→上传，全部成功） |
| 验证方式 | CI 编译通过即视为可编译；**未在真机上做过功能回归**（无设备/无 Mac），功能层面属于「代码审查过、逻辑自洽」状态 |
| 已知待办 | 见第 7 节 |

> 如果 CI 红了，第一件事是看 `归档构建（不签名）` 那一步的日志，Xcode 报错通常集中在那里。

---

## 3. 技术栈与关键决策

- **UI**：SwiftUI，`NavigationStack` + `@MainActor` 观察模型，无第三方 UI 库。
- **SMB**：[AMSMB2](https://github.com/amosavian/AMSMB2) 4.x（SPM，封装 libsmb2）。**只用到** `connectShare` / `contentsOfDirectory` / `contents(atPath:range:)` / `downloadItem` / `attributesOfItem`，所以升级 AMSMB2 大版本时要重点核这几个签名。
- **工程生成**：XcodeGen（`project.yml` 是唯一工程定义，`SMBViewer.xcodeproj` 被 `.gitignore` 排除，**不要提交 pbxproj**）。
- **视频边下边播**：自定义 scheme `smbstream://` + `AVAssetResourceLoaderDelegate`，把 AVFoundation 的字节请求翻译成 SMB 区间读取（每次 512 KB）。
- **缩略图**：图片走 ImageIO 降采样（480px），视频用 `AVAssetImageGenerator` 取第 1 秒；`NSCache` + 磁盘双层；`AsyncLimiter` 限 4 并发，避免打满 NAS。
- **缓存**：`Library/Caches/SMBViewer/{Thumbnails,Media}`，文件名 = `SHA256(服务器ID + 路径 + 大小 + 修改时间)`，服务器文件变了自动失效；上限 200MB/500MB/1GB/2GB/5GB/不限，超限按写入时间删到 80%，启动/进后台/写缓存时触发。
- **密码**：优先钥匙串；不可用（自签名场景常见）时退化为本地混淆存储 → 属于**已知安全折中**，UI 里已提示。
- **主题**：`@AppStorage` + `preferredColorScheme`，三档（跟随系统/浅色/深色）。

---

## 4. 文件地图

```
project.yml                     工程定义（依赖、Build Settings、scheme）★改配置先看这里
Config/Info.plist               权限文案、URL scheme、文件共享开关
Sources/
  App/SMBViewerApp.swift        @main，注入 AppModel / 缓存
  App/RootView.swift            TabView：服务器列表 + 设置
  App/AppModel.swift            服务器列表持久化（UserDefaults）、连接状态
  Models/SMBServer.swift        服务器配置模型 + 地址归一化（粘贴 smb:// 也能识别）
  Models/FileItem.swift         SMB 目录项解析、MediaKind 判定（按扩展名）
  Models/PreviewRequests.swift  预览页的跳转参数
  Services/SMBConnection.swift  ★actor，AMSMB2 的唯一直连封装
  Services/SMBAssetLoader.swift ★AVPlayer 的 SMB 区间读取代理（边下边播核心）
  Services/ThumbnailStore.swift 缩略图生成 + 双层缓存
  Services/MediaStore.swift     大图 / 下载到本地播放
  Services/CacheManager.swift   缓存统计、清理、上限策略（@MainActor 可观察）
  Services/CredentialStore.swift 密码存取（钥匙串 + 退化）
  Services/AsyncLimiter.swift   async 信号量，限并发
  ViewModels/BrowserModel.swift 目录列举、排序、加载状态
  Views/*.swift                 服务器列表/编辑、浏览、看图、播放、设置
  Views/Components/MediaTiles.swift 网格/列表单元格（含缩略图占位）
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

未签名 IPA 必须重签：Sideloadly / AltStore / 爱思助手（个人 Apple ID，7 天重签一次）、TrollStore（免签，限支持版本）、或自有证书 `codesign` 全量重签。重签工具会自动处理内嵌的 `AMSMB2.framework`。首次连接局域网需允许「本地网络」权限。

---

## 7. 已知限制 / 待办

1. **MKV/AVI 等容器播不了** —— AVFoundation 解码头限制，不是连接问题；播放页已提供「下载到本地播放」兜底。可考虑后续接 VLCKit（会显著增加包体积与 LGPL 复杂度）。
2. **只读**：不做上传/删除/重命名，是刻意设计（降低误操作风险）。要加的话从 `SMBConnection` 扩方法 + `BrowserView` 长按菜单入手。
3. **单共享**：一台服务器只连一个共享名，没有「先列共享再选」的流程。
4. **无真机回归**：功能正确性依赖代码审查，用户反馈时优先怀疑 `SMBConnection` 的路径拼接与 `SMBAssetLoader` 的 range 换算。
5. **缩略图首次慢**：视频要读文件头（`moov` 在尾部时还要读末尾），属预期行为。

---

## 8. 约定（改代码前先看）

- **不要提交 `SMBViewer.xcodeproj`**：改工程必须改 `project.yml`。
- **换行统一 LF**：`.gitattributes` 已强制 `* text=auto eol=lf`，别用会把 `.sh` 变 CRLF 的编辑器保存，否则 macOS 上 `bad interpreter: ^M`。
- **`scripts/build-ipa.sh` 必须保持 100755**（`git update-index --chmod=+x`）。
- **新增文件无需手动加进工程**：`project.yml` 里 `sources: Sources` 是整目录递归。
- **CI 步骤名用中文**；`uses:` 保持官方 action 原样。
- 提交信息沿用 `feat:` / `fix:` / `ci:` / `chore:` 前缀。

---

## 9. 版本记录

> 每次发版必须在表格顶部追加一行，并同步更新第 2 节「当前状态」。

| 版本 | 日期 | 变更 |
| --- | --- | --- |
| 1.0.0 | 2026-10-31 | 首个版本：SMB 浏览、看图（缩放/滑动）、视频边下边播 + 下载兜底、缩略图双层缓存、深浅主题、缓存上限与自动清理、多服务器管理；CI 用 `xcode-27` 出未签名 IPA |

---

## 10. 新会话接手清单

1. 读本文件（尤其第 2 节状态、第 7 节待办）。
2. `git log --oneline` 看最近改动，`git status` 确认工作区干净。
3. 要改 UI → `Sources/Views`；改连接/性能 → `Services`；改版本号 → `project.yml`。
4. 改完：更新本文件第 2/9 节 → commit → push → 等 CI 绿 → 把 Artifact 链接给用户。
5. 用户报「构建失败」时，先要 `归档构建（不签名）` 步骤的日志，不要凭猜改代码。
