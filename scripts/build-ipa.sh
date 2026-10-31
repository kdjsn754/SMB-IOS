#!/usr/bin/env bash
# 在 macOS 上本地构建未签名 IPA（需要 Xcode 27 + Homebrew）
# 用法：
#   ./scripts/build-ipa.sh              # 自动使用 Xcode 27
#   XCODE_VERSION=26.6 ./scripts/...    # 指定其它主版本
#   XCODE_APP=/Applications/Xcode_27.0.app ./scripts/...   # 直接指定 App 路径
set -euo pipefail

cd "$(dirname "$0")/.."

XCODE_VERSION="${XCODE_VERSION:-27}"

pick_xcode() {
  # 1) 显式指定优先
  if [ -n "${XCODE_APP:-}" ]; then
    echo "$XCODE_APP"
    return
  fi
  # 2) 优先正式版（跳过 beta），同主版本取最新
  local pick="" app
  for app in $(ls -d /Applications/Xcode_${XCODE_VERSION}*.app 2>/dev/null | sort -V); do
    case "$app" in
      *[Bb]eta*) continue ;;
      *) pick="$app" ;;
    esac
  done
  # 3) 退回 beta / 其它命名
  if [ -z "$pick" ]; then
    pick=$(ls -d /Applications/Xcode_${XCODE_VERSION}*.app 2>/dev/null | sort -V | tail -1 || true)
  fi
  echo "$pick"
}

XCODE_APP_PATH="$(pick_xcode)"
if [ -n "$XCODE_APP_PATH" ]; then
  echo "==> 使用 Xcode：$XCODE_APP_PATH"
  export DEVELOPER_DIR="$XCODE_APP_PATH/Contents/Developer"
else
  echo "==> 未找到 /Applications/Xcode_${XCODE_VERSION}*.app，沿用系统当前 Xcode"
fi

echo "==> 当前工具链"
xcodebuild -version
echo "    iOS SDK: $(xcrun --sdk iphoneos --show-sdk-version)"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "==> 安装 XcodeGen"
  brew install xcodegen
fi

echo "==> 生成 Xcode 工程"
xcodegen generate

echo "==> 清理旧的构建产物"
rm -rf build
mkdir -p build

echo "==> Archive（关闭签名）"
xcodebuild archive \
  -project SMBViewer.xcodeproj \
  -scheme SMBViewer \
  -configuration Release \
  -sdk iphoneos \
  -destination "generic/platform=iOS" \
  -archivePath "$PWD/build/SMBViewer.xcarchive" \
  -derivedDataPath "$PWD/build/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  ONLY_ACTIVE_ARCH=NO

APP="$PWD/build/SMBViewer.xcarchive/Products/Applications/SMBViewer.app"
if [ ! -d "$APP" ]; then
  echo "构建产物不存在：$APP"
  exit 1
fi

echo "==> 打包 IPA"
mkdir -p build/Payload
cp -R "$APP" build/Payload/
rm -rf build/Payload/SMBViewer.app/_CodeSignature
cd build
zip -qry SMBViewer-unsigned.ipa Payload

echo "✅ 完成：$PWD/SMBViewer-unsigned.ipa"
