#!/bin/bash
# Builds ExplorerMac.app. Pass --release for the optimised universal binary.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG=debug
ARCH_FLAGS=()
if [[ "${1:-}" == "--release" ]]; then
    CONFIG=release
    # Universal so the same bundle runs on Apple Silicon and Intel.
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

APP="build/ExplorerMac.app"
CONTENTS="$APP/Contents"

echo "==> Compiling ($CONFIG)"
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/ExplorerMac"

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/ExplorerMac"
cp -R Resources/Fonts Resources/Icons "$CONTENTS/Resources/"
cp Resources/ExplorerMac.icns "$CONTENTS/Resources/"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                 <string>ExplorerMac</string>
    <key>CFBundleDisplayName</key>          <string>文件资源管理器</string>
    <key>CFBundleIdentifier</key>           <string>local.explorermac</string>
    <key>CFBundleExecutable</key>           <string>ExplorerMac</string>
    <key>CFBundleIconFile</key>             <string>ExplorerMac</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleShortVersionString</key>   <string>0.1</string>
    <key>CFBundleVersion</key>              <string>1</string>
    <key>LSMinimumSystemVersion</key>       <string>13.0</string>
    <key>NSHighResolutionCapable</key>      <true/>
    <!-- Explorer reads the user's whole disk; without this the app is
         confined to its container and every listing comes back empty. -->
    <key>NSDesktopFolderUsageDescription</key>  <string>浏览桌面文件夹</string>
    <key>NSDocumentsFolderUsageDescription</key><string>浏览文档文件夹</string>
    <key>NSDownloadsFolderUsageDescription</key><string>浏览下载文件夹</string>
    <key>NSRemovableVolumesUsageDescription</key><string>浏览可移动驱动器</string>
</dict>
</plist>
PLIST

# Ad-hoc signature keeps macOS from killing the unsigned binary on launch.
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "==> Built $APP"
du -sh "$APP" | awk '{print "    size: " $1}'
