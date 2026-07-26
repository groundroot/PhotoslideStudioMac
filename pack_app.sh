#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
PRODUCT_NAME="DreamMediaSlideshowStudio"
APP_NAME="PhotoslideStudio"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
DIST_DIR="$ROOT_DIR/dist"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICON_SOURCE="$ROOT_DIR/../assets/AppIcon.icns"
XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
VERSION_FILE="$ROOT_DIR/VERSION"
SCRATCH_DIR="$ROOT_DIR/.swiftpm-build"
NAS_VERSION_ROOT="/Volumes/미디어/01_Optisigns/00_App/Photo APP/Version"

require_universal_binary() {
  local path="$1"
  local name="$2"
  local archs
  if [[ ! -f "$path" ]]; then
    echo "Error: $name binary not found at $path" >&2
    exit 1
  fi
  archs="$(/usr/bin/lipo -archs "$path" 2>/dev/null || true)"
  if [[ "$archs" != *"x86_64"* || "$archs" != *"arm64"* ]]; then
    echo "Error: $name is not a universal binary (found: ${archs:-unknown})" >&2
    exit 1
  fi
}

if [[ ! -f "$VERSION_FILE" ]]; then
  cat > "$VERSION_FILE" <<EOF
SHORT_VERSION=1.0.0
BUILD_NUMBER=0
EOF
fi

source "$VERSION_FILE"
if [[ "${SHORT_VERSION:-}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  VERSION_MAJOR="${match[1]}"
  VERSION_MINOR="${match[2]}"
  VERSION_PATCH="${match[3]}"
else
  VERSION_MAJOR=1
  VERSION_MINOR=0
  VERSION_PATCH=0
fi

SHORT_VERSION="${VERSION_MAJOR}.${VERSION_MINOR}.$((VERSION_PATCH + 1))"
BUILD_NUMBER=$((BUILD_NUMBER + 1))

VERSIONED_FOLDER_NAME="$SHORT_VERSION"
VERSIONED_APP_NAME="${APP_NAME}-${SHORT_VERSION}.app"
VERSIONED_ZIP_NAME="${APP_NAME}-${SHORT_VERSION}-universal.zip"
LOCAL_VERSION_DIR="$DIST_DIR/$VERSIONED_FOLDER_NAME"
LOCAL_VERSIONED_APP_PATH="$LOCAL_VERSION_DIR/$VERSIONED_APP_NAME"
LOCAL_VERSIONED_ZIP_PATH="$LOCAL_VERSION_DIR/$VERSIONED_ZIP_NAME"
NAS_VERSION_DIR="$NAS_VERSION_ROOT/$VERSIONED_FOLDER_NAME"
NAS_VERSIONED_APP_PATH="$NAS_VERSION_DIR/$VERSIONED_APP_NAME"
NAS_VERSIONED_ZIP_PATH="$NAS_VERSION_DIR/$VERSIONED_ZIP_NAME"

cat > "$VERSION_FILE" <<EOF
SHORT_VERSION=$SHORT_VERSION
BUILD_NUMBER=$BUILD_NUMBER
EOF

if [[ -d "$XCODE_DEVELOPER_DIR" ]]; then
  export DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"
fi

# NOTE: 로컬 앱 데이터(프로젝트/폰트/환경설정)는 .app 산출물에 포함되지 않으므로
# 패키징 시 삭제하지 않는다. (과거에는 여기서 초기화해 실데이터가 유실될 수 있었다)

cd "$ROOT_DIR"
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
  swift build -c release --scratch-path "$SCRATCH_DIR" --arch arm64 --arch x86_64
  BUILD_DIR="$SCRATCH_DIR/apple/Products/Release"
else
  swift build -c release --scratch-path "$SCRATCH_DIR"
  BUILD_DIR="$SCRATCH_DIR/arm64-apple-macosx/release"
fi

EXECUTABLE_PATH="$BUILD_DIR/$PRODUCT_NAME"
RESOURCE_BUNDLE="$BUILD_DIR/${PRODUCT_NAME}_${PRODUCT_NAME}.bundle"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$EXECUTABLE_PATH" "$MACOS_DIR/$APP_NAME"
cp -R "$RESOURCE_BUNDLE" "$RESOURCES_DIR/"

# 지역화 테이블 복사 (macOS 시스템 언어를 따라 UI가 표시됨; ko는 코드 내 기본값)
if [[ -d "$ROOT_DIR/Localizations" ]]; then
  cp -R "$ROOT_DIR/Localizations/"*.lproj "$RESOURCES_DIR/"
fi

# 이 스크립트의 산출물은 NAS/직접 배포 전용이며 스토어 제출에는 절대 쓰이지
# 않는다(스토어용은 pack_mas.sh). 그래서 기본값을 Pro 잠금해제로 둔다.
# PRO_EDITION=0 으로 실행하면 무료 티어 제한이 걸린 빌드를 만들 수 있다.
if [[ "${PRO_EDITION:-1}" == "1" ]]; then
  PRO_EDITION_ENTRY='    <key>PSSProUnlocked</key>
    <true/>'
else
  PRO_EDITION_ENTRY=''
fi

if [[ -f "$ICON_SOURCE" ]]; then
  cp "$ICON_SOURCE" "$RESOURCES_DIR/AppIcon.icns"
  ICON_ENTRY='    <key>CFBundleIconFile</key>
    <string>AppIcon</string>'
else
  ICON_ENTRY=""
fi

cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>ko</string>
    <key>CFBundleDisplayName</key>
    <string>Photo Slide Studio</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.dreammedia.photoslidestudio</string>
    ${ICON_ENTRY}
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Photo Slide Studio</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$SHORT_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoadsInWebContent</key>
        <true/>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
${PRO_EDITION_ENTRY}
    <key>NSLocalNetworkUsageDescription</key>
    <string>같은 네트워크의 TV·사이니지 플레이어가 슬라이드쇼를 재생하려면 로컬 네트워크 접근이 필요합니다.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
EOF

chmod +x "$MACOS_DIR/$APP_NAME"
require_universal_binary "$EXECUTABLE_PATH" "$APP_NAME"

if security find-identity -v -p codesigning | rg -q 'HWP Converter Local Code Signing'; then
  codesign --force --deep --sign "HWP Converter Local Code Signing" "$APP_DIR" >/dev/null 2>&1 || true
else
  codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
fi

rm -rf "$LOCAL_VERSION_DIR"
mkdir -p "$LOCAL_VERSION_DIR"
ditto "$APP_DIR" "$LOCAL_VERSIONED_APP_PATH"
rm -f "$LOCAL_VERSIONED_ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$LOCAL_VERSIONED_APP_PATH" "$LOCAL_VERSIONED_ZIP_PATH"

if [[ -d "/Volumes/미디어" ]]; then
  rm -rf "$NAS_VERSION_DIR"
  mkdir -p "$NAS_VERSION_DIR"
  ditto --norsrc --noqtn "$APP_DIR" "$NAS_VERSIONED_APP_PATH"
  rm -f "$NAS_VERSIONED_ZIP_PATH"
  cp -f "$LOCAL_VERSIONED_ZIP_PATH" "$NAS_VERSIONED_ZIP_PATH"
fi

echo "Created app bundle:"
echo "$APP_DIR"
echo "Version: $SHORT_VERSION ($BUILD_NUMBER)"
echo "Versioned local export:"
echo "$LOCAL_VERSIONED_APP_PATH"
if [[ -d "/Volumes/미디어" ]]; then
  echo "Versioned NAS export:"
  echo "$NAS_VERSIONED_APP_PATH"
else
  echo "Versioned NAS export skipped: /Volumes/미디어 is not mounted"
fi
