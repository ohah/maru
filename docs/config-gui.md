# config GUI — 스키마 메타에서 자동 생성하는 세팅 화면 (CS-4)

세팅 화면(GUI)을 **config 스키마의 메타**([config-schema.md])에서 **자동 생성**한다. 각 필드의
`Widget`·`Section`·`range`·`doc` 메타가 곧 위젯·그룹·검증·설명이 되므로, 스칼라 ~40개는 **GUI 코드 0줄**로
화면에 뜬다. 손으로 짜는 건 bespoke 에디터(팔레트·env·keybind·shell.args) 몇 개뿐이다.

이 문서는 [세팅 페이지 전략](settings-page.md)의 **Phase G(GUI)를 스키마-주도로 재정의**하고, CS-4의 doc-first
PR 분해를 단일 출처로 둔다. config 키·메타는 [config-schema.md], chrome 컴포넌트 구조는 [Chrome 전략](chrome-strategy.md)이 단일 출처다.

> 상태(2026-06): **설계 단계**. config 스키마 마일스톤(CS-1·CS-2·CS-2b·CS-3)이 머지돼 토대는 완성. 이 문서로
> 합의 후 CS-4를 스택으로 구현한다. **CS-4는 시각/상호작용이라** 각 PR을 머지 전 `zig build macos-app`로 실기
> 확인한다(스키마 PR처럼 헤드리스 단위만으로 blind 머지하지 않는다 — [run-macos-app-before-merge] 규율).

## 0. 목표와 범위

- **메타가 곧 UI.** schema 필드 1개 = 세팅 행 1개. 위젯 종류·범위·라벨·섹션이 메타에서 파생되므로, 새 config
  키를 추가하면(스키마 decl 1줄) **세팅 화면에도 자동으로** 뜬다(GUI 코드 추가 0줄).
- **config 파일이 단일 출처.** GUI는 파일을 읽고 쓰는 편집기. 저장은 **기본값 위 override만**([config-schema.md]
  §0; 직렬화는 S0-1b 의존 — §7).
- **Zig+GPU chrome.** 네이티브 뷰 비사용([chrome-strategy.md], [ui-strategy-zig-gpu-renderer]). 이식성.
- **범위 밖**: 합자(보류, [settings-page.md] §0). Warp식 블록/AI 패널(maru 비대상).

## 1. 아키텍처: 스키마 → 위젯

런타임에 host(platform)가 `schema`를 순회해(comptime 메타 + 현재 `Config` 값) 각 필드의 **위젯 prop**을 만들고,
neutral chrome 위젯이 그걸 그린다. 위젯 종류는 **타입 + `Meta.widget`** 으로 정한다(`.auto`면 타입에서 유추):

| 필드 타입 | 위젯(`.auto`) | prop(메타에서) |
|---|---|---|
| `bool` | toggle | 현재값, label=doc |
| `enum` | dropdown | 옵션=enum 토큰(`_`↔`-`), 현재값 |
| `f32`/`u32` + `range` | slider (+ 숫자 입력) | min/max=range, step, 현재값 |
| `[]const u8` (widget=`.text`) | text input | 현재값(IME) |
| `[]const u8` (widget=`.color`) | color input | 현재 #RRGGBB |

- **섹션**: `Meta.section`(font/theme/cursor/window/input/terminal/workspace/quick_terminal/sidebar)이 좌측
  네비 그룹이 된다. 같은 section 필드가 한 패널에 모인다.
- **설명**: `Meta.doc`가 행 라벨/툴팁. (풍부한 비고는 configuration.md가 단일 출처 — GUI는 짧은 doc.)
- **검증**: 입력값은 **parse와 같은 경로**(schema.tryParse)로 검증해 GUI와 파일이 같은 규칙을 쓴다(드리프트 없음).
- **현재값/변경**: 현재값=resolved/raw Config. 변경=그 키만 write-back(override). 입력 즉시 또는 저장 버튼(§10 결정).

## 2. 제너릭 렌더러

- platform(`app_session`/host)이 `schema`를 순회해 section별로 `FieldRow{ key, widget_kind, label, value, range }`
  목록을 빌드한다(chrome은 `theme.Config`/메타를 import 못 하므로 host가 neutral prop으로 내린다 — find/palette가
  카탈로그 행을 받는 패턴과 동일, [chrome-strategy.md] C1).
- chrome `components/settings.zig`(신규)가 그 행 목록을 받아 위젯별 view/handle을 호출. 위젯은 각자 neutral
  컴포넌트(State+view+handle)다.
- bespoke 필드(palette·env·keybind·shell.args)는 host가 전용 행 종류로 표시하고 전용 에디터를 띄운다(§5).

## 3. ChromeHost 마우스 pointer 이벤트 (CS-4-0, 선결)

현재 `ChromeHost`는 **키 이벤트만** 라우팅한다([chrome-strategy.md] C1 host). 슬라이더 드래그·색 그리드·토글
클릭엔 **마우스 pointer**가 필요하다.

- `input.InputEvent`에 pointer 변형(down/move/up + backing-px 좌표 + 버튼) 추가. 좌표·hit-test는 Zig
  (divider/sidebar/tabbar의 `hitTest` 패턴 단일 출처), 동작은 컴포넌트.
- `ChromeHost.handlePointer`가 활성 모달(세팅 페이지 등)에 라우팅. drag 상태(divider §6 라이브 포인터 패턴 재사용).
- platform(Swift)은 raw 좌표/버튼만 ABI로 넘긴다(네이티브 최소 — scroll_wheel/mouse와 같은 규율,
  [macos-app-host-boundary.md]).

## 4. 세팅 페이지 셸 (CS-4-4)

- **레이아웃**: 좌측 **Section 네비**(아이콘+이름) + 상단 **검색**(필드 key·doc 실시간 필터) + 우측 **폼**(선택
  section의 FieldRow 위젯들). 모달 오버레이 레이어(팔레트/Find와 같은 `ChromeHost` 모달, 우선순위 §host).
- **열기**: 빌트인 키(예: `⌘,` — §10 결정) 또는 메뉴 "Settings…" / 커맨드 팔릿. `toggle_settings` app action.
- **검색·blur**: 사이드바 검색바와 같은 규율(검색 영역 밖 클릭/Esc로 blur → 키 포커스 터미널 복귀).
- **저장**: 변경된 키를 override로 config 파일에 write-back(S0-1b) + atomic write(주석 보존 — sidebar.* 토글이
  쓰던 `take_*_dirty`→serialize→atomic write 패턴 일반화, [configuration.md] 구현 경계).

## 5. bespoke 에디터 (CS-4-5)

스키마로 안 떨어지는 특수 키(7종, [config-schema.md] §6)는 전용 위젯. 어차피 Phase G에서 만들 것이라 손해 아님:

| 특수 | 에디터 |
|---|---|
| `theme.palette.0~15` | 16칸 색 그리드(color input 재사용) |
| `env.<KEY>` | KEY/VALUE 행 리스트(추가/삭제/인라인 편집) |
| `keybind` | `command_catalog` 행 목록 + **인라인 키 캡처(recorder)** — 카탈로그가 단일 출처라 행은 공짜 |
| `shell.args` | 토큰 리스트(공백 분리/조립) |
| `theme.preset` | 프리셋 드롭다운(개별 색 위에 base) |
| `window.padding-x/y` | (alias라 GUI는 4방 개별만 노출, x/y는 숨김) |

## 6. 재사용 가능한 chrome 패턴 vs 신규

조사 결과(기존 `src/chrome/components/`):

| 위젯 | 재사용 | 신규 |
|---|---|---|
| 텍스트 입력 + caret | `overlay_input`(Find/팔레트) | — |
| 토글 | `context_menu` 체크박스(✓) | State+Action 얇게 |
| 드롭다운/리스트 | `palette`(선택·네비·윈도잉) | 검색 없는 정적 변형 |
| hit-test/드래그 | `divider`/`sidebar`/`tabbar` `hitTest`·`dragRatio` | pointer 이벤트(§3) |
| GPU quad/rounded/shadow | `ChromeDraw.quad` + 토큰 | — |
| 입력 라우팅 | `ChromeHost`(모달 우선순위) | pointer + 위젯 State |
| **슬라이더** | divider `dragRatio` 참고 | bar+thumb view + 드래그 |
| **color input** | quad + 토큰 | 1차: 16색 프리셋 + hex 입력(text 재사용); 2차: HSV picker |
| **keybind recorder** | `input.InputEvent` 그대로 | 녹음 State(키 캡처) |

> 핵심 리스크 2개: **color picker**(2차 HSV는 색공간 수학·2D 그리드 — 1차는 16색+hex로 우회) + **pointer
> 이벤트가 host에 아직 없음**(§3 CS-4-0이 선결). 나머지는 기존 패턴 변형이라 낮음.

### 6.1 위젯 렌더 — tui(셀 정렬 text) vs rich(GPU quad)

위젯 view는 `tokens.space.corner_radius_px`로 두 룩을 분기한다(테마는 위젯 불변, [chrome-strategy.md] §5.4):

- **rich(>0)**: GPU `ChromeDraw.quad`(SDF) — 둥근 pill·원형 knob·얇은 트랙·그림자 등 sub-pixel.
- **tui(0, 기본 테마)**: **셀 정렬 text**(`Op.text`). 토글 `[█ ]`/`[ █]`(knob=`█`, 켜짐=accent_bar 우/꺼짐=surface_fg 좌), 슬라이더 `[███   ]`(채움=`█`×ratio accent_bar, 트랙=muted_fg), dropdown `값 ▾`. control 열 좌단 정렬(세 위젯 같은 시작 x).

  **결정 근거**: tui lowering은 quad를 `paintRectBg`로 **셀 단위** 배경에 칠한다. 위젯을 quad로 두면 (1) 얇은 트랙(높이 h/4)이 `@divTrunc`로 r0==r1이 돼 사라지고, (2) 행 높이 채움이 셀 경계에서 위아래로 번지며, (3) 선택 하이라이트(셀 bg)와 같은 레이어라 서로 덮어 거칠게 겹쳤다(겹침·가림 회귀). text는 placeText가 셀 정렬로 놓고 **text 레이어**(셀 bg 위)라 선택 하이라이트 위에 또렷하다(dropdown·palette 행과 동형). `█`(U+2588)는 합성 글리프라 폰트 무관 렌더. 위젯 view에 `cw`(셀 폭)를 넘겨 tui text 칸/오프셋을 계산한다.

## 7. 의존성

- **S0-1b** ✅(머지) — `serialize.updateForKeys(original, config, keys)`로 **변경 키만** write-back(즉시-저장 결정에
  맞춤; override-only by construction — 기본값 40개를 안 쏟는다). `serializeSidebarConfig`가 이걸로 재구현됨. GUI도
  같은 경로(바뀐 필드의 키를 넘김). (full-config diff·dirty 비트마스크는 불필요 — 즉시-저장은 키 단위.)
- **CS-4-0**(ChromeHost pointer) — 슬라이더·색 그리드 선결.
- **S0-2**(자동 reload) — 외부 편집 즉시 반영(선택, GUI와 직교).
- 위젯 컴포넌트(CS-4-1~3).

## 8. PR 분해 (CS-4)

| PR | 내용 | 검증 |
|---|---|---|
| **S0-1b** ✅ | per-key write-back(`updateForKeys` — 변경 키만, override-only) + `serializeSidebarConfig` 재구현 | ✅ 머지(순수 단위) |
| **CS-4-0** | `ChromeHost` pointer 이벤트(InputEvent + 라우팅 + drag) | 헤드리스 + macos 실기 |
| **CS-4-1** | 위젯 컴포넌트 toggle·dropdown·text/number·slider(neutral State+view+handle) | 헤드리스 단위 + 실기 |
| **CS-4-2** | color input(16색 프리셋 + hex 입력) | 헤드리스 + 실기 |
| **CS-4-3** | keybind recorder(`command_catalog` 행 + 키 캡처) | 헤드리스 + 실기 |
| **CS-4-4** | **세팅 페이지 셸** — Section 네비 + 검색 + 제너릭 폼(schema 메타 소비) + `toggle_settings` 키/메뉴 | 헤드리스 + 실기 |
| **CS-4-5** | write-back 연결(S0-1b) + bespoke 에디터(palette·env·shell.args) | 헤드리스 + 실기 |
| **CS-4-6+** | (선택) color HSV picker 2차, 고급화 | 실기 |

> 시각/상호작용 PR(CS-4-0~5)은 로직을 헤드리스 단위로 고정하되, **머지 전 `zig build macos-app`로 ohah가 실기
> 확인**한다(보이나·눌리나·드래그되나). 스키마 PR과 결정적으로 다른 점.

## 9. 검증 전략

- **위젯 로직**: neutral `State`+`handle` 헤드리스 단위(클릭·드래그·키 → Action 전이), hit-test 순수 함수.
- **제너릭 렌더러**: schema 순회→FieldRow 빌드 헤드리스(필드 수·위젯 종류·section 그룹).
- **저장 round-trip**: override-only 직렬화 단위(기본값 안 씀, 변경분만; 주석 보존).
- **시각/상호작용**: `zig build macos-app` 실기(세팅 열기·각 위젯 조작·저장→파일 확인). 자동화 어려운 부분은 PR
  한계에 수동 검증 절차 기록([verification-matrix.md]).

## 10. 결정 필요 (CS-4 착수 전)

1. **세팅 열기 키**: `⌘,`(macOS 관례) 빌트인 vs 메뉴/팔릿만. (`⌘,`는 현재 "Open Config…"가 메뉴에 있음 — 충돌 정리.)
2. **저장 방식**: 변경 즉시 write-back(사이드바 ⚙ 토글처럼) vs 명시 "저장" 버튼. (즉시가 maru 기존 결과 일치.)
3. **color picker 1차 범위**: 16색 프리셋 + hex 입력 확정([settings-page.md] §8 합의). HSV는 CS-4-6.
4. **Open Config 메뉴 관계**: 세팅 GUI와 "Open Config…"(파일 열기) 공존? GUI가 주, 파일 직접 편집은 보조.

## 관련 문서

- [config 스키마(메타 1급 필드)](config-schema.md) — 위젯/섹션/범위 메타의 출처(GUI가 소비)
- [세팅 페이지 전략과 구현 계획](settings-page.md) — 상위 계획(이 문서가 §6 Phase G를 재정의)
- [Chrome 전략](chrome-strategy.md) — 위젯을 그리는 컴포넌트·host·draw 구조
- [설정(config) 파일](configuration.md) — 키·형식·검증·풍부한 비고(GUI 짧은 doc의 상세판)
- [macOS 앱 호스트 경계](macos-app-host-boundary.md) — pointer raw 좌표 등 Swift/Zig 분담
- [PR 체크리스트](pr-checklist.md) — 시각 PR의 실기 검증 규율
