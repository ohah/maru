# 세팅 페이지 전략과 구현 계획

Maru는 설정을 **config 텍스트 파일**(`docs/configuration.md` 단일 출처)로 두되, 그 위에 **앱 내 세팅
화면(GUI)** 을 얹는다. 이 문서는 세팅 GUI의 전략·섹션 구조·양방향 반영 토대·신규 기능 추가의 **doc-first
PR 분해**를 단일 출처로 둔다. 실제 키·형식·검증은 항상 [설정(config) 파일](configuration.md)이, GUI를
그리는 chrome 구조는 [Chrome 전략](chrome-strategy.md)이, 키바인딩 경계는 [키 입력과
단축키](key-input-and-shortcuts.md)가 단일 출처다 — 여기서는 중복하지 않고 연결한다.

> 상태(2026-06): **진행 중**. S0-1a·F1-3·F1-8·F1-9 머지(F1-7은 기존 구현). 진행 상황은 각 PR 표의 상태
> 칸으로 동기화한다.
>
> **방향 전환(2026-06)**: config 계층을 **스키마-주도**로 옮긴다([config 스키마](config-schema.md)). 메타
> 1급 필드 한 선언에서 parse·serialize·검증·문서·**GUI 위젯**이 파생되므로, 남은 스칼라 키(F1/F2 대부분)와
> **Phase G(§6)가 크게 축소**된다 — 스칼라는 GUI 코드 0줄로 화면에 뜨고, bespoke 위젯(팔레트·env·keybind)만
> G에 남는다. 그래서 아래 F1/F2를 키마다 손으로 더 꿰매기 전에 스키마 프레임워크(CS-1)를 먼저 둔다.

## 0. 목표와 범위

- **config 파일이 단일 출처(SSOT)**. 세팅 GUI는 그 파일을 **읽고 쓰는 편집기**일 뿐이다. GUI에서 바꾸면
  config 파일에 반영되고, 파일을 직접 편집하면 GUI/런타임에 반영된다(양방향).
- **미설정 = 기본값**. config가 없거나 일부 줄이 틀려도 동작한다는 forgiving 원칙([configuration.md])을
  GUI 도입으로 깨지 않는다. GUI는 "기본값 위의 override"만 직렬화한다.
- **GUI는 Zig+GPU chrome으로 그린다**(네이티브 뷰 비사용). 이는 maru의 chrome 전략이자 이식성 목표와
  부합한다([chrome-strategy.md], [layering-and-portability.md]). SwiftUI 설정창 같은 Apple 전용 경로를
  쓰지 않는다.
- **베이스/결정**: 세팅 화면의 형태(좌측 섹션 네비 + 검색 + 우측 폼, 키바인딩의 인라인 리바인드)는 널리
  쓰이는 데스크톱 세팅 GUI 관례를 **형태만** 참고한 **Maru 독립 설계**다(외부 터미널 출처는 본문·PR·주석에
  기재하지 않는다 — chrome UI 참조 규율). 개별 설정의 **동작·기본값** 결정은 기존 문서대로 공개 명세와
  Ghostty/iTerm2 등 사실상 표준을 베이스로 하고, 레퍼런스 간 차이에서 택한 바를 코드 주석·PR에 남긴다
  ([project-rules.md] "베이스·의사결정 명시").

**범위 밖(보류)**: 합자(ligatures)의 *실제* 구현. "1 셀 = 1 glyph" 가정이 atlas·cache key·커서·선택·
dirty region에 박혀 있어 렌더 파이프라인 재설계가 필요하고, [font-strategy.md]도 v1 범위 밖으로 명시한다.
껍데기 토글(표시만)은 의미가 없으므로 두지 않는다. 그 외 미지원 항목은 모두 이 계획의 범위에 포함한다.

## 1. 세팅 화면 섹션 구조 (Maru)

좌측 섹션 네비 + 상단 검색(항목이 많아 검색이 필수) + 우측 폼. 섹션은 config 키 네임스페이스와 1:1로
맞춰 "GUI 항목 ↔ config 키"가 자명하게 한다.

| 섹션 | 포함 config 네임스페이스 | 주요 항목 |
|---|---|---|
| **Appearance › Font** | `font.*` | family, size, line-height, letter-spacing, (신규) family-bold/italic, fallback |
| **Appearance › Theme** | `theme.*`, `chrome.theme` | preset, 개별 색, palette 16, (신규) search/sidebar 색, bold-is-bright, follow-system |
| **Appearance › Cursor** | `cursor.*` | shape, blink, color/text, (신규) blink-interval, unfocused |
| **Appearance › Window** | `window.*` | padding, (신규) opacity, blur, background-image, unfocused-dim |
| **Input › Keys** | `input.*` | page-keys, shift-enter, ime-enter, (신규) option-as-meta |
| **Input › Mouse** | `input.*` | (신규) url-click-modifier, right-click, mouse-hide-while-typing, word-separators, scroll.* |
| **Keybindings** | `keybind` | 액션 카탈로그 전체 + 인라인 리바인드/unbind/매크로 |
| **Terminal** | `term`, `scrollback.*`, `bell.*`, `notifications.*`, `osc52.*`, `shell.*`, `env.*` | TERM, 스크롤백, 벨(audible/visual/badge), 알림, OSC52 read, 셸/인자, env |
| **Workspace** | `workspace.*` | root, tab/split inherit-cwd |
| **Quick Terminal** | `quick-terminal.*` | height/width/position/screen/auto-hide/chrome/minimal-tabs |
| **Sidebar** | `sidebar.*` | show-branch, show-folder (이미 ⚙ 양방향 — 첫 선례) |
| **Behavior** | (앱 동작) | 탭/창 닫기 확인, config 자동 reload 토글 |

## 2. 토대: 양방향 config 반영 (Phase S0)

세팅 GUI 이전에 **config 파일 write-back을 전 항목으로 일반화**하고 **자동 reload**를 둔다. 이게 받침이라
이후 모든 신규 키가 GUI 없이도 "파일 편집 즉시 반영"으로 검증된다.

현재 토대(이미 있음):
- `loader.updateConfigText`(`src/config/loader.zig`) — 원본을 줄 단위로 순회해 키를 in-place 교체, **주석·
  순서·미파싱 키 보존**, 없던 키는 append. round-trip 테스트 존재.
- `take_*_dirty` 신호 ABI + Swift atomic write — `sidebar.*` 2키에 대해 동작(첫 선례).
- `app_session.reloadConfig` — 이미 40+ 필드를 재적용(appearance/palette/scrollback/ambiguous-width/bell/
  sidebar). **확장 불필요**.

| PR | 내용 | 난이도 | 상태 |
|---|---|---|---|
| **S0-1a** | **역파싱 코어** `config.configKeyValues(arena, Config) → []KeyValue`(`src/config/serialize.zig`) — parse의 대칭 역연산. 전 필드를 정규 토큰으로(enum은 명시 매핑 — `commit-only` 등; palette는 non-null만; float은 `{d}` shortest round-trip). **round-trip 대칭 테스트**(`parse(render(configKeyValues(cfg))) == cfg`)가 parse/serialize 누락을 못박는다. | 중간 | ✅ 구현·green(1058/1060). `updateConfigText` 재사용 |
| **S0-1b** ✅ | **per-key write-back 일반화** — `serialize.updateForKeys(original, config, keys)`가 넘긴 키만 현재값으로 `updateConfigText` 부분 갱신(즉시-저장 GUI 결정에 맞춤 — full-config diff 대신 변경 키만; **override-only by construction**). `serializeSidebarConfig`를 이걸로 재구현(bool 손코드 제거, byte-identical). | 낮음 | ✅ 머지. dirty 비트마스크·전체 diff는 불필요(즉시-저장은 변경 키만 씀); GUI는 같은 `updateForKeys` 경로 |
| **S0-2** | config 파일 **자동 감지 reload** — macOS `DispatchSource`/FSEvents watcher(Swift), debounce(0.5~1s), 편집 중 불완전 파일 회피(.tmp→rename 가정), 기존 `reloadConfig` 재사용. `behavior.auto-reload`로 끌 수 있게. | 낮음~중간 | 🔜 Zig는 변경 없음(reload 이미 있음). watcher만 platform(Swift) |

> 경계: write-back은 **앱→파일**(GUI 편집 저장), reload는 **파일→앱**(외부 편집 감지). 둘은 직교하며 같은
> `updateConfigText`/`reloadConfig`를 공유한다. env 등 민감값 직렬화는 [project-rules.md] redaction 기준을
> 재사용한다(저장 시 평문이라도 config 파일은 사용자 소유 — trace/artifact와 기준은 같되 파일엔 사용자가
> 적은 값을 보존).

## 3. 신규 기능 — 쉬움 (Phase F1)

config 키 추가 + 기존 경로에 분기 한 줄. GUI 없이 config 파일로 즉시 검증 가능. 각 PR은 키 1~2개로 잘게.

| PR | 기능 / 키 | 핵심 변경 | 근거(현황) |
|---|---|---|---|
| **F1-1** | 배경 투명도 `window.opacity` | `metalLayer.isOpaque=false` + 셀 배경 alpha 곱 | 셀 배경 이미 `0xAARRGGBB`, 셰이더 alpha 블렌딩 중(`maru_metal_renderer.m`) |
| **F1-2** | 폴백 폰트 `font.fallback` | `CTFontCopyDefaultCascadeListForLanguages` 명시 | per-cell CTLine이 이미 CoreText cascade 사용, FontIdentityRegistry가 face 분리 |
| **F1-3** ✅ | bold-is-bright `theme.bold-is-bright` | `packForeground`에 `brightenIfBold`(bold+indexed 0~7→+8) | ✅ 머지. render-only, packForeground 순수 단위 테스트 |
| **F1-4a** ✅ | 커서 색 `cursor.color`(칸)·`cursor.text`(반전 글자) | 테마 독립 opt-in. nullable이라 loader 수동 핸들러·serialize 수동 emit(palette 선례), `ResolvedCursor`에 색 추가 후 렌더가 `orelse` 테마 폴백 | ✅ 머지. 기존 동작(흰 커서) 보존. resolve/round-trip/parse 단위 테스트 |
| **F1-4b** | 커서 `cursor.blink-interval-ms`/`unfocused` | `blink_interval_ticks` 상수→ms, resignKey 시 override | 주기는 상수(`app_session.zig`) — 잔여 |
| **F1-5** | URL 클릭 modifier `input.url-click-modifier` | `.command` 하드코딩을 config 비교로 | `MaruAppHost.swift` 한 줄 |
| **F1-6** | 타이핑 중 커서 숨김 `input.mouse-hide-while-typing` | keyDown `NSCursor.hide()` + idle 타이머 복원 | AppKit only |
| **F1-7** | 탭 닫기 확인 | 창 닫기 confirm(`request_window_close`)을 탭 close에도 호출 | 모달 토대 이미 있음(창에만 적용 중) |
| **F1-8** ✅ | env 주입 `env.<KEY>` | `SpawnRequest.env_overrides` + `EnvStorage` upsert(부모 상속 위 덮어쓰기/추가) | ✅ 머지. 부모+사용자 정책, EnvStorage upsert 단위 테스트 |
| **F1-9** ✅ | 커스텀 셸 `shell.command`/`shell.args` | `spawnRequest` interactive 분기가 config.shell 사용(login 래퍼는 그대로 — `/bin/bash`는 메커니즘) | ✅ 머지. loader·serialize 단위 테스트. `command/args`는 spawn이 이미 받음 |
| **F1-10** | 스크롤 `scroll.multiplier`/`scroll.on-output` | `handleScroll` delta 배수, PTY 출력 후 viewport 조정 | delta 경로 존재 |

## 4. 신규 기능 — 중간 (Phase F2)

새 코드 한 덩어리(≈80~150줄). 일부는 코어+ABI 양쪽.

| PR | 기능 / 키 | 핵심 변경 | 근거(현황) |
|---|---|---|---|
| **F2-1** | 배경 이미지 `window.background-image` | 이미지 로드/config + 배경 quad pass | **렌더 ~90%는 인라인 이미지(텍스처 캐시·quad) 재사용 가능** |
| **F2-2** | Option=Meta 토글 `input.option-as-meta` | `EncodeOptions`에 bool + session 캐시 + `input.zig` 분기 | Option 항상 meta-ESC(`terminal/input.zig`) |
| **F2-3** | Bold/Italic family `font.family-bold`/`family-italic` | style_flags로 face 쿼리(없으면 synthetic) | 현재 synthetic bold만(`coretext_smoke.m`) |
| **F2-4** | 시각 벨 + Dock 배지 `bell.visual`/`bell.dock-badge` | 프레임 flash overlay + `dockTile.badgeLabel` | audible만 구현(`bell.audible`) |
| **F2-5** | 우클릭 동작 `input.right-click` (paste\|menu\|reporting) | reporting off일 때 분기 | 현재 reporting만 |
| **F2-6** | OSC52 read `osc52.read` (allow\|deny) | read 요청 파싱 + clipboard read ABI 신규 | write만 구현(`terminal/core.zig`) |
| **F2-7** | 비활성 split 디밍 `window.unfocused-dim` | 셀에 focused 플래그 + 셰이더 색 보간 | 활성 pane 추적은 이미 있음(탭바). 셀 플래그·셰이더가 일 |
| **F2-8** | word separators `input.word-separators` | core `wordBoundsAt` 수정 + ABI 전달 | 현재 비공백 run 고정(`terminal/core.zig`) |
| **F2-9** | 시스템 라이트/다크 `theme.follow-system` + light/dark preset | `NSAppearance` 감지 + 런타임 palette 교체 | reload palette 교체 토대 있음. **config 구조 결정 필요(§8)** |

## 5. 신규 기능 — 어려움 (Phase F3)

| PR | 기능 / 키 | 핵심 변경 | 근거(현황) |
|---|---|---|---|
| **F3-1** | 배경 블러 `window.blur` | 2-pass Metal(offscreen→Gaussian), F1-1 투명도 위에 | CAMetalLayer는 vibrancy 충돌 → 직접 구현. MTLRenderPassDescriptor 재설계 + 성능 튜닝 |

## 6. 세팅 GUI — chrome 위젯 + 페이지 (Phase G)

> **재정의(2026-06)**: config 계층이 스키마-주도가 되면서([config 스키마](config-schema.md)), 세팅 화면은
> **스키마 메타(Widget/Section/range/doc)에서 자동 생성**된다 — 스칼라 ~40개는 GUI 코드 0줄. 그래서 아래 G0~G8
> (필드마다 손 위젯)의 **상당수가 "제너릭 위젯 N종 + 제너릭 렌더러" 하나로 붕괴**한다. 갱신된 단일 출처:
> **[config GUI(스키마-주도 세팅 화면)](config-gui.md)** (CS-4-0~5). 아래 표는 위젯 종류의 출발 스냅샷으로 남긴다.

기능이 config로 다 들어간 뒤, 그 위에 GUI를 얹는다. **거의 모든 토대가 chrome에 이미 있다** — 텍스트
입력+caret(Find/팔레트), 토글(context_menu 체크박스), 드롭다운(팔레트), 스크롤 리스트, hit-test 패턴,
GPU rounded quad, 입력 라우팅(ChromeHost). **신규 리스크는 ① color picker(가장 무거움) ② ChromeHost에
마우스 pointer 이벤트가 아직 없음(슬라이더·색 그리드 선결)** 둘이다.

| PR | 내용 | 난이도 | 재사용/근거 |
|---|---|---|---|
| **G0** | **ChromeHost pointer 이벤트** — 마우스 down/move/up을 `InputEvent`로 확장(슬라이더 드래그·색 그리드 선결) | 중간 | divider/sidebar hit-test 패턴 존재, host 입력 라우팅 확장 |
| **G1** | `toggle.zig` 위젯 | 낮음 | context_menu 체크박스(✓) 기반 |
| **G2** | `dropdown.zig` 위젯(정적 목록) | 중간 | 팔레트 선택/네비 구조에서 검색 제거 |
| **G3** | `text_input`/`number_input` 위젯 | 중간 | `overlay_input.zig`(IME·caret) 재사용 + 숫자 검증 |
| **G4** | `keybind_input.zig`(키 캡처 recorder) | 중간 | `input.InputEvent`(OS 무관) 그대로 |
| **G5** | `slider.zig` 위젯 | 중간 | divider `dragRatio` 패턴 + G0 pointer |
| **G6** | 색 입력 — **1차: 16색 프리셋 + hex 텍스트(G3 재사용)**, 2차: HSV picker(RGB↔HSV + 2D 그리드) | 1차 중간 / 2차 높음 | tokens·Op.Quad 재사용. 2차는 색공간 수학 신규(§8 결정) |
| **G7** | **세팅 페이지 셸** — 좌측 섹션 네비 + 검색 + 우측 폼 라우팅. 각 섹션을 위 위젯으로 조립, write-back(S0-1) 연결 | 중간 | modal/팔레트 레이아웃·검색 필터 재사용 |
| **G8** | **Keybindings 섹션** — `command_catalog` 행 목록 + 인라인 리바인드 → `keybind` 직렬화(unbind·매크로 포함) | 중간 | 카탈로그가 이미 단일 출처(`command_catalog.zig`) — 행 목록 공짜 |

## 7. 검증 매트릭스

[verification-matrix.md]·[project-rules.md] 테스트 원칙을 따른다. 영역별 경로:

- **config write-back/serialize**: `updateConfigText`/`serializeConfig` round-trip 순수 단위(Linux CI). enum·
  bool·float·배열(palette/padding) 각 케이스 + 주석/미지원 키 보존.
- **렌더(투명도·블러·이미지·dim)**: 셰이더/프레임 빌더 헤드리스 + `zig build macos-app` 실행 확인(시각은
  수동 — [run-macos-app-before-merge] 규율).
- **키 인코딩(option-as-meta·word-sep)**: `encodeKey`/`wordBoundsAt` 순수 단위(Linux CI) + PTY 캡처.
- **chrome 위젯**: 각 컴포넌트 State+handle 헤드리스(neutral) + macOS 통합(hit-test·드래그).
- **auto-reload·watcher·NSAppearance**: 자동화 어려우면 수동 검증 방법을 PR 한계에 기록.

## 8. 결정 (합의됨, 2026-06)

[project-rules.md] "문서에 없는 결정은 먼저 보고" — 아래는 아키텍처/UX에 영향이 있어 착수 전 합의했다.

1. **color picker 1차 범위** — ✅ **16색 프리셋 + hex 텍스트 입력**으로 시작(G3 재사용). HSV 2D picker는
   후속(G6 2차).
2. **시스템 라이트/다크 config 구조** — ✅ **`theme.follow-system = true` + `theme.preset-light`/
   `theme.preset-dark`** 2프리셋을 OS 외관에 따라 전환. 개별 색 override도 light/dark 접미로 표현(F2-9).
3. **option-as-meta 기본값** — ✅ **`true` 보존**(현재 동작 = 항상 meta-ESC). 회귀 없음. `input.option-as-meta
   = false`로 opt-out(Option+키 특수문자 입력).
4. **env/shell write-back 시 민감정보** — config 파일은 사용자 소유라 **값 보존이 기본**(GUI가 적은 값을
   파일에 그대로). GUI 표시/trace에서만 [project-rules.md] redaction 기준으로 마스킹.

## 9. 진행 규율

- **doc-first**: 이 문서로 합의한 뒤 스택으로 구현한다([drive-multi-pr-plan-to-completion] 규율 — 모든 PR을
  끝까지, 마지막에 `/code-review max`, main 자동 머지는 안 함).
- 각 PR은 [pr-checklist.md] 9개 섹션을 전부 채우고, 렌더/플랫폼 변경은 [renderer-strategy.md]·
  [macos-app-host-boundary.md]에서 유도 근거를 밝힌다.
- 구현 중 이 계획과 실제가 갈리면 임의로 진행하지 않고 보고한 뒤 이 문서를 갱신한다.

## 관련 문서

- [설정(config) 파일](configuration.md) — 키·형식·검증 단일 출처
- [키 입력과 단축키 경계](key-input-and-shortcuts.md) — 키바인딩/액션 경계
- [Chrome 전략](chrome-strategy.md) — GUI를 그리는 컴포넌트 구조
- [레이어링과 이식성 전략](layering-and-portability.md) — 네이티브 최소·이식성
- [macOS 앱 호스트 경계](macos-app-host-boundary.md) — Swift/Zig 책임 분담
- [폰트 전략](font-strategy.md) — 폰트/셰이핑(합자 보류 근거)
- [PR 체크리스트](pr-checklist.md) — PR 본문/검증 규율
