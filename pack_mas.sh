#!/bin/zsh
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Mac App Store 제출용 빌드/패키징 스크립트
#
# 산출물: dist/mas/<version>/PhotoslideStudio.pkg  (App Store Connect 업로드용)
#
# 필요한 것(사용자가 Apple Developer 포털에서 준비):
#   1. "Apple Distribution" (또는 "3rd Party Mac Developer Application") 인증서
#   2. "3rd Party Mac Developer Installer" (Mac Installer Distribution) 인증서
#   3. Mac App Store용 provisioning profile (.provisionprofile)
#      - App ID: com.dreammedia.photoslidestudio, App Sandbox 활성
#
# 사용법:
#   PROVISION_PROFILE=/path/to/PhotoslideStudio_MAS.provisionprofile ./pack_mas.sh
#
# 인증서 자동 탐색이 실패하면 아래 환경변수로 직접 지정:
#   APP_SIGN_IDENTITY="Apple Distribution: NAME (TEAMID)"
#   INSTALLER_SIGN_IDENTITY="3rd Party Mac Developer Installer: NAME (TEAMID)"
# ─────────────────────────────────────────────────────────────────────────────

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
PRODUCT_NAME="DreamMediaSlideshowStudio"
APP_NAME="PhotoslideStudio"
BUNDLE_ID="com.dreammedia.photoslidestudio"
ENTITLEMENTS="$ROOT_DIR/PhotoslideStudio.entitlements"
ICON_SOURCE="$ROOT_DIR/assets/AppIcon.icns"
VERSION_FILE="$ROOT_DIR/VERSION"
SCRATCH_DIR="$ROOT_DIR/.swiftpm-build-mas"
XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

DIST_DIR="$ROOT_DIR/dist/mas"
APP_DIR="$ROOT_DIR/dist/mas/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

# ── 버전 읽기 (MAS는 자동 증가하지 않음: 릴리스마다 의도적으로 관리) ──────────
if [[ ! -f "$VERSION_FILE" ]]; then
  echo "Error: VERSION 파일이 없습니다: $VERSION_FILE" >&2
  exit 1
fi
source "$VERSION_FILE"
SHORT_VERSION="${SHORT_VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

# ── 사전 점검: entitlements ──────────────────────────────────────────────────
if [[ ! -f "$ENTITLEMENTS" ]]; then
  echo "Error: entitlements 파일이 없습니다: $ENTITLEMENTS" >&2
  exit 1
fi

# ── 사전 점검: 서명 인증서 ────────────────────────────────────────────────────
detect_identity() {
  # $1: grep 패턴, 첫 매칭 인증서의 전체 이름을 출력 (무매칭이어도 성공 반환)
  { security find-identity -v 2>/dev/null | grep -m1 "$1" || true; } \
    | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+[0-9A-F]+[[:space:]]+"(.*)"$/\1/'
}

APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:-$(detect_identity 'Apple Distribution')}"
if [[ -z "$APP_SIGN_IDENTITY" ]]; then
  APP_SIGN_IDENTITY="$(detect_identity '3rd Party Mac Developer Application')"
fi
INSTALLER_SIGN_IDENTITY="${INSTALLER_SIGN_IDENTITY:-$(detect_identity '3rd Party Mac Developer Installer')}"

MISSING=0
if [[ -z "$APP_SIGN_IDENTITY" ]]; then
  echo "✗ 앱 서명 인증서를 찾지 못했습니다 ('Apple Distribution' 또는 '3rd Party Mac Developer Application')." >&2
  MISSING=1
fi
if [[ -z "$INSTALLER_SIGN_IDENTITY" ]]; then
  echo "✗ 설치 서명 인증서를 찾지 못했습니다 ('3rd Party Mac Developer Installer')." >&2
  MISSING=1
fi
if [[ -z "${PROVISION_PROFILE:-}" ]]; then
  echo "✗ PROVISION_PROFILE 환경변수가 없습니다. Mac App Store provisioning profile 경로를 지정하세요." >&2
  MISSING=1
elif [[ ! -f "${PROVISION_PROFILE}" ]]; then
  echo "✗ provisioning profile 파일이 없습니다: ${PROVISION_PROFILE}" >&2
  MISSING=1
fi
if [[ "$MISSING" -eq 1 ]]; then
  cat >&2 <<'GUIDE'

── MAS 제출 준비 안내 ──────────────────────────────────────────────
1) https://developer.apple.com/account/resources/certificates 에서 발급:
   - Apple Distribution (앱 서명)
   - Mac Installer Distribution (pkg 서명)
2) App ID 등록: com.dreammedia.photoslidestudio (App Sandbox 활성)
3) Mac App Store provisioning profile 생성 후 다운로드
4) 다시 실행:
   PROVISION_PROFILE=/경로/프로파일.provisionprofile ./pack_mas.sh
────────────────────────────────────────────────────────────────────
GUIDE
  exit 1
fi

echo "앱 서명:     $APP_SIGN_IDENTITY"
echo "설치 서명:   $INSTALLER_SIGN_IDENTITY"
echo "프로파일:    $PROVISION_PROFILE"
echo "버전:        $SHORT_VERSION ($BUILD_NUMBER)"

# ── 릴리스 유니버설 빌드 ──────────────────────────────────────────────────────
if [[ -d "$XCODE_DEVELOPER_DIR" ]]; then
  export DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"
fi

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

# ── .app 번들 조립 ────────────────────────────────────────────────────────────
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$EXECUTABLE_PATH" "$MACOS_DIR/$APP_NAME"
cp -R "$RESOURCE_BUNDLE" "$RESOURCES_DIR/"

# 지역화 테이블 복사 (macOS 시스템 언어를 따라 UI가 표시됨; ko는 코드 내 기본값)
if [[ -d "$ROOT_DIR/Localizations" ]]; then
  cp -R "$ROOT_DIR/Localizations/"*.lproj "$RESOURCES_DIR/"
fi
chmod +x "$MACOS_DIR/$APP_NAME"

if [[ -f "$ICON_SOURCE" ]]; then
  cp "$ICON_SOURCE" "$RESOURCES_DIR/AppIcon.icns"
  ICON_ENTRY='    <key>CFBundleIconFile</key>
    <string>AppIcon</string>'
else
  ICON_ENTRY=""
fi

# provisioning profile 임베드 (MAS 필수)
cp "$PROVISION_PROFILE" "$CONTENTS_DIR/embedded.provisionprofile"

# ── Info.plist (샌드박스 + MAS 필수 키) ──────────────────────────────────────
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
    <string>$BUNDLE_ID</string>
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
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.photography</string>
    <key>ITSAppUsesNonExemptEncryption</key>
    <false/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>같은 네트워크의 TV·사이니지 플레이어가 슬라이드쇼를 재생하려면 로컬 네트워크 접근이 필요합니다.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoadsInWebContent</key>
        <true/>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
EOF

# ── 코드 서명 (안쪽부터 바깥으로, entitlements 포함) ─────────────────────────
# 리소스 번들 내 중첩 바이너리가 있으면 먼저 서명
find "$RESOURCES_DIR" -type f \( -name "*.dylib" -o -perm -u+x \) 2>/dev/null | while read -r nested; do
  codesign --force --timestamp --options runtime --sign "$APP_SIGN_IDENTITY" "$nested" 2>/dev/null || true
done

codesign --force --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --sign "$APP_SIGN_IDENTITY" \
  "$APP_DIR"

echo "서명 검증:"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

# ── pkg 생성 (설치 서명) ──────────────────────────────────────────────────────
VERSION_DIR="$DIST_DIR/$SHORT_VERSION"
mkdir -p "$VERSION_DIR"
PKG_PATH="$VERSION_DIR/$APP_NAME-$SHORT_VERSION.pkg"
rm -f "$PKG_PATH"

productbuild \
  --component "$APP_DIR" /Applications \
  --sign "$INSTALLER_SIGN_IDENTITY" \
  "$PKG_PATH"

echo ""
echo "✅ MAS 패키지 생성 완료:"
echo "$PKG_PATH"
echo ""
echo "다음 단계 — App Store Connect 업로드:"
echo "  xcrun altool --upload-app -f \"$PKG_PATH\" -t macos -u <APPLE_ID> -p <APP_SPECIFIC_PASSWORD>"
echo "  또는 Transporter 앱으로 업로드"
