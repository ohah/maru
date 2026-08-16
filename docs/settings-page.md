# 세팅 페이지 전략과 구현 계획

Maru는 설정을 **config 텍스트 파일**(`docs/configuration.md` 단일 출처)로 두되, 그 위에 **앱 내 세팅
화면(GUI)** 을 얹는다. 이 문서는 세팅 GUI의 전략·섹션 구조·양방향 반영 토대·신규 기능 추가의 **doc-first
PR 분해**를 단일 출처로 둔다. 실제 키·형식·검증은 항상 [설정(config) 파일](configuration.md)이, GUI를
그리는 chrome 구조는 [Chrome 전략](chrome-strategy.md)이, 키바인딩 경계는 [키 입력과
단축키](key-input-and-shortcuts.md)가 단일 출처다 — 여기서는 중복하지 않고 연결한다.

> 상태(2026-06): **진행 중**. S0-1a·F1-1·F1-2·F1-3·F1-4b(blink-interval-ms·unfocused)·F1-5·F1-6·F1-8·F1-9·F1-10(multiplier)·F2-2(option-as-meta)·F2-3(bold/italic-family)·F2-4(visual-bell·dock-badge)·F2-5(right-click)·F2-6(osc52-read)·F2-7(unfocused-dim)·F2-8(word-separators)·F2-9(follow-system)·F2-1(background-image)·F3-1(window-blur) 머지(F1-7·F1-10 on-output은 기존 구현/표준) — **F1·F2·F3 신규 기능 트랙 전부 완료**(다음은 G 트랙: 세팅 GUI 위젯·페이지). 세팅 GUI
> (CS-4-0~6, config-gui.md) 완료 후 미뤄둔 신규 기능(F1~F3)을 schema-first로 채우는 단계. 가벼운(순수 Zig·ABI 무변경)
> 항목부터 순차 진행. 진행 상황은 각 PR 표의 상태 칸으로 동기화한다.
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
| **App** | `ui.*` | language(`auto`\|`en`\|`ko`, 기본 `auto`=OS 로케일). **네비 최상단이다** — 읽을 수 없는 언어로 뜬 화면에서는 다른 섹션을 고르는 것부터 어렵기 때문이다. `Section` enum 선언 순서가 곧 네비 순서라(`buildSectionList`가 선언 순으로 모은다) `app`을 첫 변형으로 두어 그 순서를 만든다. 단일 출처: [다국어](i18n.md) |
| **Appearance › Font** | `font.*` | family, size, line-height, letter-spacing, (신규) family-bold/italic, fallback |
| **Appearance › Theme** | `theme.*`, `chrome.theme` | preset(최상단·활성 시 개별 색·palette 잠금→클릭 시 "사용자 지정" 전환), 개별 색, palette 16, bold-is-bright, follow-system (search_match\*/sidebar_\*는 config 키가 없어 preset에서 파생 — 직접 편집/노출 안 함, theme.zig 상단 주석) |
| **Appearance › Cursor** | `cursor.*` | shape, blink, color/text, (신규) blink-interval, blink-fade, unfocused |
| **Appearance › Window** | `window.*` | padding, (신규) opacity, blur, background-image, unfocused-dim |
| **Input › Keys** | `input.*` | page-keys, shift-enter, ime-enter, (신규) option-as-meta |
| **Input › Mouse** | `input.*` | (신규) url-click-modifier, right-click, mouse-hide-while-typing, word-separators, scroll.* |
| (Input 안의 keybind 행) | `keybind` | 별도 네비 섹션이 아님 — 인앱 keybind 녹음 행은 **Input** 섹션에 접혀 든다(action 카탈로그 전체 + 인라인 리바인드/unbind, config-gui.md §6.7). `keybind` Section enum 멤버는 없다 |
| **Global Hotkey** | (전역 OS 단축키) | schema 필드 없는 특수 섹션 — 전역 OS 단축키 녹음 행만(global action별 한 행, app_session이 강제 포함·라벨 "글로벌 핫키"). 매크로 rhs는 config 파일 직접 편집(후속) |
| **Terminal** | `term`, `scrollback.*`, `bell.*`, `notifications.*`, `osc52.*`, `shell.*`, `env.*` | TERM, 스크롤백, 벨(audible/visual/badge), 알림, OSC52 read, 셸/인자, env |
| **Workspace** | `workspace.*`, `session.*` | root, tab/split inherit-cwd, `session.keep-alive-after-quit` |
| **Quick Terminal** | `quick-terminal.*` | height/width/position/screen/auto-hide/chrome/minimal-tabs (라이브 반영 — 매 토글 재조회, config-gui.md §6.10; chrome/minimal-tabs만 세션 재생성) |
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
| **S0-1b** ✅ | **per-key write-back 일반화** — `serialize.updateForKeys(original, config, keys)`가 넘긴 키만 현재값으로 `updateConfigText` 부분 갱신(즉시-저장 GUI 결정에 맞춤 — full-config diff 대신 변경 키만; **override-only by construction**). 사이드바 write-back 경로(`serialize_sidebar_config` ABI export, snake_case 이름은 호환 유지 — `AppSession.serializeConfig`가 래핑)도 이 `updateForKeys`를 쓴다(bool 손코드 제거, byte-identical). | 낮음 | ✅ 머지. dirty 비트마스크·전체 diff는 불필요(즉시-저장은 변경 키만 씀); GUI는 같은 `updateForKeys` 경로 |
| **S0-2** | config 파일 **자동 감지 reload** — macOS `DispatchSource`/FSEvents watcher(Swift), debounce(0.5~1s), 편집 중 불완전 파일 회피(.tmp→rename 가정), 기존 `reloadConfig` 재사용. `behavior.auto-reload`로 끌 수 있게. | 낮음~중간 | 🔜 Zig는 변경 없음(reload 이미 있음). watcher만 platform(Swift) |

> 경계: write-back은 **앱→파일**(GUI 편집 저장), reload는 **파일→앱**(외부 편집 감지). 둘은 직교하며 같은
> `updateConfigText`/`reloadConfig`를 공유한다. env 등 민감값 직렬화는 [project-rules.md] redaction 기준을
> 재사용한다(저장 시 평문이라도 config 파일은 사용자 소유 — trace/artifact와 기준은 같되 파일엔 사용자가
> 적은 값을 보존).

## 3. 신규 기능 — 쉬움 (Phase F1)

config 키 추가 + 기존 경로에 분기 한 줄. GUI 없이 config 파일로 즉시 검증 가능. 각 PR은 키 1~2개로 잘게.

| PR | 기능 / 키 | 핵심 변경 | 근거(현황) |
|---|---|---|---|
| **F1-1** ✅ | 배경 투명도 `window.opacity` | schema f32 slider[→ 이후 숫자 입력 박스로 렌더] + `MetalFrame.window_opacity_milli`(ABI v70) → 렌더러가 **화면 clear color alpha**에 곱(default 배경만 투명, 명시 cell bg 불투명 — iTerm2/Ghostty 모델). Swift가 opacity<1이면 metal layer/NSWindow 비불투명 | ✅ 머지. schema 파싱/range·resolve·frame milli 단위 테스트 + 실기(크래시 없음). 셰이더·셀 불변(clear alpha만) |
| **F1-1b** ✅ | 앱 주사율 `render.frame-rate` | Config 최상위 scalar schema(u32 number, 30~120, 기본 60) → Cmd+, **창** 섹션에 자동 노출. Swift host가 ABI `frame_rate_hz`로 config 희망값을 읽어 앱 전역 단일 `NSTimer` interval을 정하고, 설정 변경 시 다음 tick에 timer 재시작. 실제 tick에서는 `maru_macos_app_session_tick(session, frame_loop_rate_hz, ...)`로 host 전역 cadence를 각 Zig session에 주입해 blink/fade/poll/sync timeout의 ms→tick 환산 기준을 통일 | ✅ schema parse/range + AppSession helper + ABI getter/tick cadence 단위 테스트. 실제 모니터 주사율 자동 추적/vsync는 아님(CVDisplayLink 후속) |
| **F1-2** ✅ | 폴백 폰트 `font.fallback` | 쉼표 구분 CSV(`FontConfig.fallback`) → `ResolvedFontRequest.fallback` → 셰이퍼가 `shape_draw_list` ABI로 ObjC에 전달 → 주 폰트에 **사용자 폴백 + CoreText 기본 cascade**를 `kCTFontCascadeListAttribute`로 박은 새 CTFont(매 cell 변경 불요). 빈=현행(자동 cascade만) | ✅ 머지. config 파싱·resolve 전파 단위 테스트 + 실기 정상 렌더(크래시 없음). 실제 한글/이모지 폴백 글리프는 실기 수동(한글 출력 필요) |
| **F1-3** ✅ | bold-is-bright `theme.bold-is-bright` | `packForeground`에 `brightenIfBold`(bold+indexed 0~7→+8) | ✅ 머지. render-only, packForeground 순수 단위 테스트 |
| **F1-4a** ✅ | 커서 색 `cursor.color`(칸)·`cursor.text`(반전 글자) | 테마 독립 opt-in. nullable이라 loader 수동 핸들러·serialize 수동 emit(palette 선례), `ResolvedCursor`에 색 추가 후 렌더가 `orelse` 테마 폴백 | ✅ 머지. 기존 동작(흰 커서) 보존. resolve/round-trip/parse 단위 테스트 |
| **F1-4b** ✅ | 커서 `cursor.blink-interval-ms` ✅ / `cursor.unfocused` ✅ | `blink_interval_ticks` 상수(15)→config ms 기반. **후속 정정**: 처음엔 `blinkIntervalTicks()`가 ms를 *설정* `render.frame-rate` 기준 tick으로 환산했는데, 실효 tick rate가 설정보다 낮으면(무거운 tick·백그라운드 스로틀링) 반주기가 그만큼 길어져 깜빡임이 느려졌다 → **wall-clock 위상**(`blink_phase_ns`)으로 이주하고 helper는 폐기했다(§10.5). `unfocused`(block/hollow/hidden)는 app이 `window_focused`로 `unfocusedCursorMode()` 산출→renderer `CursorUnfocused`로 cursor overlay에 wiring(F1-4b-2). hollow=metal_frame이 reserved 2/4/3/5 변 cell 4개로 외곽선, hidden=overlay.visible=false. **활성 surface는 `CoreTextFrameBuilder.build`(host buildDrawList 아님), 비활성 split pane은 per-pane 루프** 두 경로 모두 모드 주입 | ✅ blink-interval-ms 머지 + `unfocused` 머지(draw_list/metal_frame 단위 테스트 + 3모드 헤드리스 스크린샷 self-verify). `MARU_FORCE_UNFOCUSED_CURSOR` debug-gate로 캡처 |
| **F1-5** ✅ | URL 클릭 modifier `input.url-click-modifier` | modifier 판정을 Zig 단일 출처로 이주(`urlModifierHeld`) — hover/url_at ABI의 `cmd_held`(bool)→`mods`(xterm 비트, **v71**), Swift는 NSEvent 수식키→비트 변환만(네이티브 최소·이식성). enum `command`/`control`/`alt`/`shift`(기본 command=현행 Cmd) | ✅ 머지(`urlModifierHeld` + schema enum 단위 테스트, 실기 빌드). 실제 클릭/hover는 수동 |
| **F1-6** ✅ | 타이핑 중 커서 숨김 `input.mouse-hide-while-typing` | Zig가 **IME 확정 텍스트가 터미널로 갈 때**(`routeCommittedText` — 평범한 글자는 macOS IME가 커밋, handleKeyEvent 우회; ASCII·한글·CJK 포함) `take_mouse_hide` 1회성 신호(ABI **v72**, take_bell 동형), Swift가 `NSCursor.setHiddenUntilMouseMoves`(복원 자동). 기본 false. Ghostty `mouse-hide-while-typing`(press+utf8>0) 모델 | ✅ 머지 + **code-review max 수정**(옛 handleKeyEvent .char 경로는 IME 우회로 실제 타이핑을 놓쳐 죽은 기능이었음 → IME 커밋 경로로 이동) |
| **F1-7** ✅ | 탭 닫기 확인 | **이미 구현** — `request_window_close`(ABI v65)가 in-app 닫기(close_tab/탭바 ✕)에도 `requestClose`로 같은 확인 모달을 띄운다(창 전용 아님) | ✅ 기존 구현(상단 노트와 동기 — 표 상태만 정정) |
| **F1-8** ✅ | env 주입 `env.<KEY>` | `SpawnRequest.env_overrides` + `EnvStorage` upsert(부모 상속 위 덮어쓰기/추가) | ✅ 머지. 부모+사용자 정책, EnvStorage upsert 단위 테스트 |
| **F1-9** ✅ | 커스텀 셸 `shell.command`/`shell.args` | `spawnRequest` interactive 분기가 config.shell 사용(login 래퍼는 그대로 — `/bin/bash`는 메커니즘) | ✅ 머지. loader·serialize 단위 테스트. `command/args`는 spawn이 이미 받음 |
| **F1-10** ✅ | 스크롤 `scroll.multiplier` ✅ / `scroll.on-output`(불필요) | `scrollWheel` 세로 delta에 배수(0.1~10, 가로 탭 바 제외). `on-output`은 **이미 구현된 동작이라 config 불요** — maru는 viewport pin(`core.zig` `view_offset += 1`: 과거 보면 출력 와도 고정, 맨 아래면 따라감)으로 **Ghostty와 동일하게** 동작하고 Ghostty도 `scroll-on-output` config가 없다. xterm `scrollTtyOutput`(출력 시 항상 맨 아래 점프)은 Ghostty도 안 채택하는 레거시라 두지 않는다 | ✅ multiplier 머지. `on-output`은 viewport pin이 표준이라 정정(F1-7식 — 코드 무변경) |

## 4. 신규 기능 — 중간 (Phase F2)

새 코드 한 덩어리(≈80~150줄). 일부는 코어+ABI 양쪽.

| PR | 기능 / 키 | 핵심 변경 | 근거(현황) |
|---|---|---|---|
| **F2-1** ✅ | 배경 이미지 `window.background-image` | 문자열(PNG 절대경로, 기본 빈 값=배경 없음). app_session이 경로 바뀐 frame에만 `terminal/png.zig`로 디코드(매 frame 디코드 방지)해 owned RGBA 캐시 + generation으로 렌더러 텍스처 1회 업로드. frame-build에서 **풀-윈도 pass-0 GpuImage**(aspect-fill cover·중앙 UV crop)를 kitty 채널 **앞에** prepend — kitty graphics 텍스처 캐시·image quad 인프라 재사용, **렌더러 ObjC 변경 없음**. 예약 image id `0xFFFF_FFFF`. default 배경 셀(빈 영역)이 투명이라 이미지가 비치고 명시 배경색 셀·텍스트·커서는 그 위(=`window.opacity`와 같은 iTerm2/Ghostty 레이어 모델). **세팅 GUI에선 경로 타이핑 대신 파일 선택창**(이 행 활성→NSOpenPanel(PNG); 지우기=행 Backspace) — ABI v81 `take_file_pick_request`/`provide_picked_file`(OSC52 read take/provide 패턴, "언제"는 Zig·OS 다이얼로그는 Swift) | ✅ 머지. loader 파싱(경로/빈 기본)·schema·**파일 선택창 행 활성→요청·provide→적용·Backspace→지우기** 단위 테스트. **PNG 8-bit truecolor만**(maru 내장 디코더; JPEG 등 후속). 못 읽거나 디코드 실패면 조용히 폴백(배경 없음). **헤드리스 스크린샷 self-verify**(640×400 4사분면+중앙 흰 원 PNG → 터미널 영역 aspect-fill, 셀·커서가 위에) |
| **F2-2** ✅ | Option=Meta 토글 `input.option-as-meta` | bool(기본 true=현행 항상 meta). `EncodeOptions.option_as_meta`로 encodeKey ESC-prefix 게이트 + AppSession 세션 캐시(reload 갱신) + frame_loop/host.handleKeyEvent에 인자 전달. **Swift keyDown**이 ABI `option_as_meta`(v73 getter)를 읽어 false면 Option-단독 키를 입력기 조합 경로(macOS 특수문자 ∫·´)로, Cmd/Ctrl 동반만 우회 | ✅ 머지. input.zig(false→ESC 없음)·schema 파싱 단위 테스트, ABI v73(순수 read getter). 좌/우 Option 구분은 후속(device-independent `.option`). Ghostty `macos-option-as-alt` 베이스, 기본은 maru "회귀 없음" 선례 따라 true |
| **F2-3** ✅ | Bold/Italic family `font.family-bold`/`family-italic` | 문자열 2개(빈 값=주 family variant). **italic 렌더 신설**(이전엔 SGR 3 미반영) — style_flags에 italic 비트 추가. coretext_smoke.m에 4-face 캐시(regular/bold/italic/bold-italic, lazy): family 지정+존재면 그 패밀리(+cascade+traits), 아니면 primary symbolic trait 파생, 없으면 regular 폴백. bold-italic=bold face+italic. 셰이퍼 시그니처에 bold/italic family ptr/len 추가(F1-2 fallback 패턴, ABI 무관 내부) | ✅ 머지. schema 파싱 단위 테스트, **헤드리스 스크린샷 self-verify**(MARU_FORCE_STYLED — BOLD 굵게·ITALIC 슬랜트·BOTH 둘 다·regular 구분 확인). 기본 빈 값=주 폰트 variant(회귀 없음). Ghostty `font-family-bold/italic` 베이스 |
| **F2-4** ✅ | 시각 벨 + Dock 배지 `bell.visual`/`bell.dock-badge` | bool 2개(기본 false). **dispatchBell**이 BEL 1회를 단일 drain해 audible/visual/badge로 분배(takeBell은 코어 아닌 이 신호를 봄). visual=full-screen 전경색 반투명 **GpuQuad**(layer 1 over) ~250ms 페이드(8 tick, dispatchBell이 metal_dirty로 애니메이트) — **ABI/셰이더 무변**(기존 quad 패스 재사용). dock-badge=BEL+언포커스 시 `take_bell_badge`(v76 1회성)→Swift `NSApp.dockTile.badgeLabel="●"`, applicationDidBecomeActive가 지움 | ✅ 머지. schema·dispatchBell(audible/visual/badge·언포커스 게이트) 단위 테스트, ABI v76. **시각 벨 flash 헤드리스 스크린샷 self-verify**(MARU_FORCE_BELL — 전경색 오버레이 확인). Dock 배지는 OS dock이라 수동 |
| **F2-5** ✅ | 우클릭 동작 `input.right-click` (paste\|menu\|reporting) | enum(기본 **paste**=사용자 결정). 터미널 본문 우클릭에서 `core.mouse_tracking != .none`이면 리포팅 우선(현행 fall-through), 아니면 분기: paste→`pending_clipboard_action=.paste`, menu→`terminal_context_menu` 컨텍스트 메뉴(복사/붙여넣기), reporting→무동작. OS 클립보드는 **take_clipboard_action(ABI v74, take_bell식 1회성)**로 Swift가 copy/paste 실행 — "언제"는 Zig, "실행"은 OS. 사이드바/탭 우클릭은 그대로 Rename/Pin | ✅ 머지. schema enum + 파싱 단위 테스트, ABI v74. 기본 paste는 현행(reporting) 변경이라 사용자 결정 기록. menu는 기존 context_menu 인프라 재사용(terminal_context_menu 플래그) |
| **F2-6** ✅ | OSC52 read `osc52.read` (allow\|deny) | enum(기본 **deny**=탈취 방지, 보안). 코어 `dispatchOscClipboard`가 `?` 쿼리를 파싱해 `clipboard_read_pending`+target 세움(write 대칭, 코어는 OS 클립보드 안 읽음). **정책 게이트는 app**(`takeClipboardReadRequest` — deny면 클립보드 안 읽고 pending 소비, allow만 true). ABI v75 신규: `take_clipboard_read_request`(게이트)·`provide_clipboard_read`(Swift가 읽은 클립보드 → `formatOsc52ReadResponse` base64 `ESC]52;Pc;b64 ST` → paste FIFO로 PTY). 16MB 상한 | ✅ 머지. core(`?`→pending+target)·app(게이트·포맷)·schema 단위 테스트, ABI v75. 기본 deny는 정책 문서와 일치(원격 클립보드 탈취 방지). 실제 read 응답은 수동 검증(프로그램 `?`+stdin) |
| **F2-7** ✅ | 비활성 split 디밍 `window.unfocused-dim` | f32(0~1) 최상위 키. **셰이더/ABI 불변** — metal_frame `packForeground`/`packBackground`가 최종 해석 색을 pane 배경 쪽으로 `dim_milli`만큼 per-cell 보간(`dimToward`). app은 비활성 pane `CellColors.dim_milli`에만 세움(`inactive_colors` 한 곳) → 활성 pane(CoreTextFrameBuilder, dim_milli=0)은 풀 밝기. SGR/truecolor 포함 모든 셀 일률 적용, default 배경(A=0)은 투명 유지 | ✅ 머지. 당초 "셀 focused 플래그+셰이더"보다 얕게(색공간 CPU 보간) — maru는 색을 CPU에서 풀어 NativeMetalCell에 싣고 per-pane compositor opacity가 없어 셰이더 변경 불필요. metal_frame/schema 단위 테스트 + `MARU_FORCE_SPLIT` 헤드리스 스크린샷 self-verify. 기본 0.0(opt-in, 회귀 없음). Ghostty `unfocused-split-opacity` 베이스 |
| **F2-8** ✅ | word separators `input.word-separators` | 문자열(기본 빈 값=현행 비공백 run). core `wordBoundsAtImpl(separators)`가 공백+config 구분자를 단어 경계로(구분자 위 클릭=1칸). **URL 감지(wordBoundsAt)는 구분자 무시** — `:`·`/`가 URL 안 쪼개게. ABI 신규 없음 — config 구분자를 `select_word` CoreCommand에 **복사**(SelectWord [64]u8, borrowed slice reload 수명 회피)해 실어 보냄 → 코어 무상태·항상 reload-safe | ✅ 머지. core(구분자 분할·구분자 1칸·URL 무영향)·schema 단위 테스트. 기본 빈 값=회귀 없음. Ghostty `selection-word-chars` 베이스 |
| **F2-9** ✅ | 시스템 라이트/다크 `theme.follow-system` + light/dark preset | §8 합의대로 `theme.follow-system`(bool) + `theme.preset-light`/`theme.preset-dark`(ThemePreset). **Config 직속 3필드**(색 세트 ThemeConfig 아님 — presetColors가 config.theme만 덮으므로). Swift가 `NSApp.effectiveAppearance`로 light/dark 판정 + `viewDidChangeEffectiveAppearance`(변경)·tick 1회(초기) → ABI `set_system_appearance`(v77). Zig `setSystemAppearance`→follow-system 켜졌으면 그 외관 preset로 `config.theme` 교체 + `reapplyLoadedConfig`(재resolve·팔레트 재주입·재렌더), **write-back 없음**(시스템 주도 비영속). reload도 재적용 | ✅ 머지. schema·setSystemAppearance(on=교체·off=무시) 단위 테스트, ABI v77. **헤드리스 스크린샷 self-verify**(MARU_FORCE_SYS_APPEARANCE): light=Solarized Light(크림)·dark=gruvbox-dark(웜브라운) 전환 확인 |

## 5. 신규 기능 — 어려움 (Phase F3)

| PR | 기능 / 키 | 핵심 변경 | 근거(현황) |
|---|---|---|---|
| **F3-1** ✅ | 배경 블러 `window.blur` | **계획 정정**: "2-pass Metal offscreen→Gaussian"으로는 구현 불가 — 어느 OS도 **Metal로 창 뒤(backdrop) 픽셀을 못 읽는다**. 창 뒤 데스크톱 블러는 GPU 렌더러가 아니라 **OS/컴포지터 창 속성**이다. 그래서 **platform 어댑터**로 구현: config `window.blur`(u32 반경, 0=끔) + `window.opacity<1` 게이트(유효 반경 정책은 Zig 단일 출처 `windowBlurRadius`, ABI v79 getter `window_blur_radius`). macOS host가 `CGSSetWindowBackgroundBlurRadius`(Ghostty·Terminal.app과 동일한 비공개 CGS, Swift `@_silgen_name`)를 값 변화 시에만 호출. 추후 Windows=`DwmSetWindowAttribute`·Linux=`_KDE_NET_WM_BLUR_BEHIND_REGION`/kde-blur이 같은 자리를 채운다(컴포지터 의존 best-effort) | ✅ 머지. `effectiveWindowBlur`(게이트) + loader 파싱 단위 테스트, ABI v79. **시각 검증 한계**: 블러는 WindowServer가 창 뒤를 합성하므로 오프스크린 스크린샷 하니스로 못 잡는다(opacity<1+blur 설정 실기 실행으로 CGS 경로 no-crash 확인, 실제 블러는 데스크톱 수동 확인). Ghostty `background-blur` 베이스(references/ghostty embedded.zig:2106) |

## 6. 세팅 GUI — chrome 위젯 + 페이지 (Phase G)

> **재정의(2026-06)**: config 계층이 스키마-주도가 되면서([config 스키마](config-schema.md)), 세팅 화면은
> **스키마 메타(Widget/Section/range/doc)에서 자동 생성**된다 — 스칼라 ~40개는 GUI 코드 0줄. 그래서 아래 G0~G8
> (필드마다 손 위젯)의 **상당수가 "제너릭 위젯 N종 + 제너릭 렌더러" 하나로 붕괴**한다. 갱신된 단일 출처:
> **[config GUI(스키마-주도 세팅 화면)](config-gui.md)** (CS-4-0~5). 아래 표는 위젯 종류의 출발 스냅샷으로 남긴다.

기능이 config로 다 들어간 뒤, 그 위에 GUI를 얹는다. **거의 모든 토대가 chrome에 이미 있다** — 텍스트
입력+caret(Find/팔레트), 토글(context_menu 체크박스), 드롭다운(팔레트), 스크롤 리스트, hit-test 패턴,
GPU rounded quad, 입력 라우팅(ChromeHost). **신규 리스크는 ① color picker(가장 무거움) ② ChromeHost에
마우스 pointer 이벤트가 아직 없음(슬라이더·색 그리드 선결)** 둘이다. ※ 슬라이더는 이후 `input_box`(숫자 직접 입력)로 대체·`slider.zig` 제거됨.

| PR | 내용 | 난이도 | 재사용/근거 |
|---|---|---|---|
| **G0** | **ChromeHost pointer 이벤트** — 마우스 down/move/up을 `InputEvent`로 확장(슬라이더 드래그[→ 슬라이더는 이후 input_box로 대체]·색 그리드 선결) | 중간 | divider/sidebar hit-test 패턴 존재, host 입력 라우팅 확장 |
| **G1** | `toggle.zig` 위젯 | 낮음 | context_menu 체크박스(✓) 기반 |
| **G2** | `dropdown.zig` 위젯(정적 목록) | 중간 | 팔레트 선택/네비 구조에서 검색 제거 |
| **G3** | `text_input`/`number_input` 위젯 | 중간 | `overlay_input.zig`(IME·caret) 재사용 + 숫자 검증 |
| **G4** | `keybind_input.zig`(키 캡처 recorder) | 중간 | `input.InputEvent`(OS 무관) 그대로 |
| **G5** | ~~`slider.zig` 위젯~~ → **`input_box.zig`(숫자 직접 입력)로 대체·slider.zig 제거** | 중간 | divider `dragRatio` 패턴 + G0 pointer |
| **G6** | 색 입력 — **1차: 16색 프리셋 + hex 텍스트(G3 재사용)**, 2차: HSV picker(RGB↔HSV + 2D 그리드) | 1차 중간 / 2차 높음 | tokens·Op.Quad 재사용. 2차는 색공간 수학 신규(§8 결정) |
| **G7** | **세팅 페이지 셸** — 좌측 섹션 네비 + 검색 + 우측 폼 라우팅. 각 섹션을 위 위젯으로 조립, write-back(S0-1) 연결 | 중간 | modal/팔레트 레이아웃·검색 필터 재사용 |
| **G8** | **Keybindings 섹션** — `command_catalog` 행 목록 + 인라인 리바인드 → `keybind` 직렬화(unbind·매크로 포함) | 중간 | 카탈로그가 이미 단일 출처(`command_catalog.zig`) — 행 목록 공짜 |
| **G9** ✅ | **폰트 피커** — `font.family`를 번들 폰트(`theme.bundled_font_families`) **열리는 드롭다운 팝업**으로(↑↓ 라이브 미리보기·Enter 확정·Esc 원복; 목록 끝 "직접 입력…"으로 목록 밖 폰트 인라인 타이핑). 자유 문자열이라 enum dropdown을 못 써 `.font` 행 종류 신규(config-gui.md §폰트 피커) | 낮음 | ✅ 머지(이후 ←→ 순환 → 열리는 팝업으로 업그레이드). `dropdown` 팝업 + text 편집 경로 재사용, GUI 코드 최소 |

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
