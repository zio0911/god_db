#!/bin/zsh
# 릴리스 빌드 후 build/갓디비.app 번들을 만든다. (Finder 더블클릭 / 응용 프로그램 폴더로 복사 가능)
set -e
cd "$(dirname "$0")/.."
swift build -c release --product GodDB
APP="build/갓디비.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/GodDB "$APP/Contents/MacOS/GodDB"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>갓디비</string>
  <key>CFBundleDisplayName</key><string>갓디비</string>
  <key>CFBundleIdentifier</key><string>local.goddb.app</string>
  <key>CFBundleExecutable</key><string>GodDB</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.6.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSLocalNetworkUsageDescription</key><string>사내망/로컬 네트워크의 DB 서버에 접속하기 위해 필요해요.</string>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "완료: $(pwd)/$APP"
