# 현재 에디터 테마 비교 캡처

구문 색을 개선하기 전에 현재 제품이 그리는 색을 언어별로 비교한다. `run.py`는 별도 renderer나
CSS 모형을 만들지 않고, 빌드한 Maru 앱의 `MARU_NATIVE_EDITOR` → 제품 Metal → `MARU_SCREENSHOT`
경로를 사용한다. 제품 소스·기본값·테마 팔레트는 바꾸지 않는다.

## 실행

macOS의 GUI 세션과 Metal, Python 3 + Pillow가 필요하다. Pillow는 이 opt-in 도구의 PNG 변환·비교판
조립에만 쓰며 제품·CI 의존성에 추가하지 않는다.

```sh
mise exec -- zig build macos-app-build -j2
python3 tools/editor-theme-gallery/run.py \
  --output /tmp/maru-editor-theme-gallery-new \
  --typescript-all-presets
```

출력은 저장소 밖의 **새 빈 디렉터리**여야 한다. 기본은 번들 문법 31종 각각을
`maru`, `one-dark`, `catppuccin-mocha`, `one-light` 순서로 촬영한다.
`--typescript-all-presets`는 TypeScript에 나머지 프리셋을 추가하므로 총 136장이다.
문법 목록은 `src/session/editor/language.zig`의 `Grammar`, 프리셋 목록은
`src/config/theme.zig`의 `ThemePreset`에서 읽는다. 번들 문법과 예제 목록이 달라지면 중단한다.

작은 범위만 재촬영할 수도 있다.

```sh
python3 tools/editor-theme-gallery/run.py \
  --output /tmp/maru-editor-theme-gallery-small-new \
  --languages zig typescript python \
  --themes maru one-light
```

## 비교 조건

- 창 1280×760 pt, 렌더 2x, 폰트 JetBrains Mono 14. `--scale-milli 1000`으로 1x도 가능하다.
- 프리셋 외에는 모든 장에 같은 설정을 쓴다. `theme.follow-system = false`, `theme.syntax.*` 미지정.
- `lsp.enabled = false`: 서버 설치·신뢰·응답 시점에 따른 semantic token과 진단 차이를 제외한다.
  이 캡처는 tree-sitter 기본 하이라이트이며 LSP를 켠 화면 전체를 대표하지 않는다.
- 합성 예제만 열며 코드를 실행하지 않는다. 창 복원·영속 세션은 끄고, 빈 셸을 사용한다.
- 자식에 HOME·provider 환경·상위 MARU 디버그 환경을 상속하지 않는다. HOME이 없으면 제품의
  provider 훅 설치/제거 경로가 실행되지 않는다. `sidebar.agent-hooks = false`만으로는 사용자
  provider 설정의 훅을 **제거**하므로 격리가 되지 않는다.
- Foundation 프로필은 `CFFIXED_USER_HOME`, Zig 설정·캐시·백업·host는 각각의 명시 경로로 격리한다.
  각 프로세스 그룹만 종료하며 실행 중인 다른 Maru 창과 세션은 종료하지 않는다.
- 내용이 있는 첫 프레임부터 1500ms 기다린 뒤 촬영한다. UI 클릭·키보드 입력을 재현하는 도구는 아니다.

## 결과와 판독

- `index.html`: 원본 PNG를 확대할 수 있는 로컬 언어별 갤러리.
- `images/`: 실제 2560×1520 PNG. PPM을 손실 없이 PNG로 변환하며 색은 수정하지 않는다.
- `sheets/`: 같은 언어의 네 프리셋을 2×2로 배열한 PNG. 원본을 1/2 크기로 줄이고 바깥에 라벨을 붙인다.
  TypeScript 전체 프리셋은 네 장씩 별도 비교판으로 만든다.
- `result.json`: 소스 commit·앱 SHA-256·언어/테마·PNG/예제/설정 SHA-256·PID·종료 상태·크기.
- `runs/`: 각 장의 config·예제·실행 로그·원본 PPM·격리 프로필. 로컬 증거로 유지하고 커밋하지 않는다.

PR에는 `gh pr create --draft --attach <sheets의 PNG> --body-file <본문 파일>`로 캡처를 올린다.
`--attach`는 한 번에 50장까지 받으므로 기본 비교판 35장은 한 번에 첨부할 수 있다.
본문에 `![언어와 프리셋](./파일.png)` 참조를 두며, 업로드 후 실제 attachment URL로 바뀌었는지 확인한다.

앱 exit 0·캡처 로그·이미지 크기는 캡처 성공 조건이다. 색 구분의 품질, grammar의 모든 토큰 분류,
semantic token, 대비 기준 준수까지 자동으로 증명하지 않는다. 비교판에서 예제 전체가 보이는지와
알림/모달이 본문을 덮지 않는지는 별도로 확인한다.
