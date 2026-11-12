#!/bin/zsh
# 릴리스 빌드 후 build/GodDB.app 번들을 만든다. (Finder 더블클릭 / 응용 프로그램 폴더로 복사 가능)
set -e
cd "$(dirname "$0")/.."
swift build -c release --product GodDB
# iCloud 폴더(문서)에서는 File Provider 가 확장 속성을 계속 붙여 서명이 깨진다.
# 그래서 iCloud 밖(임시 폴더)에서 조립·서명하고, 끝나면 build/ 로 복사한다.
WORK="${TMPDIR:-/tmp}/goddb-build"
APP="$WORK/GodDB.app"
rm -rf "$WORK"; mkdir -p "$WORK"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/GodDB "$APP/Contents/MacOS/GodDB"
# 앱 아이콘 (scripts/draw-icon.swift 로 만든 Resources/AppIcon.icns)
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Homebrew 라이브러리(FreeTDS, OpenSSL)를 앱 안(Contents/Frameworks)에 넣는다.
# 안 넣으면 Homebrew 가 없는 맥에서 실행하자마자 "예기치 않게 종료" 된다.
FW="$APP/Contents/Frameworks"
mkdir -p "$FW"
BIN="$APP/Contents/MacOS/GodDB"
brew_deps() { otool -L "$1" | tail -n +2 | awk '{print $1}' | grep '^/opt/homebrew/' || true; }
typeset -A done_libs
queue=("$BIN")
while (( ${#queue} )); do
  file="${queue[1]}"; queue=("${(@)queue[2,-1]}")
  for dep in $(brew_deps "$file"); do
    name="${dep:t}"
    if [[ -z "${done_libs[$name]}" ]]; then
      done_libs[$name]=1
      cp -L "$dep" "$FW/$name"
      chmod u+w "$FW/$name"
      install_name_tool -id "@rpath/$name" "$FW/$name" 2>/dev/null
      queue+=("$FW/$name")
    fi
    install_name_tool -change "$dep" "@rpath/$name" "$file" 2>/dev/null
  done
done
for lib in "$FW"/*.dylib(N); do
  install_name_tool -add_rpath "@loader_path" "$lib" 2>/dev/null || true
done
install_name_tool -add_rpath "@executable_path/../Frameworks" "$BIN" 2>/dev/null || true
install_name_tool -delete_rpath "/opt/homebrew/opt/freetds/lib" "$BIN" 2>/dev/null || true
for lib in "$FW"/*.dylib(N); do codesign --force --sign - "$lib" >/dev/null 2>&1; done
if otool -L "$BIN" "$FW"/*.dylib(N) | grep -q '/opt/homebrew/'; then
  echo "오류: 아직 Homebrew 경로를 참조하는 라이브러리가 있어요." >&2
  exit 1
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>GodDB</string>
  <key>CFBundleDisplayName</key><string>GodDB</string>
  <key>CFBundleIdentifier</key><string>local.goddb.app</string>
  <key>CFBundleExecutable</key><string>GodDB</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.7.5</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSLocalNetworkUsageDescription</key><string>사내망/로컬 네트워크의 DB 서버에 접속하기 위해 필요해요.</string>
</dict>
</plist>
PLIST
# iCloud 폴더의 확장 속성(FinderInfo 등)이 있으면 서명이 깨진다 → 지우고 서명, 실패하면 중단
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
# 로컬 실행용 사본
rm -rf build/GodDB.app; mkdir -p build
ditto --norsrc --noextattr "$APP" build/GodDB.app
# Finder/Dock 아이콘 캐시가 예전 등록(아이콘 없던 때)을 쓰지 않도록 다시 등록
touch build/GodDB.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f build/GodDB.app >/dev/null 2>&1 || true
echo "서명된 앱: $APP"
echo "완료: $(pwd)/build/GodDB.app"
