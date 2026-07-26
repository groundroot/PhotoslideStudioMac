# Dream Media Slideshow Studio

로컬 macOS 앱에서 여러 슬라이드 프로젝트를 관리하고, 프로젝트별 로컬 웹 주소를 생성해 OptiSigns에 넣기 위한 앱입니다.

## 핵심 기능

- 여러 개의 슬라이드 프로젝트 생성/관리
- 프로젝트별 `이름`, `타이틀`, `서브타이틀`, `사진 폴더` 설정
- 프로젝트별 `사진당 표시 시간`, `트랜지션 시간`, `트랜지션 효과` 설정
- 로컬 웹서버 내장
- OptiSigns에 넣을 수 있는 LAN URL 생성
- `Gallery Monument` 디자인 테마 기본 탑재
- `Ken Burns` 포함 10개 전환 효과

## 실행

```bash
cd "/Users/chrictvictory/코딩/Codex/project 101/DreamMediaSlideshowStudio"
swift run
```

빌드만 하려면:

```bash
swift build
```

## OptiSigns 연결

1. 앱에서 프로젝트를 생성합니다.
2. `사진 폴더 선택`으로 로컬 사진 폴더를 고릅니다.
3. 타이틀, 서브타이틀, 재생 옵션을 설정합니다.
4. `OptiSigns URL` 항목의 주소를 복사합니다.
5. 그 주소를 OptiSigns의 웹 URL에 넣습니다.

중요:

- Mac과 OptiSigns 플레이어는 같은 네트워크에 있어야 합니다.
- `127.0.0.1` 주소가 아니라 LAN IP 주소를 사용해야 합니다.

## 현재 포함된 전환 효과

- Ken Burns
- Crossfade
- Slide Left
- Slide Right
- Slide Up
- Slide Down
- Zoom Fade
- Parallax Drift
- Soft Blur Dissolve
- Cinematic Reveal
