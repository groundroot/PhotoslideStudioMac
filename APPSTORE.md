# Mac App Store 출시 체크리스트

기준일: 2026-08-07 · 대상 버전: 1.0.39 · Bundle ID: `com.dreammedia.photoslidestudio`

## ✅ 코드/빌드 측 준비 완료 (이 저장소)

- App Sandbox entitlements (`PhotoslideStudio.entitlements`) — 서버·클라이언트 네트워크, 사용자 선택 파일, app-scoped bookmarks
- MAS 패키징 스크립트 `pack_mas.sh` — 유니버설 빌드, 프로파일 임베드, Info.plist 필수 키(암호화 면제, 카테고리, 로컬 네트워크 사유), pkg 서명까지 자동
- 인앱 구매: `com.dreammedia.photoslidestudio.pro` (비소모성, StoreKit 2) — 무료 제한(슬라이드 1개/사진 10장/영상 1개) 해제
- 앱 아이콘 `assets/AppIcon.icns`
- 자동 테스트 `swift test` (리사이즈 캐시, 알파 PNG 폴백, 프로젝트 JSON 마이그레이션)
- 지역화: ko(기본)·en·ja·zh-Hans

## 🔲 사용자(Apple Developer 계정)가 해야 할 일 — 순서대로

1. **인증서 발급** — https://developer.apple.com/account/resources/certificates
   - `Apple Distribution` (앱 서명)
   - `Mac Installer Distribution` (pkg 서명)
   - 현재 키체인에는 Developer ID Application(직접 배포용)만 있고 위 두 개는 없음
2. **App ID 등록** — Identifiers에서 `com.dreammedia.photoslidestudio`, App Sandbox 활성
3. **프로비저닝 프로파일** — Mac App Store 배포용 생성 후 다운로드
4. **App Store Connect 앱 레코드 생성** — 이름 "Photo Slide Studio", 기본 언어 한국어, 카테고리 사진
5. **인앱 구매 등록** — 제품 ID `com.dreammedia.photoslidestudio.pro`, 비소모성. 심사 노트에 무료 제한과 해제 범위 명시
6. **패키지 빌드**
   ```sh
   PROVISION_PROFILE=/경로/프로파일.provisionprofile ./pack_mas.sh
   ```
7. **업로드** — Transporter 앱 또는:
   ```sh
   xcrun altool --upload-app -f dist/mas/<버전>/PhotoslideStudio-<버전>.pkg -t macos -u <APPLE_ID> -p <앱암호>
   ```
8. **심사 메타데이터** — 스크린샷(1280×800 이상, 편집 화면·프리뷰·송출 화면 권장), 설명, 키워드, 개인정보처리방침 URL(네트워크 서버 앱이므로 필수), 지원 URL
   - 심사 노트에 반드시 기재: 앱이 로컬 HTTP 서버를 열어 같은 네트워크의 사이니지 플레이어(OptiSigns)가 슬라이드쇼를 재생하는 구조라는 점, 테스트 방법(앱 실행 → 프로젝트 생성 → 브라우저 뷰 URL 접속)

## 직접 배포(NAS)판 공증 — 선택이지만 권장

`pack_app.sh`는 이제 키체인의 Developer ID Application 인증서로 자동 서명한다(hardened runtime 포함).
다른 Mac에서 Gatekeeper 경고 없이 실행하려면 공증까지 필요:

```sh
xcrun notarytool store-credentials notary --apple-id <APPLE_ID> --team-id 2W3UMZHQ8G  # 최초 1회
xcrun notarytool submit dist/<버전>/PhotoslideStudio-<버전>.zip --keychain-profile notary --wait
xcrun stapler staple dist/<버전>/PhotoslideStudio-<버전>.app
```

## 주의

- MAS 판은 `PSSProUnlocked` 키가 없어야 함 — `pack_mas.sh`는 넣지 않음(정상). NAS판(`pack_app.sh`)만 Pro 고정.
- 샌드박스 하에서 NAS(SMB) 폴더 접근은 사용자가 폴더를 직접 선택해야 유지됨 — 기존 app-scoped bookmark 로직이 처리.
- VERSION의 `BUILD_NUMBER`는 App Store Connect 업로드마다 증가해야 함.
