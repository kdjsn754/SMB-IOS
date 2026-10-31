#!/usr/bin/env bash
# 在 macOS 上本地构建未签名 IPA（需要 Xcode 16+ 与 Homebrew）
set -euo pipefail

cd "$(dirname "$0")/.."

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
