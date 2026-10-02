# Photo Slide Studio (Dream Media Slideshow Studio)

로컬 macOS 앱에서 사진·영상 슬라이드 프로젝트를 관리하고, 프로젝트별 웹 주소를 만들어 OptiSigns 같은 사이니지 플레이어에 넣기 위한 앱입니다.

- 현재 버전: `1.0.40 (131)` — `VERSION` 파일 기준
- 요구 사항: macOS 13 이상, Swift 6.2 (Universal: Apple Silicon + Intel)
- 지역화: 한국어(기본) · English · 日本語 · 简体中文

## 기능

### 프로젝트

- 사진 슬라이드 / 비디오 슬라이드 프로젝트 여러 개 생성·관리
- 프로젝트 하나에 여러 이벤트(슬라이드)를 넣고 `순차` · `랜덤` · `플레이리스트` 방식으로 재생
- 프로젝트별 고정 URL(`/p/<번호>`)

### 미디어 소스

- 로컬 폴더: 사진 `jpg/jpeg/png/webp/gif/bmp/avif/heic/tiff`, 영상 `mp4/m4v/mov/webm`
- 유튜브 플레이리스트(웹 플레이어가 YouTube IFrame API로 직접 재생)
- 재생 순서: 랜덤 · 파일명순 · 촬영일순
- 화면 맞춤: Fill · Fit · 스트레치 · 16:9 강제비율

### 화면 연출

- 전환 효과 15종: None, Crossfade, Page(좌·우·상·하), Slide(좌·우·상·하), Zoom Dissolve, Cinematic Reveal, Split Wipe, Flash Fade, Diagonal Reveal
- 사진 모션 10종: Ken Burns, Slow Zoom In/Out, Drift(좌·우·상·하), Parallax Float, Cinematic Push
  - Ken Burns 방향(줌 인/아웃), 배율, 초점(중앙 · 랜덤 · 얼굴 인식)
- 특수 효과: Floating Particles, Light Leaks, Glass Orbs, Gradient Mesh, Paper Grain, Prism Lines
- 사진당 표시 시간, 전환 시간 설정
- `Gallery Monument` 디자인 테마

### 텍스트 · 로고 · 오디오

- 타이틀 / 서브타이틀 오버레이: 9개 위치 + X/Y 오프셋, 배경 효과(Clean · Drop Shadow · Blur Bar)
- 글꼴: 한글 번들 폰트 11종(Pretendard, 본고딕, 나눔스퀘어, 에스코어드림, 검은고딕 등) + 시스템 폰트 + 사용자 폰트 가져오기(`ttf/otf/ttc/otc`)
- 크기, 색상, 굵기, 기울임, 자간, 행간, 그림자 세부 조절
- 로고 오버레이(위치, 크기, 오프셋, 투명도)
- 배경 음악(로컬 mp3/mp4)

### 배포 · 네트워크

- 내장 웹서버(기본 포트 `8787`)
- 주소 선택: LAN / Tailscale. 마지막에 고른 주소를 기억해서 재부팅 후에도 URL이 바뀌지 않음
- 앱 안 미리보기는 `127.0.0.1`로 실제 배포 해상도 비율을 그대로 보여 줌
- 사진은 2560px로 줄인 JPEG로 전송(디스크 캐시 1GB, LRU)

### 무료 / Pro

- 무료: 슬라이드 1개, 사진 10장, 영상 1개
- Pro(인앱 구매 `com.dreammedia.photoslidestudio.pro`): 제한 해제
- NAS / 직접 배포용 빌드(`pack_app.sh`)는 Pro가 기본으로 켜져 있음

## 실행

```bash
swift run      # 실행
swift build    # 빌드만
swift test     # 테스트
```

## 패키징

```bash
./pack_app.sh   # 직접 배포용 universal .app/.zip → dist/<버전>/, NAS에도 복사
./pack_mas.sh   # Mac App Store용 .pkg (APPSTORE.md 참고)
```

- `pack_app.sh`는 Developer ID 인증서가 있으면 Developer ID + hardened runtime으로 서명하고, 없으면 ad-hoc 서명합니다.
- 빌드 결과물은 NAS `/Volumes/미디어/01_Optisigns/00_App/Photo APP/Version/<버전>/`에도 들어갑니다.

## OptiSigns 연결

1. 앱에서 프로젝트를 만들고 사진/영상 폴더를 고릅니다.
2. 링크 카드에서 주소(LAN 또는 Tailscale)를 고르고 URL을 복사합니다.
3. 복사한 주소를 OptiSigns의 웹 URL에 넣습니다.

주의할 점:

- Mac과 플레이어는 같은 네트워크(또는 같은 Tailscale 네트워크)에 있어야 합니다.
- `127.0.0.1` 주소는 다른 기기에서 열리지 않습니다.

## 개발 노트

| 버전 (빌드) | 날짜 | 변경 내용 |
|---|---|---|
| 1.0.40 (131) | 2026-10-02 | 발표 주소 선택(LAN / Tailscale). 브라우저 보기·복사가 고른 주소를 써서 다른 Mac에서도 열림. 마지막 주소 기억(재부팅 후 URL 유지), 인터페이스 순서 고정, AirDrop/bridge/vmnet 인터페이스 숨김 |
| 1.0.39 (130) | 2026-08-07 | App Store 준비: 아이콘 복구, Developer ID 서명, 제출 체크리스트(`APPSTORE.md`). 테스트 타깃 추가(리사이즈 캐시, 프로젝트 JSON 마이그레이션), VoiceOver 접근성 개선 |
| 1.0.38 (129) | 2026-07-26 | Intel Mac 성능 개선: 사진 2560px 축소 전송 + 디스크 캐시, 얼굴 인식 썸네일 디코드 + 병렬 처리, 쓰이지 않던 WebGL 전환 엔진 제거 |
| 1.0.37 (128) | 2026-07-26 | 미리보기 크기 문제 수정(`WKWebView.pageZoom`), 위치 프리셋을 90% 가이드라인에 맞춤 |
| 1.0.36 (127) | 2026-07-26 | NAS/직접 배포 빌드는 Pro 잠금 해제 상태로 빌드 |
| 1.0.35 (126) | 2026-07-26 | X/Y 오프셋 스테퍼 버튼 추가, 미리보기 글자 크기 불일치 수정 |
| 1.0.34 (125) | 2026-07-26 | 타이틀 X/Y 오프셋 추가, Safari 전체 화면 멈춤 수정 |

1.0.33 이전 버전은 git 기록이 없습니다(첫 커밋이 1.0.34). 빌드만 NAS `Version/` 폴더에 남아 있습니다.
