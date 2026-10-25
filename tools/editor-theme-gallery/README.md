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

## 실제 LSP를 켠 추가 캡처

`prepare_lsp.py`와 `run_lsp.py`는 실제 설치된 서버의 응답을 받아 촬영한다. 가짜 서버나 합성 token은
쓰지 않는다. `lsp_proxy.py`는 stdio 바이트를 수정 없이 전달하면서 initialize/initialized/didOpen,
semantic token 응답 개수·오류, 진단 개수만 로컬 `protocol.ndjson`에 기록한다.

먼저 저장소 밖에 앱 사본을 만든다.

```sh
python3 tools/editor-theme-gallery/prepare_lsp.py \
  --snapshot /tmp/maru-theme-lsp-app-new
```

사본의 유일한 소스 변경은 `MaruAppHost.swift`의 스모크 예제 입력을 생략하고 실제 창 resize만 하는
조건문이다. 일반 deferred startup에서 `MARU_NATIVE_EDITOR`가 먼저 탭을 만들면
`finishDeferredInitialSurface`가 탭 존재만 보고 돌아가 Surface가 초기화되지 않아, 화면은 보이되
입력·LSP 처리를 끝까지 진행할 수 없다. 그래서 이미 초기화된 Surface로 시작하는 controlled smoke를
사용한다. 그 스모크의 기본 `a`·Enter 입력은 문서를 바꾸므로 사본에서만 생략한다.
제품 checkout의 `src/`, LSP·파서·테마·렌더러 구현은 고치지 않는다. 사본에는
`theme-gallery-fixture.json`으로 원본 commit과 수정 전후 Swift SHA-256을 남긴다.

서버 목록 JSON은 문법 이름을 실제 실행 argv에 연결한다. mise 등의 비활성 shim 대신 실제 설치 경로를
쓴다. 필요한 SDK 환경과 PATH는 `environment`, 추가 프로젝트 파일은 `support`로 지정할 수 있다.

```json
{
  "typescript": {"argv": ["/absolute/bin/tsgo", "--lsp", "--stdio"]},
  "c": {"argv": ["/usr/bin/clangd"]},
  "python": {"argv": ["/absolute/bin/pyright-langserver", "--stdio"]}
}
```

```sh
python3 tools/editor-theme-gallery/run_lsp.py \
  --app /tmp/maru-theme-lsp-app-new/zig-out/Maru.app/Contents/MacOS/maru-macos-app \
  --servers-json /tmp/real-language-servers.json \
  --output /tmp/maru-editor-lsp-gallery-new \
  --typescript-all-presets \
  --baseline-gallery /tmp/maru-editor-theme-gallery-new
```

- 각 언어의 임시 git 프로젝트를 만든다. TypeScript/Cargo/Go 등의 최소 프로젝트 메타데이터를 함께 둔다.
- 앱은 HOME/provider 환경을 상속하지 않아 사용자 provider 훅과 신뢰 파일을 읽거나 쓰지 않는다.
  실제 서버 자식에는 SDK를 찾을 수 있도록 기존 HOME·PATH 등의 도구 환경만 전달한다. 서버 캐시와 SDK는
  실제 설치를 사용하며 OS 샌드박스를 제공하는 도구는 아니다.
- `trust_button.swift`를 출력 폴더에 컴파일한다. Vision OCR로 **현재 그려진 LSP 신뢰 창**과 Run 버튼을
  찾은 뒤, 기존 AppKit 테스트 입력으로 그 버튼만 클릭한다. 신뢰는 이번 앱 프로세스 메모리에만 남는다.
- `initialized`와 `didOpen`을 확인한다. semantic provider가 있으면 실제 token 응답을 기다린다.
  실행 시작 후 30초(`--semantic-wait`)까지 응답이 없으면 **연결 화면만** 촬영하고 미응답으로 구분한다.
  응답의 token 수와 오류를 함께 기록하므로, LSP 설정 켜짐과 token 응답 성공을 구분할 수 있다.
- `MARU_SCREENSHOT_KEEP_PROCESS=maru-test-only-v1`으로 제품 offscreen 렌더링을 유지하고, 기존
  `inspect-main-capture` 경로로 같은 앱에서 테마를 바꿔 촬영한다. 촬영 완료 뒤 그 앱 프로세스 그룹만 종료한다.
- `--baseline-gallery`를 주면 같은 언어·테마의 이전 PNG와 코드 영역의 달라진 픽셀 수를 센다.
  여기에는 semantic 색뿐 아니라 진단·인레이·접힘 표시 차이도 포함되므로 semantic token 단독 효과로 읽지 않는다.
- 결과는 언어별 서버 정보·capability·응답·실패 이유와 PNG를 보유한다. 서버가 없거나 초기화/응답이
  실패한 언어는 성공한 LSP 캡처로 취급하지 않는다. Markdown·XML·DTD·Make·SQL은 현재 내장 주 서버가 없다.

실제 창·제품 Metal 출력과 실제 서버를 사용하지만, 신뢰 클릭은 합성 AppKit 입력이다. 물리 입력이나
모든 실제 프로젝트의 빌드·의존성 구성을 검증하는 결과는 아니다. 서버가 semantic token을 제공하지 않으면
연결돼 있어도 tree-sitter 색을 유지할 수 있다. 진단·인레이 힌트는 서버가 보내는 실제 결과를 그대로 촬영한다.

시맨틱 토큰 수정의 EOF·설정·응답 복구 검증은 [회귀 증거](semantic-recovery.md)를 참고한다.
