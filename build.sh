#!/bin/zsh
# 构建 Clawd.app（Apple 芯片 + Intel 通用版）
#   ./build.sh            只构建，产物在 build/Clawd.app
#   ./build.sh install    构建并安装到 ~/Applications，然后启动
#   ./build.sh dist       构建并打包 dist/Clawd-<版本>.dmg 和 .zip
#   ./build.sh demo       重新录制 docs/ 里的演示 GIF（需要 python3 + Pillow）
set -e
cd "${0:A:h}"
VERSION="1.1.0"
BUILD="$PWD/build"
APP="$BUILD/Clawd.app"

build() {
  rm -rf "$BUILD"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/rime"
  echo "→ 编译（arm64 + x86_64）"
  for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -target $arch-apple-macos13.0 \
      -framework AppKit -framework ServiceManagement -framework SwiftUI \
      Sources/Clawd.swift -o "$BUILD/Clawd-$arch"
  done
  lipo -create "$BUILD/Clawd-arm64" "$BUILD/Clawd-x86_64" -output "$APP/Contents/MacOS/Clawd"
  rm "$BUILD/Clawd-arm64" "$BUILD/Clawd-x86_64"

  echo "→ 生成图标"
  local iconset="$BUILD/Clawd.iconset"; mkdir -p "$iconset"
  for s in 16 32 128 256 512; do
    "$APP/Contents/MacOS/Clawd" --render-icon "$iconset/icon_${s}x${s}.png" $s
    "$APP/Contents/MacOS/Clawd" --render-icon "$iconset/icon_${s}x${s}@2x.png" $((s * 2))
  done
  iconutil -c icns "$iconset" -o "$APP/Contents/Resources/Clawd.icns"
  rm -rf "$iconset"

  echo "→ 打包输入法配置"
  cp Resources/rime/squirrel.custom.yaml Resources/rime/clawd.lua Resources/rime/clawd_punct.lua "$APP/Contents/Resources/rime/"

  cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.clawd.companion</string>
  <key>CFBundleName</key><string>Clawd</string>
  <key>CFBundleDisplayName</key><string>Clawd 伴随</string>
  <key>CFBundleExecutable</key><string>Clawd</string>
  <key>CFBundleIconFile</key><string>Clawd</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

  codesign --force --deep --sign - "$APP" >/dev/null 2>&1
  echo "✓ 构建完成：$APP"
}

case "${1:-}" in
  install)
    build
    pkill -x Clawd 2>/dev/null || true
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/Clawd.app"
    cp -R "$APP" "$HOME/Applications/Clawd.app"
    open "$HOME/Applications/Clawd.app"
    echo "✓ 已安装到 ~/Applications/Clawd.app"
    ;;
  dist)
    build
    rm -rf dist; mkdir -p dist
    ditto -c -k --keepParent "$APP" "dist/Clawd-$VERSION.zip"
    stage="$BUILD/dmg"; rm -rf "$stage"; mkdir -p "$stage"
    cp -R "$APP" "$stage/"; ln -s /Applications "$stage/应用程序"
    hdiutil create -volname "Clawd $VERSION" -srcfolder "$stage" -ov -format UDZO "dist/Clawd-$VERSION.dmg" >/dev/null
    rm -rf "$stage"
    (cd dist && shasum -a 256 * > SHA256SUMS.txt)
    echo "✓ 已打包："; ls -lh dist
    ;;
  demo)
    build
    # 每行：GIF 名字、皮肤、剧本（空 = 打字和上屏；nap = 打瞌睡；love = 打「猪咪」）
    for spec in "classic classic" "witch witch" "side side" "striker striker" "siu siu" "nap sleepy nap" "love classic love"; do
      set -- ${=spec}
      rm -rf "$BUILD/frames-$1"
      "$APP/Contents/MacOS/Clawd" --render-demo "$BUILD/frames-$1" $2 ${3:-}
      ${PYTHON:-python3} scripts/make_gif.py "$BUILD/frames-$1" "docs/demo-$1.gif"
    done
    "$APP/Contents/MacOS/Clawd" --render-sheet docs/sprites.png
    "$APP/Contents/MacOS/Clawd" --render-icon docs/icon.png 256
    ;;
  "") build ;;
  *) echo "用法：./build.sh [install|dist|demo]"; exit 1 ;;
esac
