// swift-tools-version:6.0
//
// 本目录是 AMSMB2（https://github.com/amosavian/AMSMB2）的 vendored 副本。
//
// 相对上游只改了两处，目的都是让产物里**不再出现动态框架**：
//   1. product 的 `type` 从 `.dynamic` 改成 `.static`；
//   2. 去掉 swift-system / swift-atomics 两个外部依赖（前者只在非 Darwin 平台用，
//      后者只有单元测试用），于是整个包自包含，CI 不需要再联网拉依赖。
//
// 为什么这么做：动态框架会以 `SMBViewer.app/Frameworks/AMSMB2.framework` 形式进入 IPA，
// 用「轻松签 / ESign」这类工具重签时经常只签主程序、漏签嵌套框架，导致 iOS 27 上点开即闪退。
// 改成静态链接后 App 只有一个可执行文件，不存在漏签问题。
//
// 目录内容：
//   AMSMB2/                     Swift 层（11 个文件，与上游一致）
//   Dependencies/libsmb2/lib    libsmb2 C 源码
//   Dependencies/libsmb2/include 头文件（含 apple / smb2 子目录）
//
// 升级上游时：重新拷贝上述两个目录 + 保持本文件的差异，然后跑一次 CI 验证。
import PackageDescription

let package = Package(
    name: "AMSMB2",
    platforms: [
        .iOS(.v14),
        .macOS(.v11),
        .macCatalyst(.v14),
        .tvOS(.v14),
        .watchOS(.v7),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "AMSMB2",
            type: .static,
            targets: ["AMSMB2"]
        ),
    ],
    targets: [
        .target(
            name: "libsmb2",
            path: "Dependencies/libsmb2",
            exclude: [
                "lib/CMakeLists.txt",
                "lib/libsmb2.syms",
                "lib/Makefile.am",
                "lib/Makefile.AMIGA",
                "lib/Makefile.AMIGA_AROS",
                "lib/Makefile.AMIGA_OS3",
                "lib/Makefile.PS3_PPU",
                "lib/ps2",
            ],
            sources: [
                "lib",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("include/apple"),
                .headerSearchPath("include/smb2"),
                .headerSearchPath("lib"),
                .define("_U_", to: "__attribute__((unused))"),
                .define("HAVE_CONFIG_H", to: "1"),
            ]
        ),
        .target(
            name: "AMSMB2",
            dependencies: ["libsmb2"],
            path: "AMSMB2"
        ),
    ]
)

for target in package.targets {
    target.swiftSettings = [.enableUpcomingFeature("ExistentialAny")]
}
