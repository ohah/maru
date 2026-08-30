# config GUI — 스키마 메타에서 자동 생성하는 세팅 화면 (CS-4)

세팅 화면(GUI)을 **config 스키마의 메타**([config-schema.md])에서 **자동 생성**한다. 각 필드의
`Widget`·`Section`·`range`·`doc` 메타가 곧 위젯·그룹·검증·설명이 되므로, 스칼라 ~40개는 **GUI 코드 0줄**로
화면에 뜬다. 손으로 짜는 건 bespoke 에디터(팔레트·env·keybind·shell.args) 몇 개뿐이다.

이 문서는 [세팅 페이지 전략](settings-page.md)의 **Phase G(GUI)를 스키마-주도로 재정의**하고, CS-4의 doc-first
PR 분해를 단일 출처로 둔다. config 키·메타는 [config-schema.md], chrome 컴포넌트 구조는 [Chrome 전략](chrome-strategy.md)이 단일 출처다.

> 상태(2026-06): **CS-4 구현 진행**. 스키마 토대(CS-1·CS-2·CS-2b·CS-3)에 더해 CS-4-0(pointer)·CS-4-1(toggle·
> slider[→ 이후 `input_box`로 대체·`slider.zig` 제거]·dropdown·text)·CS-4-2(color)·CS-4-4(세팅 페이지 셸 — Section 네비·폼 스크롤·즉시 write-back)가 머지됐다.
> CS-4-3(keybind recorder)·CS-4-5 bespoke 에디터(palette·env·shell.args)·CS-4-6(HSV picker)도 머지됐다. 후속은 picker 연속 해상도·alpha 등 고급화.
> **CS-4는 시각/상호작용이라** 각 PR을 머지 전 `zig build macos-app`로 실기 확인한다(스키마 PR처럼 헤드리스
> 단위만으로 blind 머지하지 않는다 — [run-macos-app-before-merge] 규율).

## 0. 목표와 범위

- **메타가 곧 UI.** schema 필드 1개 = 세팅 행 1개. 위젯 종류·범위·라벨·섹션이 메타에서 파생되므로, 새 config
  키를 추가하면(스키마 decl 1줄) **세팅 화면에도 자동으로** 뜬다(GUI 코드 추가 0줄).
  뒤집어 말하면 **필드를 되돌리면 행도 되살아난다** — 그래서 제거한 chrome 키(`chrome.theme` 룩·
  `chrome.preset` 큐레이션)가 UI에 다시 나타나지 않는지를 테스트가 가드로 지킨다
  ([Chrome 전략](chrome-strategy.md#chrome-전용-전환-정책)).
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
| `enum` | dropdown(**열리는 팝업 목록**) | 옵션=enum 토큰(`_`↔`-`), 현재값. Enter/클릭으로 목록을 열어 **↑↓로 넘기면 라이브 미리보기(바로 반영)**·Enter 확정·Esc는 열 때 값으로 원복 |
| `f32`/`u32` + `range` | **숫자 입력 박스**(`input_box`) | min/max=range로 커밋 시 clamp, 현재값. Enter/클릭으로 편집 진입해 직접 타이핑(슬라이더/프로그레스바 대체) |
| `[]const u8` (widget=`.text`) | text input | 현재값(IME) |
| `[]const u8` (widget=`.color`) | color input | 현재 #RRGGBB |
| `font.family` (특수) | **번들 폰트 드롭다운 팝업**(`.font` 행) | 옵션=`theme.bundled_font_families` + **"직접 입력…"**. Enter/클릭으로 목록을 열어 선택; "직접 입력…" 고르면 인라인 편집이 열려 임의 설치 폰트 타이핑 |

> **폰트 피커(`font.family`)**: `font.family`는 자유 문자열이지만, 사용자 요청으로 **번들 폰트 목록
> (`theme.bundled_font_families` — 단일 출처) 위의 열리는 드롭다운 팝업**(`.font` 행 종류)으로 emit한다: Enter/클릭이
> 목록을 열고 ↑↓로 골라 Enter로 확정한다(platform이 `openDropdown`→`applyDropdownSelection`으로 `setText`). 현재값이
> 목록 안이면 그 항목에서 선택이 시작되고, 목록 밖(시스템·직접입력 폰트)이면 첫 항목에서 시작한다. 목록 밖 임의 폰트를
> 직접 지정하려면 목록 끝 **"직접 입력…"** 항목을 고른다 — platform이 인라인 편집을 열어 임의 폰트명을 타이핑하게 한다.) 새 번들 폰트는 `theme.bundled_font_families` + [font-strategy.md]
> 갱신만으로 자동 노출(GUI 코드 0줄).

- **섹션**: `Meta.section`(font/theme/cursor/window/input/terminal/workspace/quick_terminal/sidebar/global_hotkey)이 좌측
  네비 그룹이 된다. 같은 section 필드가 한 패널에 모인다. `global_hotkey`는 schema 필드가 없는 특수 섹션이라
  app_session이 강제로 목록에 넣는다(전역 OS 단축키 녹음 행만 — §6.7 keybind 선례).
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

현재 `ChromeHost`는 **키 이벤트만** 라우팅한다([chrome-strategy.md] C1 host). 색 그리드 드래그·토글·드롭다운·입력 박스
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
- **키보드 네비(방향키 영역 모델)**: 좌측 섹션 네비와 우측 폼 두 영역을 **방향으로** 오간다 — **`←`=네비로 포커스, `→`=폼으로 포커스**, 각 영역 안에서 **`↑↓`가 이동**(네비=섹션, 폼=행). Tab 토글(`nav_focused` on/off)이 아니라 방향키로 이동해 직관적(왼쪽 열=네비, 오른쪽=폼). **Enter/Space=폼 행 활성**(bool flip·number 입력 박스 편집·enum/font/theme.preset 드롭다운 팝업 열기·text 편집·color HSV picker·keybind 녹음), 네비에서 Enter=폼 진입, Esc=닫기, Tab=무동작. 활성 영역은 **dim**으로 보인다(네비 포커스면 폼 라벨 muted, 폼 포커스면 비-현재 섹션 muted). 섹션 상한은 platform `refreshSettingsFieldCount`가 clamp(컴포넌트는 섹션 수 모름). **팔레트 그리드 행**(폼 포커스)에선 `←→`가 16색 셀을 이동한다(가로 스트립 — platform이 `settingsPaletteArrowIntercept`로 그 행만 특수 처리; `←` 셀0·`→` 셀15(끝)에선 셀 밖으로 나가 영역 이동으로 이어진다). 슬라이더 ←→ 값조절·색 ←→ 프리셋 순환은 제거(값은 입력 박스·드롭다운·picker). **`←→` adjust 보류**: "숫자·드롭다운도 ←→로 값 조절하면 일관적일까?"는 논의 후 현행(영역 포커스) 유지로 정했고, 옛 값-조절 구현(`adjustSelectedSetting`·`applyThemePreset` dir-순환 + deprecated Action `slider_set`/`adjust_left`/`adjust_right`)은 **삭제하지 않고 dead code로 남겨둔다**(dispatch no-op이라 비활성; ←→ adjust를 재도입하면 재활용). 현행을 영구 확정하면 함께 제거. 드롭다운 팝업이 열려 있으면 모든 키를 팝업이 잡는다 — **↑↓로 넘길 때마다 highlighted 변형을 라이브 적용**(바로 반영, 팝업 유지), **Enter=확정**(그 값 유지 + 닫기), **Esc/바깥 클릭=취소**(열 때 값으로 원복 + 닫기), ←→/잡키는 무시. 파일 쓰기는 Swift가 tick에서 coalesce하므로 ↑↓ 연타여도 write 폭주가 없다. **취소 복원은 값 종류마다 다르다**: enum은 `dropdown.State.original`(인덱스)로 되돌리지만, **목록 밖 커스텀 폰트·"사용자 지정" 커스텀 테마는 인덱스로 표현 못 하므로 platform이 열 때 원본을 통째로 스냅샷**(`dropdown_snapshot_*`)해 취소 시 그 스냅샷으로 복원한다(인덱스 복원이 커스텀 값을 첫 항목/프리셋으로 덮어써 잃던 데이터 손실 수정 — code-review high). 번들 폰트는 정적 문자열이라 프리뷰 적용 시 arena dupe 없이 그대로 set(키당 누수 방지).
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
| `theme.syntax.<역할>` | **라벨 있는 색 행 열하나**(color input 재사용). 그리드 한 행이 아닌 이유는 **검색**이다 — 그리드면 `keyword` 를 검색해도 안 걸린다(팔레트는 0~15 라 번호로 찾지만 역할은 이름으로 찾는다). **프리셋 활성이면 잠근다**(팔레트·주 색과 같은 규율 — 구문 색은 팔레트에서 파생하므로 프리셋이 정하는 것과 같다. 행을 편집하면 "사용자 지정" 으로 자동 전환된다). **되돌리기는 줄을 지운다**(`removeConfigLines`) — 슬롯만 비우면 파일에 남아 다음 로드에 되살아난다 |
| `window.padding-x/y` | (alias라 GUI는 4방 개별만 노출, x/y는 숨김) |

## 6. 재사용 가능한 chrome 패턴 vs 신규

조사 결과(기존 `src/chrome/components/`):

| 위젯 | 재사용 | 신규 |
|---|---|---|
| 텍스트 입력 + caret | `overlay_input`(Find/팔레트) | — |
| 토글 | `context_menu` 체크박스(✓) | State+Action 얇게 |
| 드롭다운/리스트 | `dropdown`(축소 표시 + **열리는 팝업 목록**, `context_menu` 오버레이 규율) | enum/font 변형 선택 |
| hit-test/드래그 | `divider`/`sidebar`/`tabbar` `hitTest`·`dragRatio` | pointer 이벤트(§3) |
| GPU quad/rounded/shadow | `ChromeDraw.quad` + 토큰 | — |
| 입력 라우팅 | `ChromeHost`(모달 우선순위) | pointer + 위젯 State |
| **숫자 입력 박스**(`input_box`) | 테두리 박스 + 값/편집버퍼 + caret | Enter/클릭 편집 → 파싱+clamp+setNumber (슬라이더 대체) |
| **color input** | quad + 토큰 | 1차 ✅ 16색 프리셋 + hex 입력(text 재사용); 2차 ✅ HSV picker(§6.9) |
| **keybind recorder** | `input.InputEvent` 그대로 | 녹음 State(키 캡처) |

> 핵심 리스크 2개: **color picker**(2차 HSV는 색공간 수학·2D 그리드 — 1차는 16색+hex로 우회) + **pointer
> 이벤트가 host에 아직 없음**(§3 CS-4-0이 선결). 나머지는 기존 패턴 변형이라 낮음.

### 6.1 위젯 렌더 — tui(셀 정렬 text) vs rich(GPU quad)

위젯 view는 `tokens.space.corner_radius_px`로 두 룩을 분기한다(테마는 위젯 불변, [chrome-strategy.md] §5.4):

- **rich(>0)**: GPU `ChromeDraw.quad`(SDF) — 둥근 pill·원형 knob·얇은 트랙·그림자 등 sub-pixel.
- **tui(0)**: **셀 정렬 text**(`Op.text`). 토글 `[█ ]`/`[ █]`(knob=`█`, 켜짐=accent_bar 우/꺼짐=surface_fg 좌), **숫자 입력 박스=값 text만**(border 0이라 테두리 quad 생략), dropdown 축소=`값 ▾`. control 열 좌단 정렬.

  **드롭다운 팝업의 불투명 렌더(중요)**: 팝업은 설정 폼과 **같은 modal 레이어**의 셀 그리드라, `context_menu`(다른 레이어=터미널 위)처럼 그냥 quad로 덮으면 안 된다 — 모달 셀 lowering은 `.fill`이 셀 **배경만** 칠하고 **글리프는 안 지우며**, rich는 배경이 `surface_bg`인 셀을 투명화한다. 그래서 뒤 폼 텍스트가 팝업 뒤로 비친다. 해결: 팝업 각 행을 (1) `surface_bg`가 **아닌** 배경(`tab_hover_bg`/선택=`tab_active_bg`)으로 칠해 투명화 pass를 피하고, (2) 항목 텍스트를 **박스 폭까지 공백 패딩**해 그 행 모든 셀에 글리프를 놓아 뒤 폼 글리프를 덮는다(`dropdown.viewPopup`).

  **결정 근거**: tui lowering은 quad를 `paintRectBg`로 **셀 단위** 배경에 칠한다. 위젯을 quad로 두면 (1) 얇은 트랙(높이 h/4)이 `@divTrunc`로 r0==r1이 돼 사라지고, (2) 행 높이 채움이 셀 경계에서 위아래로 번지며, (3) 선택 하이라이트(셀 bg)와 같은 레이어라 서로 덮어 거칠게 겹쳤다(겹침·가림 회귀). text는 placeText가 셀 정렬로 놓고 **text 레이어**(셀 bg 위)라 선택 하이라이트 위에 또렷하다(dropdown·palette 행과 동형). `█`(U+2588)는 합성 글리프라 폰트 무관 렌더. 위젯 view에 `cw`(셀 폭)를 넘겨 tui text 칸/오프셋을 계산한다.

### 6.2 text 위젯(인라인 편집) + color 위젯(스와치 + 16색 프리셋)

**text(widget `.text` = 폰트 패밀리)**: 인라인 편집. 행을 클릭/Enter하면 편집 모드(현재값 시드) — 글자/Backspace로 고치고 Enter 커밋, Esc 취소. 편집 버퍼는 컴포넌트 State의 **고정 버퍼**(`edit_buf[128]`)라 별도 allocator가 없다. 커밋 시 platform이 `editText()`를 **config arena에 dupe**해 `schema.setText`로 적용(라이브 재resolve + write-back, 검증 포함) — 라이브/직렬화가 슬라이스를 계속 읽으므로 config arena가 소유한다.

**color(widget `.color` = `#RRGGBB`)**: **스와치 + hex**(`components/color.zig`). 스와치는 `Op.swatch`(literal RGB)로 실제 색을 보여준다 — 다른 op은 색을 `ColorRole`(테마 토큰)로 두지만 스와치는 "이 색이 무엇인지"를 보여주는 **값 미리보기**라 의도적 예외로 원색을 싣는다(**raw-RGB draw 프리미티브** — role 추상화의 명시적 확장, CS-4-2 결정). platform이 `parseHexColor`로 RGB를 만들어 주입한다(chrome은 config 무지 유지). **스와치 렌더는 `Swatch.corner_radii`로 분기**(C4b `Op.quad` 동형) — 컴포넌트가 `props.shape.corner_radius_px`(스와치 높이의 절반으로 cap)를 실어, lowering이 0이면 셀 bg(tui 직각), >0이면 **둥근 GPU quad 칩**(rich, layer 3 — 셀·선택 하이라이트 위, literal RGB)으로 그린다. 인터랙션 세 zone:
- **스와치 클릭 / Enter** → **HSV picker 열기**(현재 색으로 시드 — §6.9). 임의 색을 그리드로 고른다(2차 색 선택, CS-4-6).
- **hex 클릭** → 인라인 편집(text 위젯 재사용 — `editText`→`setText`, hex 검증).
- (예전 `←→` 16색 프리셋 순환은 제거 — `←→`는 방향키 영역 포커스 이동(←=네비·→=폼, §4)에 쓰이지 색을 조절하지 않는다. 색은 HSV picker·hex로 고른다.)

- **미구현(후속)**: 옵셔널 색(`?[]const u8` sidebar 파생색), IME 조합 편집, 값 길이에 따른 박스 폭 확장, picker의 연속(non-discrete) 해상도·alpha. (color 스와치 rich 둥근 quad 렌더는 구현됨 — 위 참조.)

### 6.3 테마 프리셋(named 테마) — 특수 행

테마 섹션 **최상단** dropdown **"테마 프리셋"** — `maru`·`ghostty`·`gruvbox-dark`·`solarized-dark`·`solarized-light`·`dracula`·`catppuccin-mocha`·`catppuccin-latte`·`light-pink`·`dark-pink`·`rose-pine`·`rose-pine-dawn`·`tokyo-night`·`nord`·`one-dark`·`one-light` 16종 + **"사용자 지정"**을 **열리는 드롭다운 팝업**에서 고른다(Enter/클릭으로 열고 ↑↓로 넘기면 테마가 **라이브 미리보기**로 바로 바뀜, Enter 확정·Esc 원복). 프리셋은 색 세트를 통째로 깔고, "사용자 지정"은 열 때 스냅샷한 **원본 커스텀 색을 복원**하며 잠금만 푼다(미리보기로 프리셋을 봤어도 원본 커스텀으로 되돌린다). `theme.preset`은 synthetic(스키마 enum 아님)이라 일반 enum 드롭다운과 달리 platform이 변형 목록·적용을 특수 배선한다(`themePresetVariants`·`applyThemePresetIndex`). `theme.preset`은 **schema 필드가 아니라 특수 지시어**(loader가 색 세트를 통째로 까는 명령, 저장 필드 없음)라 자동 노출되지 않으므로:

- **표시값은 색에서 derive**: `detectThemePreset`이 config.theme의 주 색 4개(bg/fg/cursor/selection)를 16종 `presetColors`와 매칭 → 일치하면 그 이름, 없으면 "사용자 지정". 저장 안 해도 현재 프리셋을 안다.
- **주입·배치**: platform이 theme 섹션 `currentSectionFields.enums`에 **synthetic `EnumField`**(`key="theme.preset"`)를 **맨 앞에 `insert`**한다 → 색·팔레트보다 위(테마 섹션 최상단)에 도드라지게, 기존 dropdown/enum 경로 재사용(새 Kind·index 수술 없음).
- **적용**: 드롭다운 팝업의 ↑↓/확정이 `key=="theme.preset"`을 특수 처리 → `applyThemePresetIndex(idx, persist)`가 `config.theme = presetColors(idx)`(정적 리터럴) + 라이브 재resolve, `persist=true`(확정)일 때만 `persistThemePreset`으로 파일 영속. **idx=="사용자 지정" 슬롯이면 열 때 스냅샷한 원본 커스텀 색을 복원** + 잠금 해제(예전엔 잠금만 풀어 미리본 프리셋 색이 커스텀으로 굳던 데이터 손실 — code-review high). **↑↓ 프리뷰는 `persist=false`(인메모리만)**, 확정만 `persist=true` — 미리보기가 영속하면 취소해도 파일에 미리본 프리셋이 써져 커스텀이 사라졌기에 영속은 확정에서만 한다. 취소는 스냅샷(`dropdown_snapshot_*`)으로 인메모리 복원(파일은 미리보기가 안 건드려 원본 그대로). (옛 `applyThemePreset(dir)` 순환은 남겨두되 드롭다운이 대체.)
- **프리셋 활성 시 색 잠금(옵션 A)**: `themePresetActive`(=색이 프리셋과 일치 ∧ `theme_user_custom`=false)면 색·팔레트 행을 `FieldRow.disabled`로 회색·잠금 표시한다(프리셋이 색을 정하므로 직접 편집은 혼란). 비활성 색을 **클릭하면**(swatch/hex 무관) 핸들러가 `theme_user_custom=true`로 "사용자 지정" 전환 후 바로 편집(picker/인라인)을 연다. `theme_user_custom`은 런타임 휘발(색은 derive하므로 영속 불요); 프리셋 재선택·reload·reset 시 false로 돌아간다(색이 프리셋과 같으면 자동으로 다시 잠금).
- **영속(해결)**: 프리셋을 고르면 `persistThemePreset`이 **`theme.preset = <name>` 한 줄**을 쓰고(serializeConfig 전용 패스 — configKeyValues는 round-trip 대칭 유지 위해 derive 키를 안 emit), 충돌할 개별 `theme.*` 색·`theme.palette.N` override 줄은 제거한다. 로더가 `theme.preset`을 통째 프리셋 색(**16색 팔레트 포함**)으로 펼치므로 reload·재시작 후에도 **팔레트까지 그대로** 복원된다(search/sidebar 색은 그 테마에서 derive돼 자동). 옛 "주 색 4개만 영속" 한계 해소(팔레트 영속 리뷰). (옛 "후속: 팝업 그리드"는 열리는 드롭다운 팝업으로 해소됨 — 위 참조.)

### 6.4 통합 리셋(Reset All Settings to Defaults)

커맨드 팝업(Cmd+Shift+P) **"Reset All Settings to Defaults"**(action `reset_settings`)와 메뉴 **"Reset to Defaults"**(ABI `reset_defaults`)는 **같은 동작**이다. 둘 다 `requestResetAll` 확인 뒤 config를 내장 기본값으로 되돌린다. `session.keep-alive-after-quit`은 PTY 소유권 예외다. app-global G2 snapshot이 `absent`이면 줄을 만들지 않고, explicit valid/invalid이면 Reset 직전 live bool을 기본값과 같아도 canonical explicit override로 보존한다. 다른 설정을 지운 body와 이 override는 한 번의 atomic replace로 게시하며 write 실패는 기존 파일과 live snapshot을 보존한다. 별도 persisted migration marker나 만료 정책은 두지 않고, 사용자가 Workspace 토글을 직접 바꿀 때만 explicit true/false를 교체한다. schema 키만 부분 초기화하면 비-schema 키(`theme.preset`·`palette.N`·`env.*`·`cursor.color`·`shell.args`)가 남으므로 나머지는 전체 덮어쓰기를 유지한다. `config_dirty_keys`를 비워 Swift 부분 write-back이 끼지 않게 하고, 이후 변경은 `serializeConfig`가 채운다. 파일 덮어쓰기는 파괴적이므로 메뉴·팝업 모두 확인 모달을 사용한다.

**세팅 모달 안 진입점(네비 맨 아래 "↺ 모든 설정 초기화")**: 리셋 로직·확인 모달은 위와 동일하되, 진입점이 커맨드 팝업·메뉴에만 있어 세팅 화면(⌘,)을 보면서는 못 찾던 발견성 문제를 해소한다(사용자 제보 "복구가 어렵다"). 좌측 Section 네비 **맨 아래**에 실제 섹션과 구분해(위 간격 + 구별색) 상시 노출하고, 클릭/Enter로 `requestResetAll`(같은 확인 모달)을 연다. 이 행은 **섹션이 아니라 액션**이므로 `buildSectionList`/`currentSectionFields`(폼 섹션 매핑)에는 넣지 않고 `buildSettingsSectionLabels`(네비 표시 라벨)에만 더한다 — 둘을 분리해, 리셋 행을 골라도 폼은 마지막 섹션을 흐리게 유지하고 활성은 네비에 있다. 컴포넌트는 config를 모르므로 platform이 `State.nav_reset_row`(리셋 행 인덱스)를 주입하고, `handle`이 네비 포커스 Enter가 그 행이면 `.reset_all` Action을 낸다(포인터 hit도 동일). 확인 모달과 세팅 모달은 둘 다 중앙 모달이라 단일-오버레이 불변식상 세팅이 닫히며 확인이 뜬다(전체 리셋은 파괴적이라 수용 — 취소해도 세팅은 닫힘).

### 6.5 ANSI 16색 팔레트 그리드(`theme.palette.0~15`) — 특수 행 (CS-4-5 첫 조각)

테마 섹션 맨 아래 **"ANSI 팔레트"** 행 — 16색을 한 줄 스와치 그리드로 편집한다. `theme.palette.N`은 **schema 필드가 아니라 특수 키**(loader가 인덱스 파싱, `[16]?[]const u8`)라 자동 노출되지 않으므로 platform이 color 뒤에 **한 행**을 합성 주입한다(`SettingsSectionFields.has_palette` — theme 섹션일 때만). 16칸이라 공유 control 열에 안 들어가므로 폼 우측에 그리드 블록(`palette_grid` Kind)을 펼친다(control 열 비공유, [§6.1] tui 규율은 그대로 — 색은 `Op.swatch` 원색).

- **셀 색**: `cells[i].rgb` = config override(`theme.palette[i]`) 있으면 그 hex, 없으면 **표준 xterm256(i)**(ANSI 0~15 기본). 그래서 미override 칸도 실제 기본색을 보여준다. hex 시드도 같은 규칙(override는 그대로, 기본은 RGB→`#rrggbb`).
- **선택·편집**: 폼 포커스로 이 행에 있을 때 `←→`로 16색 셀을 이동(`State.grid_cell`), `Enter`/스와치 클릭으로 선택, 선택 셀의 hex를 인라인 편집(text/color 위젯과 같은 고정 버퍼·Enter 커밋·Esc 취소). 커밋은 `schema.setPaletteColor`(파일 로드와 같은 `#RRGGBB` 검증)로 적용 + `theme.palette.N` 키 dirty. **←→ 셀 이동은 platform이 pre-intercept**한다(`settingsPaletteArrowIntercept` — 방향키 영역 모델에서 ←→는 기본이 영역 포커스 이동이라, 이 가로-스트립 행에서만 셀 이동으로 가로챈다). `←` 셀0·`→` 셀15(끝)에선 가로채지 않아 셀 밖으로 나가는 방향키가 영역 이동으로 살아난다(마우스 클릭은 그대로 셀 선택). **검색 중에도 팔레트 ←→는 동작한다** — `currentSectionFields`가 검색 필터를 적용해 `paletteRowIndex`와 `selected`가 같은 필터-인덱스라 정합하고, 검색의 ←→는 원래 소비만 되던 미사용 키다(↑↓·글자는 그대로 검색 나비·쿼리 편집).
- **선택 표식 = 인덱스 텍스트**: 우측에 **`N  #rrggbb`**(선택 ANSI 인덱스 + hex)를 보여준다. 셀 위에 `Op.border`/`fill`을 얹으면 tui lowering(`paintRectBg`가 셀 단위)이 **1행 높이라 셀 전체를 그 색으로 칠해 스와치 색을 덮으므로** 안 쓴다. 인덱스는 색과 무관하게 어느 칸인지 분명히 보여준다.
- **영속은 공짜**: write-back(`serialize.configKeyValues`)이 **이미 set된 `theme.palette.N`을 직렬화**한다(round-trip 테스트가 보장). 그래서 별도 write-경로 확장 없이 dirty만 찍으면 파일에 써진다 — `theme.preset`이 깐 팔레트도 이 그리드로 직접 칠하면 영속된다([§6.3] 한계의 직접 해소 경로).
- **온-그리드 선택 마커**: 선택 스와치 위에 `▾` 글리프(accent text 레이어)를 얹어 어느 칸인지 보여준다 — `Op.border`/`fill`은 tui lowering(`paintRectBg` 셀 단위)이 셀 전체를 칠해 스와치 색을 덮으므로, 글리프(셀 bg=스와치 색은 거의 안 가림)로. 우측 `N  #hex` 인덱스 텍스트와 함께.
- **셀별 기본값 되돌리기(§6.11)**: 선택 셀이 override(config에 `theme.palette.N` 있음)면 그 palette 행 **맨 오른쪽 칸**(§6.11 다른 행과 같은 자리)에 ↺ 어포던스가 뜬다 — 클릭/Backspace로 `theme.palette[N]=null` + `markConfigKeyRemoved(paletteKey(N))`(override 줄 제거)로 표준 xterm256 기본색으로 되돌린다(옛 "null로 되돌리기(통합 리셋이 담당)" 한계 해소).
- **한계(후속)**: 셀별 프리셋 순환(현재는 hex 입력만).

### 6.6 셸 인자(`shell.args`) + 환경 변수(`env.<KEY>`) — 특수 행 (CS-4-5)

터미널 섹션에 두 특수 키(schema 필드 아님, loader가 명시 핸들러)를 **`.text` 위젯 재사용**으로 합성 주입한다(palette처럼 새 Kind를 안 만든다 — 둘 다 한 줄짜리 문자열 편집이라 text로 충분). platform이 `currentSectionFields`의 terminal 분기에서 행을 더하고, `commitSelectedText`가 **키로 라우팅**한다(`theme.preset`·palette 선례).

- **`shell.args`**: `셸 인자 (공백 구분)` 행 — 값 = 현재 argv를 공백으로 join(`"-i -l"`). 편집 커밋 시 `setShellArgs`가 공백으로 토큰 분리해(`tokenizeAny`, loader와 같은 규칙 — 따옴표 미지원) `config.shell.args`에 적용 + `markConfigKeyDirty("shell.args")`. write-back은 `serialize.configKeyValues`가 join해 한 줄로 쓴다.
- **`env.<KEY>`**: 각 환경 변수가 한 행(라벨=KEY, 값=VALUE 인라인 편집). 커밋 시 `setEnvVar(name, value)`가 `config.env`(`"KEY=VALUE"` 리스트)에서 그 KEY를 **upsert**(있으면 교체, 없으면 추가) + `markConfigKeyDirty("env.KEY")`. dirty 키는 동적이라 세션 arena에 둬 안정 포인터로 보관(serialize drain까지 유효 — palette의 정적 키와 다른 점).
- **추가 행**: 목록 끝 `환경 변수 추가 (KEY=VALUE)` 행(빈 `env.` sentinel 키). 편집 커밋 시 `addEnvVar`가 `KEY=VALUE`를 파싱해 `setEnvVar`로 upsert(첫 `=` 기준, KEY는 양끝 trim; `=` 없거나 빈 KEY면 notice).
- **삭제(Backspace)**: `env.<KEY>` 행에서 `Backspace`(편집 아님)를 누르면 그 변수를 삭제한다 — `removeEnvVar`가 `config.env`에서 빼고 `config_removed_keys`에 `env.<KEY>`를 예약, `serializeConfig`가 **`removeConfigLines`로 파일에서 그 줄을 제거**한다(`updateConfigText`는 줄 삭제를 안 하므로 전용 제거 패스 — keybind write-back처럼 갱신 패스 뒤에 체이닝). 추가 sentinel 행·`shell.args`·schema text 행에선 무동작.
- **라이브 적용 없음**: env·shell.args는 **셸 spawn 시점에만** 쓰이므로 `reapplyLoadedConfig`를 안 부른다(이미 뜬 셸엔 영향 없고, 다음 새 Term부터 반영 — 정확한 동작). appearance/렌더 무변경이라 metal_dirty도 불필요.
- **영속은 공짜**: write-back이 `shell.args`·set된 `env.<KEY>`를 이미 직렬화(serialize.zig, round-trip 테스트 보장)하므로 별도 write-경로 확장 없이 dirty만 찍으면 파일에 써진다.
- **한계(후속)**: env **KEY 변경**(기존 KEY를 다른 이름으로)은 삭제+추가로 해야 한다(인라인 KEY 편집은 후속). shell.args 토큰 따옴표(공백 포함 인자)도 후속.

### 6.6a 시작 디렉터리(`workspace.root`) — 특수 행

**Workspace 섹션**에 시작 디렉터리(첫 창·새 탭이 열리는 경로)를 한 줄짜리 text 행으로 노출한다. `workspace.root`도 schema 필드가 아니라 loader 명시 핸들러(경로 형식 검증) 특수 키라, `shell.args`/`env`와 같이 `.text` 위젯을 재사용해 합성 주입한다 — platform이 `currentSectionFields`의 workspace 분기에서 행을 더하고(값=현재 `config.workspace.root`), `commitSelectedText`가 키로 라우팅해 `setWorkspaceRoot`로 커밋한다.

- **검증은 loader와 공유**: 형식 규칙(절대경로 또는 `~`/`~/…`, 상대경로·`~user` 거부)을 `loader.isValidWorkspaceRoot` **단일 헬퍼**로 뽑아 loader 파싱과 GUI 커밋이 같이 쓴다 — GUI·파일 드리프트 방지(§1). `~` 확장·존재 검증은 형식이 아니라 env/FS라 **spawn 시점**(`resolveWorkspaceRoot`)이 하고, 여기선 형식만 본다.
- **빈 값 = 상속 cwd**: 값을 비우면(클리어) `workspace.root=""`로 되돌려 "maru를 띄운 cwd 상속"(기본) 동작이 된다. 비-빈 값이 형식에 안 맞으면 저장하지 않고 notice로 안내한다.
- **영속·라이브**: write-back은 `serialize.configKeyValues`가 이미 `workspace.root`를 emit하므로 `markConfigKeyDirty("workspace.root")`만 찍으면 파일에 써진다. `root`는 셸 spawn 시점에만 쓰이므로 라이브 재적용(reapplyLoadedConfig)은 다음 새 Term부터 반영된다(env·shell.args와 같은 결).

### 6.7 keybind recorder(단축키 재바인딩) — 특수 행 (CS-4-3)

입력 섹션에 `command_catalog`의 모든 액션을 한 행씩(라벨=title, 우측=현재 단축키 표시 또는 "(미지정)") 주입한다(`has_keybinds`). 행을 Enter/클릭하면 **녹음 모드**(`State.recording`)로 들어가 "키 입력 대기..."를 보이고, 다음 키 한 번을 그 액션의 새 단축키로 묶는다. keybind는 `keybind = <chord> = <action>` 줄이라 다른 특수 키와 또 다른 영속 패스가 필요하다.

- **전체 키 캡처**: 녹음 중엔 platform이 chrome 변환 **전에** raw `terminal.KeyEvent`를 가로챈다(`handleKeyEvent`). `chromeInputFromKeyEvent`가 키를 축약 enum(`enter`/`char`/`other`…)으로 줄여 Tab·Home·F-키를 잃으므로, 전체 키 정보가 있는 raw 이벤트를 `KeyChord.fromKeyEvent`로 chord화한다. 평범한 `Esc`(모디파이어 없음)는 녹음 취소(흔한 recorder 관례).
- **즉시 반영**: `rebindActionEntry`가 `loaded_config.keybindings`를 새 슬라이스로 교체(그 액션을 새 chord로, 없으면 추가)하고 `rebuildCommandCatalog`로 메뉴바·팝업 표시도 갱신한다. resolver가 매 키 이벤트마다 이 슬라이스를 읽으므로 재시작 없이 바로 동작한다.
- **영속(전용 write-back)**: keybind는 `key = value`가 아니라 줄마다 같은 `keybind` 키 + 두 번째 `=`로 chord/action을 나눠서 `updateConfigText`(key 기준)로는 못 다룬다(모든 keybind 줄이 한 키로 충돌). 그래서 `updateKeybindLines`(loader)가 **action 기준**으로 `keybind = <chord> = <action>` 줄을 찾아 교체(없으면 append)한다. chord는 `KeyChord.toConfigString`(parse와 round-trip되는 ASCII 표기 — 표시용 `formatChord`의 ⌘⇧ 기호와 다름). `serializeConfig`가 schema write-back 뒤에 이 패스를 **체이닝**하고, `takeConfigDirty`가 keybind 재바인딩도 본다. 매크로 줄(`text:`/`esc:` rhs에 `=` 포함)은 action 키와 안 겹쳐 자연히 보존된다.
- **해제(unbind)**: keybind 행에서 `Backspace`(녹음 아님)를 누르면 그 액션의 **사용자 지정** 단축키를 해제한다 — `unbindActionEntry`가 `loaded_config.keybindings`에서 그 액션을 빼고 카탈로그를 재빌드, `keybind = * = action` 줄을 **`removeKeybindLines`(action 기준 제거)**로 빼며(serializeConfig 체이닝), 펜딩 rebind도 취소한다. 해제 후 resolver는 빌트인(있으면)을 반환하거나 미지정 — 행 표시가 그에 맞게 갱신. 사용자 바인딩이 없으면 notice(빌트인은 안 건드림).
- **빌트인까지 완전 해제 + 재바인딩 완전 교체**: unbind/rebind는 공통 헬퍼 `unbindBuiltinChords(entry, except)`로 그 액션의 **빌트인 chord(들)**(`default_app_bindings`)를 `loaded_config.unbinds`에 넣고(라이브) `keybind = <chord> = unbind` 지시어로 영속해 죽인다. **unbind(완전 해제)는 `except=null`로 전부** 죽이고(해제 후 `chordForAction`=null → "(미지정)"), **rebind(완전 교체)는 `except=새 chord`로 새 chord만 살리고 나머지 빌트인을 죽인다** — 안 그러면 빌트인이 살아 옛 키 + 새 키 둘 다 발동(추가)이라 "표시=동작"·옛 키 되찾기가 안 된다. **한 액션에 빌트인 chord가 여럿이면(next_tab·previous_tab·increase/decrease_font_size는 2개) 전부** 처리(하나만 죽이면 `chordForAction`이 남은 chord를 반환해 실패 — 리뷰 #840). resolver는 사용자 바인딩을 unbinds보다 **먼저** 보므로(`keybinding.resolve` 우선순위) 새 chord가 빌트인과 같아도 `except`로 안 죽이면 그 키가 산다(중복 unbind 줄도 안 남김).
- **충돌 경고**: rebind 시 그 chord가 다른 액션의 effective chord와 같으면 알린다(rebind는 진행 — 사용자 의도, last-wins). 다만 다중-chord 빌트인의 2번째 변형·terminal 매크로 바인딩과의 충돌은 못 잡는다(best-effort — 후속).
- **검증 메시지는 인라인 배너(세팅을 안 닫는다)**: 녹음 검증 결과(전역 등록 불가 키 거부·충돌 경고·"이미 미지정") 메시지는 `showNotice`(토스트)가 아니라 **`settingsMessageOrNotice`**로 낸다 — 세팅 모달이 열려 있으면 `State.setMessage`로 **폼 상단(힌트 줄 자리)에 `⚠ <메시지>` 배너**를 얹고(세팅 자체 draw 그리드 안 텍스트라 레이아웃·단일-오버레이 불변식 무관), 세팅 밖(메뉴 rebind 등)에서 온 같은 메시지는 기존대로 토스트다. `showNotice`는 `dismissMessageOverlays`로 **세팅 모달까지 닫으므로**(confirm/notice와 settings가 한 오버레이 그리드에 겹쳐 그려지는 것을 막는 단일-오버레이 불변식), 녹음 중 그 경로를 타면 사용자가 녹음하던 세팅 화면이 통째로 사라졌다(사용자 제보 "등록 불가/실패라며 설정창이 꺼짐"). 배너는 다음 녹음 시도(`captureKeybindRecording` 진입)·섹션 전환·모달 닫기에서 정리한다(`clearMessage`). 긴 메시지는 `truncateToCols`로 박스 안에 가둔다. **중복 모달(notice를 세팅 위에 스택)** 대신 이 배너를 택한 이유: 오버레이 파이프라인이 열린 컴포넌트 draw를 하나의 union-bbox 셀 그리드로 합쳐 painter-order로 raster하므로(둘 다 중앙 모달이면 겹침), 진짜 스택은 paint 순서·입력 라우팅·hit-test의 "단일 모달" 전제를 여러 곳에서 풀어야 하는 큰 변경이다(사용자와 상의해 배너로 결정).
- **stale unbind 정리**: 어떤 chord를 다시 사용자 바인딩으로 묶으면(rebind), 옛 `keybind = <chord> = unbind` 줄이 모순되게 남는 걸 정리한다 — `clearStaleUnbind`가 ① 라이브 `unbinds`에서 제거 ② 이번 세션 펜딩 unbind-append 취소 ③ 파일의 옛 줄 제거 예약(`removeKeybindUnbindLines`, chord 기준). resolver는 사용자 바인딩을 unbinds보다 먼저 봐서 동작은 정상이었지만 파일 위생을 맞춘다.
- **terminal 매크로 GUI 편집(해결)**: 입력 섹션에 사용자 터미널 매크로(`keybind = <chord> = text:`/`esc:`/`ctrl:`)를 **rhs 편집 text 행**으로 노출한다(env 특수 행 선례). 라벨=chord 표시(`formatChord`), 값=rhs config 문자열(`macroRhsString` 역직렬화 — esc는 앞 ESC 제거, ctrl은 codepoint→UTF-8). 행 키 `macro.<chord config>`(`toConfigString`)로 커밋/삭제 시 chord를 식별한다. **편집**: 값을 고쳐 Enter → `setTerminalMacro`가 `parseMacroRhs`로 검증하고 `loaded_config.terminal_bindings`를 라이브 교체(resolver 즉시 반영) + write-back 예약. **추가**: 맨 끝 `터미널 매크로 추가 (chord = text:...)` 행에 `chord = rhs`를 입력(첫 `=`로 분리, chord 정규화). **삭제**: Backspace → `removeTerminalMacro`(삭제 후 `refreshSettingsFieldCount`). **추가도 `refreshSettingsFieldCount`** 후속 호출(행 늘어 연속 추가가 키보드로 도달). **충돌**: 사용자 바인딩 충돌(app↔terminal·중복 terminal)은 `KeyBindingResolver.validate`로 **막고** `showNotice`. 단 validate는 사용자 바인딩만 보므로(빌트인은 `default_*`라 resolve 내부에만), **빌트인 chord 덮어쓰기**(예 `Cmd+T`)는 `chordShadowsBuiltin`로 따로 감지해 **차단이 아니라 경고**(오버라이드는 사용자 의도, last-wins — rebind 경고와 동일). 빌트인을 매크로로 묶을 때 `clearStaleUnbind`로 그 chord의 옛 `unbind` 지시어를 정리해, 나중에 매크로를 지워도 빌트인이 살아난다. 영속은 **chord 기준** 전용 패스(`updateTerminalMacroLines`/`removeTerminalMacroLines` — action 기준 `updateKeybindLines`의 짝, rhs가 매크로인 줄만 건드려 app action 줄 보존). chord 매칭은 raw 문자열이 아니라 **`KeyChord.eql`**(파싱 후 비교)이라 손으로 쓴 비정규 표기(`ctrl+g`·수식키 순서)도 교체·삭제된다(중복 줄·미삭제 방지). 같은 chord 반복 편집·추가↔삭제는 `cancelPendingMacro`로 dedup·cross-cancel.
- **한계(후속)**: F13+ 키(F1~F12만 키 이벤트로 들어옴, ABI/Swift 매핑 신규 — 니치). (terminal 매크로 GUI 편집·rebind 완전 교체·다중-chord·**global 바인딩 편집**·stale unbind는 해결.)

### 6.8 폼 검색(섹션 내 + 교차 섹션 필터) (CS-4-4 후속)

섹션 폼이 커져서(입력 섹션은 keybind 행만 ~40개) 행을 빠르게 좁히는 검색을 둔다. `§4`에서 후속으로 미뤘던 항목.

- **시작·종료**: 폼에서 `/`를 누르면 검색 모드(제목이 `검색: <쿼리>▏`로, accent + caret), 타이핑이 쿼리가 되고 `Esc`로 종료(필터 해제, 전체 행 복귀). 검색 중에도 `↑↓` 나비·`Enter` 활성은 그대로(필터된 행 위에서). 섹션을 바꾸면 검색이 초기화된다(필터는 섹션 내).
- **macOS IME 라우팅(입력 경로)**: macOS는 평범한 글자 입력을 `NSTextInputClient`(IME) **확정 텍스트**로 처리해 `handleKeyEvent`(컴포넌트 `handle`)를 우회한다. 그래서 세팅 모달이 열려 있을 때 그 확정 텍스트가 검색줄로 가려면 `inputFocus()`가 세팅을 **입력 대상**으로 알아야 한다(`.settings` — find/palette와 같은 대열). 이게 없으면 확정 텍스트가 `.terminal`로 라우팅돼 검색어가 **뒤의 터미널로 새서 검색이 안 됐다**(find/palette는 되던 것과 달리 settings만 누락돼 있던 버그). `routeCommittedText`가 `.settings`를 비-터미널로 보고 `sendTextAsKeys`로 replay하면 `settings.handle(.char)`가 `appendSearchCp`로 쌓는다(`/` 시작·검색 char 모두 이 경로). IME **조합(preedit)**은 `imeSetPreedit`→`State.setSearchPreedit`(고정 버퍼)로 검색줄 `검색: <쿼리>` 뒤에 accent로 보이고, caret은 query 끝(=조합 시작)에 둬 조합 글자를 덮는다(find의 `OverlayInput.preedit`와 같은 모델이되 세팅은 고정 버퍼). 포커스 상실 등 `commitComposition`은 `commitSearchPreedit`로 조합을 query에 확정한다. IME 후보창 위치는 `searchCaretRect`(sections/rows/props로 modal box 계산)를 platform이 `buildChromeOverlayPrep`에서 캐시(`settings_search_caret`)해 `imeCursorRect`가 쓴다.
- **필터는 단일 출처**: `currentSectionFields`가 `settingsRowMatches(label, key, query)`(쿼리 부분일치 — ASCII 대소문자 무시, 한글은 그대로)를 **모든 행 종류**(schema bool/num/enum/text/color + synthetic theme.preset/shell.args/env + palette + keybind)에 같은 규칙으로 적용한다. 그래서 필터 후에도 view(행 목록)와 핸들러(selected 인덱스 매핑)가 **일관**된다 — 핸들러가 `selected`로 라우팅할 때 필터된 같은 집합을 본다.
- **keybind 필터의 인덱스 정합**: keybind 행은 검색으로 부분집합이 되므로 `SettingsSectionFields`가 `has_keybinds`(bool) 대신 **`keybind_entries`(필터된 목록)**를 들고, `total`/`keybindRowStart`/`buildSettingsFields`/`captureKeybindRecording`가 모두 이 목록을 쓴다. 그래서 "split"로 필터한 뒤 첫 행을 녹음하면 **필터된 첫 액션**(Split Right)이 정확히 rebind된다(단위 테스트가 못박음).
- **흐름**: 컴포넌트가 `search_changed` Action을 내면 platform이 `refreshSettingsFieldCount`로 필터된 행 수를 다시 주입(`setFieldCount`가 `selected`를 clamp)하고 재렌더.
- **교차 섹션 검색**: 쿼리가 있으면(`cross = q.len>0`) 섹션 게이트(`x.section==sel_sec`)를 무시해 **전 섹션**의 매칭 행을 보여준다(설정이 어느 섹션인지 몰라도 찾는다). 빈 쿼리면 현재 섹션만. 교차 검색에선 palette(theme)·keybind(input)가 함께 나올 수 있어 `keybindRowStart`가 palette 한 행 오프셋을 더해 인덱스 충돌을 막는다(필터·인덱싱 단일 출처는 `currentSectionFields`).
- **클릭 진입점**: `/` 키 외에, 검색이 아닐 때 **제목 행(row 0)을 클릭**해도 검색이 시작된다 — 제목 우측에 `/ 검색` 힌트(muted)를 두어 클릭 가능함을 알린다. 컴포넌트 `handlePointer`가 제목 행 밴드 hit-test 시 `startSearch()` + `search_changed` Action을 낸다(키 `/` 경로와 동일 → platform이 `refreshSettingsFieldCount`). 필드 행은 `first_field_row`(=`title_rows`=2)부터라 제목 행 클릭은 nav/form hit-test와 충돌하지 않는다.
- **교차 결과 섹션 라벨 접두**: 교차 검색(`cross`)에서는 각 행 라벨 앞에 그 설정이 속한 섹션명을 붙여(`<섹션> › <라벨>`, 예: `외관 › 폰트 크기`) 어느 섹션 설정인지 한눈에 보인다. `buildSettingsFields`가 `settingsRowLabel(cross, section, label)` **단일 헬퍼**로 모든 행 종류(scalar는 필드의 `.section`, palette=`.theme`·keybind=`.input`·global=`.global_hotkey`)에 같은 규칙을 적용한다. 빈 쿼리(현재 섹션만)면 접두 없음. 긴 라벨은 폼 라벨 폭으로 truncate된다(고정 폭 유지).
- **한계(후속)**: 없음(검색 트랙 완결 — `/`·클릭 진입, 섹션 내·교차 필터, 섹션 라벨 접두 모두 구현).

### 6.9 HSV 색 picker(임의 색 선택) — color 위젯 모드 (CS-4-6)

16색 프리셋(§6.2)만으로 못 고르는 임의 색을 위해 **HSV picker**를 둔다. **새 ChromeHost 모달이 아니라 세팅 모달의 모드**(`State.picking`)다 — picker가 켜지면 `settings.view`가 폼 대신 picker를 그리고(early-return) 키/포인터가 picker로 라우팅된다(host 배선 추가 없이 기존 settings 경로 재사용).

- **HSV↔RGB**: `src/color.zig`의 `hsvToRgb`/`rgbToHsv`(`Hsv{h:0~359, s:0~100, v:0~100}`). 표준 변환(round-trip ±3 — 단위 테스트가 못박음). 색공간 수학은 chrome이 아니라 `color.zig`(렌더러 계층 공유 유틸)에 둔다.
- **레이아웃(셀-그리드 tui)**: ① **SV 그리드** — 채도(col 16칸) × 명도(row 8칸)의 원색 스와치(현재 hue 고정, 위가 명도 100). ② **hue 스트립** — 색상(col 16칸, 채도·명도 100). ③ **미리보기** — 현재 효과색 스와치 + `#rrggbb  H S V`. ④ 도움말. 셀-그리드라 **이산 샘플**(연속 해상도는 후속) — `svSatForCol`/`svValForRow`/`hueForCol` 등이 셀↔값을 정수 반올림으로 매핑(양 끝 0/100·0/360에 정확히 닿음). 선택 셀은 **▾ 마커 글리프**(text 레이어)로 표시 — palette 그리드와 같은 이유로 `Op.border`를 안 쓴다([§6.5]·[[tui-widgets-must-be-cell-text-not-quad]]: tui lowering의 `paintRectBg`가 1행 border를 셀 전체로 칠해 스와치 색을 덮음). picker 박스 기하는 `pickerLayout`이 단일 출처(렌더·hit-test 공유).
- **조작**: `←→` 채도, `↑↓` 명도, `[`/`]` 색상(wrap), `Enter` 확정, `Esc` 취소(picker만 닫고 폼 복귀 — 모달 유지). 포인터: SV 그리드 클릭·드래그 → s/v, hue 스트립 클릭 → h, 박스 밖 클릭 → 취소(드래그는 폼 위젯 press-gate 규율과 같아 hover로는 안 바뀜).
- **커밋**: 컴포넌트가 `Enter`에서 `color_picked` Action → host가 `settings_color_picked`로 정규화 → platform `commitPickerColor`가 `settings.pickerRgb()`를 `#rrggbb`로 직렬화해 선택 color 행 키에 `setText`(인라인 편집 커밋과 같은 인덱스 매핑·검증·write-back 예약) + picker 닫기. hex 문자열은 `loaded_config.arena` 소유.
- **연속 해상도(키)**: pick_h/s/v는 full precision(0~359/0~100)으로 저장되므로, **Shift+화살표**(±1 채도/명도)·**`{`/`}`**(=Shift+[/], ±1° hue)로 그리드 셀 **사이** 임의 값에 도달한다. 평범한 화살표·`[`/`]`는 빠른 셀 점프(coarse) 그대로 — 이산 그리드는 표시·coarse용이고 값은 미세 조정으로 연속. 미리보기 `#rrggbb H S V`가 정확한 효과색을 실시간 표시. (picker 고급화 리뷰)
- **포인터 sub-cell**: SV 그리드 클릭/드래그는 픽셀 위치를 0~100 s/v로 **연속** 매핑(셀 양자화 안 함 — 키 Shift 미세의 포인터 짝). hue 스트립은 셀 유지(`{`/`}` 키 미세로 보완 — 우측 끝 wrap 마커 회귀 회피).
- **hex 인라인 입력**: picker 안에서 **`#`** 키로 hex 편집 진입 → 6자리 타이핑/붙여넣기 → Enter가 `color.parseHex`→`rgbToHsv`로 h/s/v 적용(Esc=취소·picker 유지). 정확한 hex를 picker를 안 닫고 잡는다(hex/# 자리만 받음). 미리보기 행이 편집 중엔 버퍼를 accent로 표시.
- **eyedropper(스포이드)**: picker에서 **`i`** 키 → platform이 OS 화면 색 추출기(`NSColorSampler`, 돋보기로 화면 픽셀 클릭)를 연다(ABI v83 `take_color_sample_request`/`provide_sampled_color`, 비동기 콜백 — "언제"는 Zig·OS 추출기는 Swift host). 고른 색(sRGB→0~255 RGB)을 `setPickerRgb`로 picker에 반영(picking·non-editing 가드).
- **한계(후속)**: alpha(터미널 색은 #RRGGBB라 범위 밖에 가까움 — 보류). picker 고급화 사실상 완료(연속 해상도·sub-cell·hex 인라인·eyedropper).

### 6.10 퀵 터미널(`quick-terminal.*`) 라이브 반영

퀵 터미널 옵션(`height`/`width`/`position`/`screen`/`auto-hide`/`chrome`/`minimal-tabs`)은 전부 **schema-주도 스칼라**라 세팅 폼이 자동으로 위젯을 그리고, 커밋은 다른 스칼라와 똑같이 `setNumber`/`cycleEnum`/`setBool` + write-back으로 처리한다(특수 행 아님). 다만 이 값들은 Zig 코어가 아니라 **macOS 플랫폼(Swift `MaruAppHost`)이 오버레이 패널을 그릴 때** 쓰므로, "라이브 반영"의 배선이 다른 렌더 설정과 다르다.

- **세션-불변 스냅샷 제거**: 예전에는 Swift가 첫 토글(`ensureQuickTerminal`)에서 config를 한 번 읽어 캐시했고 이후엔 다시 안 읽어, 설정을 바꿔도 **이미 연 퀵 터미널엔 재시작 전까지 반영되지 않았다**(루트커즈). 지금은 매 토글마다 config를 라이브로 다시 읽는다.
- **패널 사각형은 ABI가 매 호출 계산**: 위치별 보임/숨김 사각형(가장자리 슬라이드 방향·center 페이드)은 Swift가 아니라 **Zig 순수 모듈 `quick_terminal_geometry.zig`의 `compute`**(세션·AppKit 없이 단위 테스트가 top/bottom/left/right/center·width 폴백·오프셋 원점 화면을 못박음)가 단일 출처다. Swift는 대상 화면 `visibleFrame`을 `maru_macos_app_session_quick_terminal_frames`(ABI)로 넘겨 세션의 **현재** config로 계산받는다(`quick_terminal_config`의 세션-불변 스냅샷과 대비 — frames는 매 호출 라이브). 그래서 `height`/`width`/`position` 변경은 다음 표시에서 바로 반영된다. config는 primary 세션에서 읽는다(설정 GUI 라이브 적용 대상이자 항상 존재).
- **`auto-hide`/`screen`**: 표시 직전 토글에서 Swift가 라이브로 다시 읽어 즉시 적용(포커스 잃음 자동 숨김 여부·대상 화면 모드).
- **`chrome`/`minimal-tabs`만 예외(재생성)**: 이 둘은 퀵 세션 **생성 인자**로 박혀 라이브로 못 바꾼다. 토글에서 현재 config와 생성 시점 스냅샷을 비교해 달라졌으면 기존 퀵 세션을 내리고(`tearDownQuickTerminal`) 새 chrome으로 재생성한다 — **그 스크래치 셸 상태는 초기화**된다(퀵 터미널은 transient라 허용, 라이브 반영의 유일한 트레이드오프).
- **멀티 모니터**: `screen=main`은 **주 디스플레이(메뉴 막대가 있는 원점 화면 = `NSScreen.screens.first`)**에 띄운다. `NSScreen.main`(키보드 포커스 창의 화면)은 글로벌 핫키 특성상 다른 앱이 전면일 때 그 화면으로 새므로 쓰지 않는다. 숨김 애니메이션은 **표시 시점에 캐시한 사각형**으로 되빠져, 표시 이후 마우스가 다른 모니터로 넘어가도(mouse 모드) 패널이 있던 화면 그대로 슬라이드 아웃한다.
- **한계(후속)**: config를 primary 세션에서 읽으므로, **멀티 창에서 primary가 아닌 창의 세팅으로 바꾸면** 파일엔 써지지만 primary 메모리 config는 stale이라 다음 재시작·해당 창 reload 전까지 퀵 터미널에 안 보일 수 있다(세션 간 config 브로드캐스트는 별도 과제). 단일 창(주 사용 흐름)에선 완전 반영된다.

### 6.11 항목별 기본값 리셋(변경된 행만 ↺) — 폼 행 어포던스

전체 리셋(§6.4)은 keep-alive 보존 예외를 제외한 나머지 설정을 한 번에 되돌려 "이 한 항목만 되돌리기"가 안 됐다. 각 설정 행에 **그 항목만 기본값으로 되돌리는** 어포던스를 둔다(사용자 요청). VS Code 세팅처럼 **기본값과 다른(=override된) 행에만** `↺`를 상시 표시하고, 클릭 또는 Backspace로 그 항목만 복원한다. 이미 기본값인 행엔 ↺가 없다(붐빔 최소).

- **"다름" 판정 = `theme.Config{}` 대비**: 기본값 단일 출처는 Zig 구조체 필드 초기화 값이다(§6.4의 `Config{}`와 같은 출처). platform이 `buildSettingsFields`에서 각 행의 현재값을 **기본 config에서 뽑은 같은 키의 값**과 비교해 `FieldRow.is_default`(true=기본과 같음)를 주입한다 — 기본 field 리스트는 `appendBoolFields`/`appendNumberFields`/… 를 `theme.Config{}`로 한 번 더 순회해 얻고 키로 룩업한다(별도 기본값 테이블 없음). 컴포넌트는 config를 모르므로 판정은 전부 platform이 하고 결과 bool만 내린다(neutral prop — `disabled`/palette 선례).
- **리셋 = override 줄 제거(값 덮어쓰기 아님)**: 일반 항목은 기본값 setter 뒤 `markConfigKeyRemoved(key)`로 override를 삭제한다. `session.keep-alive-after-quit`만 이 규칙의 소유권 예외다.
- **Backspace = "되돌리기"로 통일**: 폼 선택 행에서 Backspace(편집 아님)가 "그 항목 기본값 복원"이다. env/keybind/macro는 이미 Backspace=삭제였는데 그게 곧 그들의 기본값(없음)이라 의미가 자연히 일치한다 — 기존 `deleteSelectedSettingRow`를 `resetSelectedSettingRow`로 확장한다(삭제형 행=삭제, 그 외=기본값 setter + 줄 제거). 클릭 `↺`가 주 경로, Backspace가 키보드 동반.
- **행 종류별 리셋 규칙**:
  - `session.keep-alive-after-quit` → 값과 explicit override를 바꾸지 않고 "Workspace 토글을 직접 변경" notice. `reset_field`/Backspace는 snapshot·dirty/remove queue·파일 mutation 0이다.
  - scalar(bool/number/enum) → 기본 config 값으로 setter + `markConfigKeyRemoved(key)`.
  - text(자유 문자열)·color·font.family → 기본 문자열로 `setText` + 줄 제거. 기본 색·기본 폰트 패밀리는 `theme.Config{}`에서.
  - `theme.preset`(synthetic) → **v1 ↺ 제외**(is_default=true로 고정). 테마 되돌리기는 (a) 프리셋 드롭다운에서 기본 프리셋 선택, (b) "사용자 지정" 상태의 개별 **색 행 ↺**(프리셋 잠금이면 색·팔레트 행은 회색이라 ↺가 안 뜸 — §6.3), (c) 전체 리셋이 담당한다. 테마 전체를 되돌리는 파일 정리(모든 `theme.*`·palette override 제거)는 프리셋/follow-system과 얽혀 복잡해 v1에서 뺐다.
  - palette 셀 → **선택 셀** override 제거(§6.5): `theme.palette[grid_cell]=null` + `markConfigKeyRemoved(paletteKey(cell))`. ↺는 선택 셀이 override일 때만.
  - env/macro/keybind/global → 기존 삭제/해제 경로(§6.6·§6.7) = 그들의 기본값(없음/빌트인). keybind는 사용자 rebinding이 있을 때만 ↺(순수 unbind만 한 경우는 chord 기준이라 못 잡음 — 한계).
- **인터랙션 배선**: 컴포넌트 `Action`에 `reset_field`(폼 행 ↺ 클릭 — Backspace는 기존 `delete_row`가 platform에서 같은 `resetSelectedSettingRow`로 합류), `reset_all`(§6.4 네비) 추가 → host `HostAction`(`settings_reset_field`/`settings_reset_all`) → platform dispatch(`resetSelectedSettingRow`/`requestResetAll`). ↺는 폼 행 **맨 오른쪽 칸**(값 오른쪽 `reset_gutter_cols` 전용 여백 안, 단일 출처 `resetGlyphX`)에 얹는다 — 변경된 행마다 같은 자리에 정렬돼 발견성이 높다(사용자 요청; 예전엔 control 열 좌단 왼쪽 label_gap이라 값에 붙어 작고 눈에 안 띔). control/palette 열은 이 여백만큼 좌측으로 물러나 값과 겹치지 않고, 박스 폭(`form_content`)에 여백을 더해 값·라벨 가용 폭은 그대로 유지한다. 색은 선택 행 accent, 그 외도 `surface_fg`로 또렷하게(예전 muted에서 상향). `handlePointer`가 이 맨 오른쪽 밴드(`reset_icon_cols`칸)를 hit-test해 `reset_field`를 낸다.
  - **아이콘**: ↺ 글리프는 폰트 문자(U+21BA, 번들 폰트 미커버 → 작은 시스템 폴백)가 아니라 **빌드타임 SVG→coverage 합성 아이콘**(`assets/icons/reset.svg`, Octicons "sync" 파생, Plane-15 PUA `0xF000B`)이다 — chrome ⚙🔔 등과 같은 `renderer.icon_glyph` 경로로 셀을 꽉 채워 그려 크고 또렷하며 테마색이 자동 적용된다([[icon-svg-coverage-status]] 인프라 재사용). placeText가 **이 리셋 cp(`reset_glyph_cp`)만** width-2(~16px)로 렌더해(width-1이면 실루엣이 뭉개짐 — 사이드바 아이콘과 같은 취지) `reset_icon_cols=2`, `reset_gutter_cols=3`(아이콘 2 + 간격 1). 등록 아이콘 **전체**를 넓히지 않는 이유: git_branch 등은 Nerd Fonts MDI(U+F0001~) 범위와 겹쳐 사용자 config 값에 들어올 수 있는데, 그걸 넓히면 displayCols(=1칸) 기반 caret/truncate와 어긋나기 때문(리뷰). 미등록 PUA면 폰트 폴백이라 tofu는 안 난다. 같은 상수 `reset_glyph`를 네비 "초기화" 라벨(§6.4)도 공유해 두 진입점의 아이콘이 일관된다. **좁은 창 가드**: `computeLayout`은 이 섹션의 최대 우측 블록(palette 행이면 그리드, 아니면 control) + ↺ 여백 + 라벨 간격을 form_cols가 확보 못 하면 null을 돌려 아예 안 그린다(그리드가 라벨을 덮거나 라벨이 통째 사라지는 것 방지 — 리뷰).
- **라이브·영속**: 리셋도 일반 편집과 같은 `reapplyLoadedConfig`(화면 즉시 반영) + write-back 파이프라인(dirty/removed drain → Swift atomic write)을 탄다. env·shell.args·workspace.root처럼 spawn 시점에만 쓰이는 키는 라이브 재적용을 건너뛴다(§6.6과 같은 결).
- **한계(후속)**: (1) `theme.preset` 항목 ↺(위), (2) 기본값이 빈 문자열인 schema text(font.fallback 등)는 `setText`가 빈 값을 거부해 라이브 클리어가 안 되고 override 줄만 제거된다(다음 로드에 기본값 — 대부분 필드는 비-빈 기본값이라 무관), (3) keybind 순수 unbind 되돌리기. 리셋 확인은 항목 단위라 개별 확인 모달은 두지 않는다(전체 리셋만 파괴적이라 확인).

## 7. 의존성

- **S0-1b** ✅(머지) — `serialize.updateForKeys(original, config, keys)`로 **변경 키만** write-back(즉시-저장 결정에
  맞춤; override-only by construction — 기본값 40개를 안 쏟는다). 사이드바 write-back 경로(`serialize_sidebar_config`
  ABI export, snake_case 이름은 호환 유지 — `AppSession.serializeConfig`가 래핑)도 이 `updateForKeys`를 쓴다. GUI도
  같은 경로(바뀐 필드의 키를 넘김). (full-config diff·dirty 비트마스크는 불필요 — 즉시-저장은 키 단위.)
- **CS-4-0**(ChromeHost pointer) — 슬라이더·색 그리드 선결. ※ 슬라이더는 이후 `input_box`로 대체됨(slider.zig 제거).
- **S0-2**(자동 reload) — 외부 편집 즉시 반영(선택, GUI와 직교).
- 위젯 컴포넌트(CS-4-1~3).

## 8. PR 분해 (CS-4)

| PR | 내용 | 검증 |
|---|---|---|
| **S0-1b** ✅ | per-key write-back(`updateForKeys` — 변경 키만, override-only) + 사이드바 write-back 경로(`serialize_sidebar_config` ABI export) 재구현 | ✅ 머지(순수 단위) |
| **CS-4-0** ✅ | `ChromeHost` pointer 이벤트(InputEvent + 라우팅 + drag) | ✅ 머지(헤드리스 + 실기) |
| **CS-4-1** ✅ | 위젯 컴포넌트 toggle·dropdown·text/number·~~slider~~(neutral State+view+handle) | ✅ 머지(헤드리스 + 실기). ※ slider는 이후 **`input_box`(숫자 직접 입력)로 대체·`slider.zig` 제거** |
| **CS-4-2** ✅ | color input(16색 프리셋 + hex 입력) | ✅ 머지(헤드리스 + 실기) |
| **CS-4-3** ✅ | keybind recorder(`command_catalog` 행 + 키 캡처 + `keybind` 줄 write-back) — §6.7. unbind·충돌 UI는 후속 | 헤드리스 + 실기 |
| **CS-4-4** ✅ | **세팅 페이지 셸** — Section 네비 + 제너릭 폼(schema 메타 소비) + 폼 스크롤 + `toggle_settings`(⌘,) 키/메뉴 + **폼 검색**(`/` 필터 — 빈 쿼리=현재 섹션, 쿼리 입력 시 교차 섹션 — §6.8) | ✅ 머지(헤드리스 + 실기) |
| **CS-4-5** | write-back 연결(S0-1b ✅) + bespoke 에디터: **palette 16색 그리드 ✅**(§6.5) · **env·shell.args ✅**(§6.6, upsert; 삭제는 후속) → keybind(CS-4-3) | 헤드리스 + 실기 |
| **CS-4-6** ✅ | **color HSV picker** — SV 그리드 + hue 스트립 + 미리보기, 세팅 모달 모드(§6.9). `color.zig` HSV↔RGB | 헤드리스 + 실기 |
| **CS-4-7+** | (선택) picker 연속 해상도·alpha·eyedropper, 고급화 | 실기 |
| **CS-4-8** | **기본값 리셋 UX** — 세팅 네비 맨 아래 전체 리셋 진입점(§6.4) + 변경 행 ↺ 항목별 리셋(§6.11, 리셋=override 줄 제거) | 헤드리스 + 실기 |

> 시각/상호작용 PR(CS-4-0~5)은 로직을 헤드리스 단위로 고정하되, **머지 전 `zig build macos-app`로 ohah가 실기
> 확인**한다(보이나·눌리나·드래그되나). 스키마 PR과 결정적으로 다른 점.

## 9. 검증 전략

- **위젯 로직**: neutral `State`+`handle` 헤드리스 단위(클릭·드래그·키 → Action 전이), hit-test 순수 함수.
- **제너릭 렌더러**: schema 순회→FieldRow 빌드 헤드리스(필드 수·위젯 종류·section 그룹).
- **저장 round-trip**: override-only 직렬화 단위(기본값 안 씀, 변경분만; 주석 보존).
- **시각/상호작용**: `zig build macos-app` 실기(세팅 열기·각 위젯 조작·저장→파일 확인). 자동화 어려운 부분은 PR
  한계에 수동 검증 절차 기록([verification-matrix.md]).

## 10. 결정

> 1~3은 구현으로 확정됐다(아래 결정대로 머지). 4는 공존으로 유지한다.

1. **세팅 열기 키**: `⌘,`(macOS 관례) 빌트인으로 확정(CS-4-4b). "Open Config…"(파일 열기)는 메뉴에 별도 유지.
2. **저장 방식**: 변경 즉시 write-back으로 확정(사이드바 ⚙ 토글과 동형 — CS-4-4c). 명시 "저장" 버튼 없음.
3. **color picker 1차 범위**: 16색 프리셋 + hex 입력 확정([settings-page.md] §8 합의 — CS-4-2). HSV는 CS-4-6.
4. **Open Config 메뉴 관계**: 세팅 GUI와 "Open Config…"(파일 열기) 공존. GUI가 주, 파일 직접 편집은 보조.

## 관련 문서

- [config 스키마(메타 1급 필드)](config-schema.md) — 위젯/섹션/범위 메타의 출처(GUI가 소비)
- [세팅 페이지 전략과 구현 계획](settings-page.md) — 상위 계획(이 문서가 §6 Phase G를 재정의)
- [Chrome 전략](chrome-strategy.md) — 위젯을 그리는 컴포넌트·host·draw 구조
- [설정(config) 파일](configuration.md) — 키·형식·검증·풍부한 비고(GUI 짧은 doc의 상세판)
- [macOS 앱 호스트 경계](macos-app-host-boundary.md) — pointer raw 좌표 등 Swift/Zig 분담
- [PR 체크리스트](pr-checklist.md) — 시각 PR의 실기 검증 규율
