# 텍스트 필드 에디터 (주소창 인라인 편집 — caret·선택·마우스)

주소창(browser 패널 omnibox)을 **일반 웹 브라우저 주소창처럼** 편집하게 하는 단일행 텍스트 필드 에디터의 설계 단일 출처다. 마우스 드래그로 텍스트를 블록 선택하고, 클릭으로 caret을 문자 사이에 놓고, 화살표·Home/End·단어 점프·⌘A·복붙이 되는 편집 경험을 Zig+GPU chrome으로 구현한다.

이 문서는 [web-panel.md](web-panel.md) §7e가 *"mid-string 커서·선택은 후속"* 으로 남겨둔 그 후속의 상세 설계다. §7e의 주소창 밴드 렌더·nav 버튼·navigate 파이프라인(7e-1~7e-4)은 이미 구현됐고, 여기서 다루는 건 **밴드 안 텍스트의 편집 모델**뿐이다.

> 이 문서가 기술하는 편집 모델은 제품 경로에 배선돼 있다. 모델은 `src/chrome/components/text_field.zig`(L3 순수 — `TextField` + `fieldLayout`/`caretAtColumn`)가 소유하고, 주소창은 `AppSession.addr_field`로 그것을 소비한다. 진행/검증 상태의 단일 출처는 [검증 매트릭스](verification-matrix.md)의 "주소창 텍스트 필드 편집" 행이며, 이 문서는 상태가 아니라 **계약**을 기술한다.

> 이 설계는 두 차례 적대적 검증을 거쳤다(설계 1회 + 문서 1회). 검증이 못박은 제약은 §3·§5·§6에 인라인으로 표기한다.

## 1. 목표·범위

- **목표**: 주소창 편집 시 (a) 클릭으로 caret 위치 지정, (b) 드래그로 선택(블록 하이라이트), (c) 더블클릭 단어·트리플클릭 전체 선택, (d) shift+클릭/shift+화살표로 선택 확장, (e) ←/→(그래핌)·⌥←/→(단어)·Home/End·⌘←/→ 이동, (f) caret 기준 삽입/삭제, (g) ⌘A 전체선택·⌘C/⌘X/⌘V 복붙·⌘Z(후속).
- **범위**: **주소창 한 곳만**. 이 컴포넌트는 원리상 재사용 가능하나(향후 세팅 텍스트 입력 등), **지금은 소비자 1개**로 출발한다. find/palette/rename/사이드바 검색은 **이관하지 않는다**(§2 참조).
- **비목표(현재)**: 멀티라인, undo/redo 무한 스택, 우클릭 컨텍스트 메뉴, 접근성(VoiceOver) 완전 대응, 네이티브 Services 메뉴. macOS marked-text 완전 프로토콜은 §7에서 후속 슬라이스로 분리.

## 2. 베이스·결정 (왜 이 구조인가)

[document-basis-and-decision] 규율에 따라 무엇을 베이스로 했고 대안 중 무엇을 왜 택했는지 못박는다.

### 2.1 (A) Zig-GPU 자체 구현 vs (B) 네이티브 텍스트 컨트롤 → **(A)**

`NSTextField`/`NSTextView`를 임베드하면 선택·드래그·IME·시스템 단축키·접근성이 공짜지만, **장기 유지보수·코드 관리에서 (A)가 우위**라 (A)를 택한다:

- **패러다임 단일성**: Maru chrome 전체(사이드바·탭·divider·find·palette·세팅)가 Zig state/view/hitTest + 헤드리스 테스트 **한 모델**이다([chrome-strategy.md] §5.4). (B)는 주소창만 네이티브 뷰 섬을 만들어 유지보수자가 두 패러다임을 알아야 하고, Metal 합성 chrome 안 네이티브 뷰의 z-order·responder·포커스 seam을 영구히 진다.
- **이식성**(로드맵 목표, [layering-and-portability.md] §1): (A)는 OS-중립 모델 1개 + 얇은 per-platform 렌더 바인딩. (B)는 플랫폼마다 다른 네이티브 컨트롤(NSTextField/Win32 EDIT/GTK Entry/DOM input) — 동작이 플랫폼마다 갈라지는 N배 유지보수.
- **테스트성·테마**: (A)는 헤드리스 컴포넌트 테스트로 회귀를 CI에서 잡고 chrome 토큰으로 그려 테마/다크모드/opacity를 자동 추종. (B)의 합성/포커스 버그는 헤드리스로 안 잡혀 GUI 손 테스트에만 의존하고([web-panel.md] §4가 WKWebView로 문서화한 그 고통), 테마 변경마다 네이티브 속성 수동 미러링이 필요하다.

(B)의 유일한 장기 강점은 "OS가 어려운 텍스트 로직을 대신 소유"인데, 그 대가로 되풀이되는 통합·테마·이식성 세금을 문다. Maru의 상설 결정(Zig-GPU chrome·이식성)과 네이티브 합성 이력을 감안하면 (A)가 명확하다.

### 2.2 새 컴포넌트 vs `OverlayInput` 제자리 확장 vs 전원 이관 → **새 컴포넌트, 이관 0**

텍스트 입력은 현재 공유 `OverlayInput`([overlay_input.zig])을 find·palette·rename·사이드바검색·**주소창**이 쓴다(버퍼 DRY는 이미 달성). 그러나:

- **전원 이관(보편 TextField로 5소비자+세팅 수렴)은 기각**: 적대 검증 결과 (i) IME 라우터가 소비자를 한 switch에 나열해 국소 이관이 아님, (ii) 세팅 고정 버퍼는 *"allocator 불요"*가 의도된 설계라([settings.zig] 주석) ArrayList 흡수가 수명주기·POD성을 깬다, (iii) find/palette는 `left`/`right`를 **오버레이 닫기**에 배정해 caret 편집을 **명시적으로 거부**한다([find.zig]·[palette.zig]). 즉 마우스 편집 실수요는 주소창 1곳뿐이라 수렴 이득이 이관 비용을 정당화 못 한다.
- **`OverlayInput` 제자리 확장(caret/선택 필드 추가)도 지양**: 4/5 소비자가 안 쓰는 편집 상태를 lean한 검색 모델에 욱여넣어 추상을 흐린다.
- **결정: 편집기를 새 컴포넌트 `chrome/components/text_field.zig`로 분리**하고, `OverlayInput`은 검색 입력 모델로 **lean 유지**한다. 새 struct라도 EAW 폭 수학은 복제하지 않고 **모듈 레벨 순수 헬퍼(`displayCols`·[width.zig])를 호출**해 DRY를 지킨다.

### 2.3 적대 검증이 남긴 두 개의 벽 (new/extend와 무관하게 동일)

1. **IME × 중간 caret**: 현재 Swift `NSTextInputClient`가 `selectedRange()`=항상 빈 `NSRange`, `insertText`/`setMarkedText`가 `replacementRange`를 **무시**, `markedRange()`=**location 항상 0**(length만 조합 길이)([MaruAppHost.swift])이라, 중간 caret에서 조합하면 preedit가 끝에 그려지고 끝에 확정된다. 선택 대체(선택 후 조합)는 미지원. → §7에서 v1/후속 분리.
2. **그려진 caret이 L4에서 나옴 + 말줄임 예약 규약 불일치**: 편집 밴드는 coretext `buildPaneAddressBarDrawList`가 그리고 caret 열은 `appendEllipsizedTitle`(제목 말줄임, L4, `.tail` 앵커)에서 나온다. **폭 함수는 이미 일치**한다 — `text_layout.clusterCols = @max(1, width.cellWidth)`([src/chrome/text_layout.zig])이고 주소창은 `widen_icons=false`라 `displayCols`와 같은 값. 진짜 문제는 (a) 기존 경로가 **끝-caret 전용**이라 mid-string caret을 못 놓고, (b) hit-test가 순진하게 `overlay_input.tailWindow`로 역산하면 **"…" 1칸 예약 규약이 서로 달라**(coretext는 함수 **내부** 예약, tailWindow는 **호출자** 예산 — coretext 주석이 *"단일 함수화는 계층 침범"* 이라 공유를 금지) 말줄임 경계에서 드리프트한다. → §3에서 **필드 전용 새 순수 레이아웃 함수**로 해결.

### 2.4 상호작용·경계 베이스

- **선택 상호작용 모델**은 터미널 [selection.zig]에서 가져온다 — 드래그(down=`select_start`, drag=`select_extend`, 밖=autoscroll), 더블클릭 단어(`select_word`), 트리플클릭 줄(`select_line`), 이동 없는 클릭=해제. 단 **데이터 모델(그리드 절대행 vs 문자열 오프셋)과 실행 스레드는 다르다** — 터미널 선택은 `enqueueCoreCommand`로 reader 스레드에 위임([core_command.zig])하지만, **이 필드 에디터는 메인 chrome 스레드에서 `AppSession` 상태를 직접 mutate한다(core mutate·위임 아님)** — `addr_input` 전이와 동형(§4). 시맨틱만 차용, 위임 경로는 차용 금지. ([read-reference-terminals-early]: Ghostty 선택 모델 참조.)
- **그래핌 경계**는 [grapheme-clustering.md] 단일 출처(caret 이동·삭제는 코드포인트가 아니라 그래핌 클러스터 단위 — 이모지 ZWJ·결합 문자 안전). **코드 단일 출처는 `grapheme.zig`**인데, 이 모듈은 원래 `terminal/grapheme.zig`(L1)에 있었고 **chrome은 terminal을 import할 수 없다**(tests/boundary/imports.zig). grapheme.zig는 `width.zig`(최상위 중립)만 의존하는 순수 UAX#29 분절이라 width.zig와 동격이므로, 슬라이스 1에서 **최상위 중립 `src/grapheme.zig`로 승격**해 terminal(코어 print)·chrome(TextField) 공용으로 만든다(유일 importer였던 screen.zig repoint, [full-removal-no-legacy-shims]대로 shim 없이 이동). 설계 검증이 놓친 경계 결함을 슬라이스 1 착수 시 정정한 것.
- **키 바인딩**은 [key-input-and-shortcuts.md] "기본 제공 macOS 줄 편집 단축키"와 정합(⌘←/→·⌥←/→·⌃A/⌃E 등)하고, IME 조합 중 판정은 같은 문서 "레이아웃 독립 단축키와 IME"를 따른다.

## 3. 레이어 배치 — L3 순수 모델 + L4 렌더/hit-test, **단일 레이아웃 소스**

[layering-and-portability.md] §2의 4층 위상을 지킨다. 핵심은 [chrome-strategy.md] §5.4의 **MUST 규범**: *view와 hitTest가 하나의 픽셀-레이아웃 소스를 공유한다.* §2.3 벽②의 드리프트는 기존 말줄임 경로를 재사용하면 나므로, **필드 전용 새 레이아웃 함수**를 만들어 draw와 hit-test가 그것을 공유한다.

### 3.1 L3 (중립, `text_field.zig`) — OS 타입 0

- **모델**: 편집 상태 + 순수 편집 ops (§4).
- **레이아웃(순수)**: `fieldLayout(model, metrics{cols, cell_width_px, nav_end}) → FieldLayout`. metrics는 props로 주입(터미널 셀 폭·nav 존 폭). 반환은 **run 리스트**다(단일 slice 아님 — §3.3 벽): `{ runs: [pre, preedit, post], caret_col, selection_span_cols, lead_ellipsis, tail_ellipsis }`. caret 열·선택 span·가로 스크롤 창을 **한 함수**에서 산출한다.
- **hit-test(순수)**: `caretAtColumn(layout, click_col) → byte_offset`. 위 레이아웃의 역함수 — 같은 run 배치·같은 폭 규약이라 드리프트 불가. **그래핌 스냅**: 반환 오프셋은 항상 그래핌 경계로 스냅한다(폭 산술만으론 base+combining 사이 비-경계 열이 나올 수 있으므로 [grapheme-clustering.md] 경계로 보정).

**제약 (검증이 못박음)**:
- **폭 규약 통일**: `fieldLayout`·`caretAtColumn`은 반드시 `@max(1, cellWidth)`(=`displayCols` 규약)를 쓴다. **raw `width.cellWidth` 금지** — 결합 문자에서 0을 반환해 coretext(`@max(1,…)`=1)와 **결합 문자 경계에서 1칸 어긋난다**.
- **metrics 단일 계산**: `nav_end`(=`nav_button_count*nav_button_w`)와 band `cols`(=`pb.full.w/cw`)는 지금 렌더·caret-rect·hit-test가 **각각 재계산**한다. `fieldLayout` 도입 시 **한 곳에서 계산한 metrics 구조체를 draw+hit-test+caret-rect 세 곳에 스레드**한다(site별 재계산 금지 — 안 그러면 순수성이 드리프트를 caller로 옮길 뿐).

### 3.2 L4 (platform)

- **렌더**: `buildPaneAddressBarDrawList`의 **주소창 editing=true 경로만** `fieldLayout` 소비로 분기 — caret을 `caret_col`에 셀 정렬 셀로, 선택을 `selection_span_cols`에 배경 quad로 emit. **범위 한정 필수**([full-removal-no-legacy-shims]를 문자 그대로 적용 금지): `appendEllipsizedTitle`과 `.tail` 앵커는 **읽기전용 URL(`.head`)·탭 라벨·사이드바/탭 rename·grip·cmdline·floating/sticky**가 공유하는 단일 출처라 **존치**한다. 즉 `if (editing) fieldLayout-emit else appendEllipsizedTitle(.head)`로 밴드 안에서만 분기한다.
- **읽기전용↔편집 전환 일치**: 두 레이아웃 엔진이 한 밴드에 공존하므로, 편집 진입/이탈 시 URL 텍스트가 열 점프하지 않도록 **nav_end·cols·"…" 1칸 예약·폭 규약을 양쪽이 동일**하게 맞춘다.
- **hit-test 배선**: `app_session.mouse()`의 밴드 분기([app_session.zig])가 `navButtonAt`(버튼 존 `[0,nav_end)`)을 **먼저** 소비하고, URL 존(`col ≥ nav_end`)만 `caretAtColumn`에 넘긴다(버튼 위 클릭 ≠ caret).
- **IME 브리지**(§7): Swift `NSTextInputClient` ↔ Zig preedit anchor.

즉 필드 레이아웃 계산은 **L3에서 순수·이식 가능**하고, L4는 그 결과를 셀/quad로 lowering + 클릭 px를 열로 바꿔 넘기기만 한다. 단일 소스는 L3 `fieldLayout`이다.

### 3.3 preedit-at-caret이 반환 shape를 규정한다 (§2.3 벽① 관련)

현재는 끝-caret이라 `url = query ++ preedit`를 **끝에 이어** 붙여 충돌이 없다. mid-string caret은 이를 깬다:

- **run 리스트 필수**: 표시 내용 = `text[0..caret] ++ preedit ++ text[caret..]` — `text`의 부분 슬라이스가 아니라 세 조각이다. 그래서 `fieldLayout`은 `visible_slice: []const u8` 하나가 아니라 **`[pre, preedit, post]` run**을 반환한다(무-alloc pure-slice 규약 유지).
- **스크롤 예산**: 가로 스크롤 창은 caret **및 preedit 전체**가 같이 보이도록 예산한다(caret 가시성만으론 부족).
- **선택 span**: `text[caret..]`는 `displayCols(preedit)`만큼 우측 이동하므로 `selection_span_cols`가 이를 반영한다.
- **조합 중 caret 그리기 규칙**(§6·§7): `caret_col`은 preedit **시작 열**이라 반전 블록 caret이 첫 preedit 셀을 덮어 조합 글자를 가린다. → **조합 중에는 block caret을 preedit 끝에 그리거나 억제**한다(현행 끝-caret 동작 보존).

## 4. 데이터 모델·수명주기 (`text_field.zig`)

```
TextField = struct {
    text:      ArrayList(u8),   // 확정 텍스트(UTF-8)
    preedit:   ArrayList(u8),   // IME 조합(§7). caret 위치에 겹쳐 표시
    caret:     usize,           // text 내 바이트 오프셋(그래핌 경계에만 위치)
    selection: ?struct { anchor: usize, focus: usize }, // 없으면 caret만
}
```

- **백킹 = ArrayList** (동적 — URL은 길이 상한 없음). `OverlayInput`과 동일 소유 규율.
- **스레드**: 모든 mutate는 **메인 chrome 스레드**(§2.4). core_mutex/`enqueueCoreCommand` 없음.
- **수명주기**: `TextField`는 **세션 수명 지속 필드**다(매 편집마다 재생성 아님). `dropAddrEditIfSurface`([app_session.zig], destroyTerm teardown)·`cancelAddrEdit`·`commitAddrEdit`는 `text`·`preedit` 두 ArrayList를 **`clear`**(deinit 아님, capacity 유지)하고 `caret=0`·`selection=null`로 리셋한다. **`deinit`은 세션 teardown 1회**(소유자=app_session).
- **순수 ops** (전부 헤드리스 테스트):
  - 편집: `insertText(bytes)`·`insertCp(cp)`(caret에 삽입, 선택 있으면 대체 후 삽입)·`deleteBackward`/`deleteForward`(그래핌 단위·선택 있으면 선택 삭제)·`deleteSelection`.
  - 이동: `moveLeft`/`moveRight`(그래핌)·`moveWordLeft`/`moveWordRight`(separators 주입)·`moveHome`/`moveEnd`. 각각 `extend: bool`로 shift-선택 확장.
  - 선택: `selectWordAt(offset)`·`selectAll`·`clearSelection`·`selectTo(offset)`(드래그/shift+클릭).
  - IME: `setPreedit(bytes)`·`commitPreedit`(caret에 확정).
- `OverlayInput.appendChar`/`backspace`(끝 고정)와 달리 **전부 caret 기준**. 이게 이 컴포넌트를 새로 만드는 이유다.
- **단어 경계**: 터미널 `word-separators`(config) 단일 출처를 재사용하되, 주소창 소비자가 URL 지향 집합(`/ . ? & # =` 등)을 주입할 수 있게 **정책은 인자**로 받는다(컴포넌트는 중립).

## 5. 상호작용

### 5.1 마우스 ([selection.zig] 시맨틱 차용)

| 제스처 | 동작 |
|---|---|
| 클릭(down) | `col ≥ nav_end`면 `caretAtColumn`으로 caret 배치 + 선택 해제. 밴드 밖이면 편집 종료(mouse-down에서만) |
| 드래그 | 앵커=down 지점, focus=현재 → `selectTo`. 밴드 좌우 끝 넘으면 가로 autoscroll |
| shift+클릭 | 기존 caret을 앵커로 `selectTo` |
| 더블클릭 | `selectWordAt` |
| 트리플클릭 | `selectAll` |

- `app_session.mouse()` 밴드 분기에 arm. `navButtonAt`(버튼 존)을 `caretAtColumn`보다 **먼저** 판정·소비(§3.2). 드래그 캡처 상태는 터미널 선택용 `mouse_drag_selecting`과 **별도 필드**로 둔다.
- **포커스 불변식**([web-panel.md] §4): 드래그가 밴드를 벗어나도 **`addr_edit`을 유지**해 `terminalOwnsInput`(=`…∪ addr_edit`)을 true로 지켜, 매 tick `reconcileWebFocus`가 mid-drag에 firstResponder를 웹뷰로 넘기지 않게 한다. 클릭-어웨이 취소는 mouse-down에만 적용.
- `selectTo`·선택 변경·편집 종료는 각각 **`metal_dirty=true`**(§6).

### 5.2 키보드 ([key-input-and-shortcuts.md] 정합)

- 이동: ← →(그래핌)·⌥← ⌥→(단어)·⌘←/Home ⌘→/End·⌃A ⌃E. 각각 +shift=선택 확장.
- 편집: Backspace/⌫·Delete/⌦(그래핌 또는 선택)·⌥⌫(단어 삭제).
- 선택·클립보드: ⌘A·⌘C·⌘X·⌘V — **§5.3 클립보드 브리지 필요**.
- 확정/취소: Enter=`commitAddrEdit`·Esc=`cancelAddrEdit`([app_session.zig] 기존 경로 유지).
- `handleAddrEditKey`가 현재 화살표/tab을 무시([app_session.zig])하는 걸 위 ops 호출로 교체.

### 5.3 클립보드 브리지 (검증이 짚은 신규 배선)

현재 ⌘V는 Swift `handleKeyDown`이 `pastePasteboardText`→PTY로 가로채므로([MaruAppHost.swift]) **web Term(PTY 없음)에선 소멸**한다 — 즉 필드에 안 온다("no-op"이 아니라 엉뚱한 데로 감). 필드 편집 지원엔 신규 경로가 필요하다:

- **⌘V**: `inputFocus==.addr_edit`이면 그 분기(또는 `take_clipboard_action` 동형 신호)로 **NSPasteboard 텍스트 → `TextField.insertText(caret)`** 라우팅(개행 strip — 단일행).
- **⌘C/⌘X**: `copySelectionToPasteboard`는 현재 터미널 선택을 뽑는다 — `addr_edit`이면 **필드 선택 텍스트**를 뽑아 NSPasteboard에 쓰도록 분기(⌘X는 뒤이어 `deleteSelection`).

## 6. 렌더

- **caret**: `fieldLayout.caret_col`에 셀 정렬. **현행 밴드 caret은 정적 반전 블록 셀**(v95 blink 페이드 suffix pass 아님)이므로, **v1은 정적 반전 셀을 caret_col로 옮기는 것**으로 한다(blink 승격은 후속 — "페이드 uniform 재사용"이라 뭉개지 말 것). 조합 중 caret 위치는 §3.3 규칙.
- **선택 하이라이트**: `selection_span_cols`에 accent 배경 quad(터미널 선택 하이라이트와 시각 일관). 셀 단위 정렬([tui-widgets-must-be-cell-text-not-quad] — sub-pixel quad 금지).
- **선택 지속성**: `selectTo`/선택 변경/편집 종료가 `metal_dirty`를 세운다. **편집 종료(`addr_edit=null`)면 밴드가 읽기전용 URL로 재렌더돼 선택 quad가 자연 소멸**한다.
- **가로 스크롤**: `fieldLayout`이 caret(+preedit §3.3)이 항상 보이도록 visible 창을 정한다. `tailWindow`(끝 고정)를 **임의 caret 시야 유지**로 일반화 — caret이 창 밖이면 좌/우 스크롤, 선두/말미 "…" 표시(예약 규약은 §3.2 일치).
- **EAW 반칸**: 한글(2칸) 위 클릭은 왼쪽 반=글자 앞, 오른쪽 반=글자 뒤로 `caretAtColumn`이 **그래핌 스냅**(§3.1). 셀 정렬 caret은 그래핌 경계에만 놓인다.

## 7. IME (§2.3 벽① — v1 범위와 후속 분리)

- **v1 (이 이니셔티브)**: preedit를 **caret 위치에** 렌더(model이 preedit+caret 소유, `fieldLayout`이 run으로 배치 §3.3) + 확정 텍스트를 **caret에 삽입**(committed-text 라우팅을 `addrEditAppend`(끝, `sendTextAsKeys`→`handleAddrEditKey` 경유)에서 `insertText`(caret)로 교체). `addrEditCaretRect`(IME 후보창)를 끝에서 caret 열로. 조합 중 caret 이동은 잠금(조합 취소 후 이동). 조합 중 block caret은 §3.3 규칙(preedit 안 가림).
- **후속 슬라이스 (별도)**: macOS marked-text **완전 프로토콜** — Swift `NSTextInputClient.selectedRange`/`markedRange`를 실 문서 오프셋으로 반환 + `insertText(_:replacementRange:)`/`setMarkedText(_:selectedRange:replacementRange:)`의 `replacementRange` 처리 → 선택 대체 조합·정확한 후보창. Swift↔Zig ABI 확장 동반. 원리·이득·벽·착수 적기를 아래에 남긴다([document-basis-and-decision]).
  - **원리(양방향 대화)**: macOS IME는 별도 상태기계이고 앱은 그 **문서**다 — `NSTextInputClient` 계약으로 양방향 대화한다. 입력기는 조작(`setMarkedText`/`insertText`) **전에** 앱에게 상태를 되묻고(`selectedRange`/`markedRange`/`attributedSubstring`/`firstRect`/`characterIndex`), 그 답에 따라 조작을 결정한다. 앱이 거짓(빈 range·location 0)을 답하면 입력기가 **틀린 문서 모델** 위에서 조작한다. 끝-caret·무선택에서만 "틀린 모델 == 현실"이 우연히 겹쳐 현행 stub이 동작한다(Zig가 입력기 주장 위치를 무시하고 자기 caret에 넣기 때문). 그 밖(중간 caret·선택)은 어긋난다.
  - **이득(질의 메서드 → 여는 기능)**:
    - `selectedRange()` 실 선택 반환 → **선택 대체 조합**(선택 후 조합 시작 시 선택이 조합으로 교체; §2.3 벽① "미지원" 해소).
    - `markedRange()` 실 location 반환 → **정확한 후보창** + 조합 중 편집(자모 교정) 위치.
    - `attributedSubstring(forProposedRange:)` 실 텍스트 반환 → **재변환(reconversion)** — 확정 글자를 선택해 다시 입력기로 여는 것(한자 변환·일본어 kanji 재변환). 입력기가 선택된 실 글자를 읽어야 후보를 낸다.
    - `insertText`/`setMarkedText`의 `replacementRange` 처리 → 받아쓰기·자동수정의 **범위 교체**(caret 삽입이 아니라 지정 범위 교정).
    - `characterIndex(for:)` 실 매핑 반환 → 마크드 텍스트/후보 위 **마우스 조작**.
  - **벽(왜 별도 이니셔티브인가)**:
    1. **좌표계 변환(UTF-16 ↔ UTF-8/그래핌)**: `NSTextInputClient` range는 전부 **UTF-16 코드 유닛** 단위인데 `TextField`는 **UTF-8 바이트 + 그래핌 클러스터** 단위다. 매 질의/답에 변환 레이어가 필요하다 — 한글(BMP=1 유닛)·이모지(surrogate pair=2 유닛)·결합 문자에서 오프셋이 어긋나면 조합·커서가 **조용히** 틀어진다(가장 큰 버그 원천).
    2. **양방향 ABI**: 현행은 Zig가 자기 caret에 넣는 **단방향**이라 ABI가 단순하다. 완전 구현은 Swift가 매 질의마다 Zig에 주소 필드의 caret/선택/조합 오프셋을 **UTF-16으로 묻는 읽기 ABI** + `replacementRange`로 특정 범위를 교체하는 **쓰기 ABI**를 새로 뚫어야 한다.
    3. **엣지 회귀(현 stub은 의도된 최소값)**: 지금 stub은 순진한 게 아니라 엣지를 피하려 최소로 둔 것이다 — `markedRange()`가 `NSNotFound` 대신 빈 range를 주는 건 NSNotFound 시 한글 마지막 자모 Backspace가 삭제 대신 확정(insertText)으로 처리되던 버그 때문이라고 [MaruAppHost.swift] 주석에 못박혀 있다. 완전 구현은 이런 IME별(한/일/중)·자모별 엣지를 전수 재검증해야 한다.
  - **착수 적기**: 주소창은 짧은 URL 입력이라 위 이득의 실수요가 낮다. **2번째 `TextField` 소비자**(예: 향후 코드 에디터 surface — 긴 한글 문서 편집)가 등장해 선택-대체·재변환 수요가 오를 때 함께 착수하는 게 비용 대비 효율이다(§8 후속의 "향후 2번째 소비자 등장 시 보편 추출 검토"와 동시).
- **회귀 방지**: [overlay_input.zig] 모듈 주석이 못박은 "커밋 N + 조합 N+1이 다음 조합을 지움" 회귀가 caret 전진과 preedit 앵커 동기에서 재발할 수 있다. v1은 그 흐름(imeInsert→imeMarked 순서)의 헤드리스 IME 테스트를 caret-aware로 **확장**한다([devsession-undefined-test-field-trap]: 새 필드는 기본값 필수).

## 8. 구현 구성 (레이어별 책임)

편집 모델은 아래 다섯 조각으로 나뉜다. 각 조각은 독립 green·doc 동기·[pr-checklist.md] 준수로 들어왔다([drive-multi-pr-plan-to-completion]).

- **모델·레이아웃·hit-test (순수, `text_field.zig`)**: `TextField` struct + 편집 ops + `fieldLayout`(run 반환)/`caretAtColumn`(그래핌 스냅). 헤드리스 테스트가 편집 ops·EAW·그래핌 경계·선택·가로 스크롤·역함수 왕복·preedit run을 고정한다.
- **렌더**: `buildPaneAddressBarDrawList`의 **editing 경로만** `fieldLayout`을 소비한다(§3.2 범위 한정) — caret 열·선택 quad, metrics 단일 계산.
- **마우스**: `app_session.mouse()` 밴드 분기가 클릭 caret(`addrBandOffsetAt`→`caretAtColumn`)·드래그 선택(`selectTo`)·더블클릭 단어(`selectWordAt`)·트리플클릭 전체(`selectAll`)를 라우팅한다. nav 버튼 존은 caret 판정보다 **먼저** 소비한다(§3.2).
- **키보드·클립보드**: ←/→·⌥단어·⌘Home/End·shift 선택·⌘A·⌃A/⌃E(emacs)·⌫/⌥⌫/⌘⌫ + §5.3 ⌘C/⌘X/⌘V 브리지.
- **IME**: `inputFocus=.addr_edit` 라우팅으로 `setPreedit`/`commitPreedit`이 caret 자리에 조합을 얹는다(§7 v1).

**이 계약 밖(별도 이니셔티브)**: macOS marked-text 완전 프로토콜(§7 — 양방향 UTF-16 caret 읽기/`replacementRange` 쓰기 ABI가 필요), ⌘Z undo, caret blink 승격(v95), 2번째 소비자가 생길 때의 보편 컴포넌트 추출.

## 9. 검증

- **헤드리스**(슬라이스 1·핵심): 편집 ops 왕복, EAW/그래핌 경계 caret, 선택 삭제·대체, `fieldLayout`↔`caretAtColumn` 역함수 일치(드리프트 0), preedit run 배치, 가로 스크롤 caret+preedit 시야 유지, IME preedit-at-caret + 멀티문자 흐름 무회귀.
- **오프스크린 스크린샷**(슬라이스 2, [renderer-screenshot-self-verify-loop]): caret 중간 위치·선택 하이라이트가 첫 frame에 렌더.
- **GUI 손 테스트**(마우스 드래그·포커스·IME·클립보드는 헤드리스 밖 [run-macos-app-before-merge]): 드래그 선택, 클릭 caret, 더블클릭 단어, ⌥←/→, ⌘C/⌘X/⌘V, 한글 조합 caret 위치, 드래그가 밴드 벗어나도 웹뷰로 포커스 안 새는지·web pane 위 편집 무회귀([web-panel.md] §4).
- [verification-matrix.md]에 항목 추가.

## 10. 리스크·미해결

- **IME 완전 대응 미룸**: v1은 선택-대체 조합·후보창 정확도가 부분적. 조합 중 UX가 덜 매끈할 수 있음(후속에서 해소).
- **품질 천장**: (A)의 본질 — 네이티브 "느낌" 100% 일치는 지속 폴리시. v1 목표는 브라우저의 핵심 제스처(드래그 선택·클릭 caret·단어·복붙) 커버.
- **`app_session.zig` hot file**: 밴드 hit-test·IME 라우팅이 이 파일(≈40k줄)에 있어 진행 중 작업과 충돌 위험 → §11 타이밍.
- **밴드가 coretext(L4) 상주 + 두 레이아웃 엔진 공존**: 읽기전용(`appendEllipsizedTitle`)·편집(`fieldLayout`)이 한 밴드에 공존하므로 §3.2 일치 규약을 어기면 전환 시 열 점프. 향후 밴드를 정식 L3 `ChromeDraw` 컴포넌트로 승격하면 lowering만 backend가 맡아 완전 중립화(별도 cleanup, 이 범위 밖).

## 11. 기존 문서 정정

- **[web-panel.md] §7e 정정**: 텍스트 입력을 *"공유 OverlayInput 재사용(caret·가로 스크롤 단일 출처)"* 로 적었으나, `OverlayInput`은 텍스트 저장+EAW+**끝-caret 열(`queryCols`)**만 제공하고 밴드의 표시 caret·가로 스크롤은 coretext `appendEllipsizedTitle`(tail 앵커)이 생성했다(caret/선택/가로 스크롤 **미소유**). 주소창 텍스트는 이제 이 문서의 `TextField`가 소유하며, §7e의 *"mid-string 커서·선택은 후속"* 이 곧 이 문서다.
