# Screen struct fold (§10, 방향 B)

필드를 `Screen` 하위 struct로 접는 2단계 이니셔티브다. B-min은 채택·확정됐고 B-full(Option 3, per-screen cursor)은 의도적 동작 변경을 동반한다. 분해 1단계(방향 A)의 설계는 [TerminalCore 분해 설계](../terminal-core-decomposition.md)가 소유한다.

> **절 번호는 파일을 넘어 이어진다.** 본문이 `§7`처럼 절만 가리키면 여기서 소유 파일을 찾는다 — §1~§3·§5 [terminal-core-decomposition.md](../terminal-core-decomposition.md) · §0·§4·§6~§9 [분해 기록](terminal-core-decomposition.md) · §10 [Screen struct fold](screen-struct-fold.md) · §11 [page-aligned storage](page-aligned-storage.md)

## 10. Screen struct fold (방향 B, 2단계) — B-min(B1~B3) 완결 · B-full(B4~) 진행 (헤딩 정정 2026-08-29)

§2에서 미룬 **2단계**(architecture.md §"스크롤백은 화면에 귀속한다" 종착지)다. 방향 A(연산 추출)는 §5~§9로 소진됐고, 남은 건 **필드를 `Screen` 하위 struct로 접는** 구조 변경이다. 이건 함수 이동과 성격이 다르다 — 동작 변경 없는 **대규모 기계적 필드-접근 rename**(self.cells → self.screen.cells)이고, alt-screen swap 의미까지 건드린다. **고위험 단일 도약**이라 합의 후 착수한다.

### 10.1 규모 (실측)

- **내부(terminal/) self.<field> 접근 ~792**: cursor 159·size 143·sb 116·cells 72·pen 51·wrapped 50·prompt_marks 47·view_offset 36·last_print 35·dirty 33·pending_wrap 29·tabstops 17·scroll_top 16·scroll_bottom 15·semantic_state 13·alt_active 12·…
- **외부(비 terminal/) TerminalCore 필드 직접 접근 ~78**: core.size 31·view_offset 23·cells 12·alt_active 6·cursor 4·wrapped 1·prompt_marks 1 (대부분 renderer/runtime 테스트가 fake core를 세팅 + surface.zig/host.zig가 `core.size`로 창 geometry 읽음).
- 합계 **~870 접근부 rename**. 순수 기계적(동작 불변), 컴파일러+289 테스트가 누락 강제.

### 10.2 핵심 설계 결정 — 무엇을 Screen에 넣나 (동작 보존 긴장)

maru의 **현재 alt-screen 전환은 grid(cells·wrapped·prompt_marks)+`sb`만 swap**한다(saved_cells/saved_wrapped/saved_prompt_marks/saved_sb ↔ 활성). cursor는 reset/`saved_cursor`로 복원, scroll region·모드·tabstops는 **swap 안 함**. 따라서 "Screen에 넣어 swap"하는 필드는 **현 swap 의미와 일치**해야 동작이 보존된다(아무거나 Screen에 넣고 swap하면 alt 전환 동작이 바뀜).

두 가지 scope:

**(B-min) grid+scrollback만** — `Screen = { cells, wrapped, prompt_marks, sb }`. 현재 swap되는 것과 **정확히 일치** → 동작 보존이 by-construction. `saved_*` 4필드 → `saved_screen: Screen` 한 개로, alt 전환이 `std.mem.swap(&self.screen, &self.saved_screen)` 한 줄이 된다(Scrollback 1단계의 자연스러운 확장 + Ghostty primary/alternate Screen과 동형). cursor·모드·scroll region은 core 잔류. rename ~285 내부 + grid 외부(cells 12·wrapped 1·prompt_marks 1). **위험 낮음~중**, "alt엔 스크롤백 없음"이 타입으로 보장되는 §"스크롤백 귀속"이 grid까지 확장.

**(B-full) cursor·모드까지** — `Screen = { grid, sb, cursor, pen, pending_wrap, last_print, scroll_top/bottom, origin_mode, autowrap, insert_mode, cursor_visible/shape/blink, view_offset, tabstops, semantic_state, … }`. architecture.md "cursor·grid 포함 완전한 Screen" 문언에 가장 충실. 하지만 현재 alt가 swap 안 하는 필드(scroll region·모드·tabstops)를 Screen에 넣고 swap하면 동작이 바뀌므로, alt enter/leave에 **명시적 reset 로직**을 추가해 현 동작을 재현해야 한다(순수 rename이 아님 — 의미 작업 추가). rename ~700+ 내부 + size 31 등 외부. **위험 높음**(동작 보존 검증이 alt 전환 엣지까지 넓어짐).

> 공통: parser 상태(parser·csi_*·osc_*…)·host-reply(response·clipboard·notification·shell_events)·selection(anchor/head)·kitty(images/placements)·터미널 모드(mouse·bracketed_paste·focus_events·kitty_flags…)·config/metrics(cell_*_px·palette·default_*)·alt_active(swap 상태 자체)·reflow scratch는 화면 content가 아니라 **core 잔류**. IME preedit은 core가 아니라 `Surface` client-local projection이다. `size`(두 화면 공유 geometry)·`dirty`(렌더 추적)는 B-min에선 core 잔류, B-full에서도 공유라 core 권장.

### 10.3 마이그레이션 전략 (staging)

필드-fold는 필드별 atomic(한 필드를 옮기면 그 필드 접근 전부 동시 변경)이지만 **그룹 단위로 incremental** 가능 — 각 PR이 한 필드 그룹을 `screen`에 넣고 접근부 전수 rename, 매 PR 4종 게이트 green. 빅뱅(단일 거대 PR)은 리뷰·머지 충돌 위험이 커 지양.

- **B-min**: ① `Screen` struct 신설 + grid(cells·wrapped·prompt_marks) fold → `self.screen.cells` (~169 rename) → ② `sb` fold → `self.screen.sb` (~116) → ③ `saved_*` → `saved_screen: Screen` + alt swap을 struct swap으로(의미 보존) → ④ 외부 접근부(renderer/app 테스트·surface/host) rename. 4 PR.
- **B-full**(B-min 후 선택): cursor·print state·scroll region·모드를 그룹별로 추가 fold + alt enter/leave reset 로직. 별도 다회 PR.

### 10.4 위험·정직한 평가

- **직접 payoff는 조직화**(평평한 ~60 필드 → screen 그룹핑)와 alt-swap 단순화. **page-aligned storage**(다중 page 스크롤백, Ghostty식)라는 진짜 이득은 이 fold가 **가능하게 만들 뿐**, 그 자체는 별도 후속 initiative다.
- 순수 rename이라 버그 위험은 낮지만(컴파일러+테스트), **churn이 크다** — 동시 진행되는 terminal 작업과 머지 충돌이 잦을 수 있어 집중 스프린트로 처리 권장.
- B-full의 alt enter/leave reset은 유일한 비-기계적 부분 — 동작 보존 검증(alt 전환·DECSC·scroll region)이 필요.

### 10.5 결정 — B-min 채택 (확정)

사용자와 합의해 **B-min을 먼저, 이어서 B-full까지** 진행한다(2단계 종착지 = "cursor·grid 완전한 Screen"). B-min은 scope 축소가 아니라 ~870 rename + alt-swap 의미 변경을 한 번에 하지 않으려는 **안전한 1단계**다 — 동작 보존이 by-construction인 grid+sb를 먼저 굳히고, 그 위에 cursor·모드를 얹는다.

- **B-min**(B1~B3): `Screen = { cells, wrapped, prompt_marks, sb }`(현 alt-swap 대상과 정확히 일치). `Screen` struct는 self-contained(types + Scrollback, TerminalCore 미참조)라 screen.zig 소유 + core가 `const Screen = screen.Screen`·`screen: Screen` 필드(Scrollback 선례 동형).
- **B-full**(B4~, 확정 후속): cursor·pen·pending_wrap·last_print·scroll_top/bottom·origin_mode·autowrap·insert_mode·cursor_visible/shape/blink·view_offset·tabstops·semantic_state를 그룹별로 Screen에 흡수. alt enter/leave에 현 동작 재현 reset 로직 추가(비-기계적 — 동작 보존 검증이 alt 전환·DECSC·scroll region까지). size·dirty는 공유라 core 잔류.

| PR | 범위 | rename | 위험 |
|---|---|---|---|
| **B1** ✅ | `Screen` struct 신설(grid: cells·wrapped·prompt_marks) + fold → `self.screen.cells/wrapped/prompt_marks`. 내부·외부 접근 전수 rename(컴파일러 강제) | 내부 169 + 외부 238(테스트 다수) | 중 |
| **B2** ✅ | `sb`를 Screen에 추가 + fold → `self.screen.sb` | 내부 93(외부 0 — sb는 terminal-internal). primary cap default는 init `.screen = .{ … .sb = .{ .cap = default_max_scrollback } }`로 이동 | 중 |
| **B3** ✅ | `saved_cells`/`saved_wrapped`/`saved_prompt_marks`/`saved_sb` → `saved_screen: Screen`, alt enter/leave를 `saved_screen = screen`/`screen = saved_screen` struct 교환으로(의미 보존). **B-min 완결** | 28 + resize-during-alt·deinit·setMaxScrollback | 중 |

검증·리뷰는 §5 그대로(매 PR 4종 게이트 green auto-merge + 마지막 `/code-review max`). 외부 접근 rename은 해당 필드 fold PR에 포함(컴파일러가 내부·외부 동시 강제). 머지 충돌 최소화 위해 연속 처리.

> **B-min(B1~B3) 완결**: 활성 화면 grid+scrollback이 `screen: Screen`으로, alt 보관분이 `saved_screen: Screen`으로 묶였다. alt 전환은 `self.screen ↔ self.saved_screen` 통째 교환 한 번 — "alt엔 스크롤백 없음"이 grid까지 타입으로 보장. 동작 불변(289 테스트 — alt 전환·DECSC·resize-during-alt·스크롤백 보존). 다음: **B-full**(cursor·pen·print·scroll region·모드 흡수, B4~).

### 10.6 전체 로드맵 — B-full은 종착지가 아니다

architecture.md §211 종착지 = "cursor·grid 완전한 Screen **+ 그 자리에 page-aligned storage**". 따라서:

1. **Direction A**(함수 추출, §5~§9) ✅ 완료.
2. **Direction B**(Screen struct fold): B-min(B1~B3) → **B-full = Option 3**(B4~B6, **per-screen cursor**, §10.8). 레퍼런스 정정으로 범위가 cursor 클러스터로 좁혀짐(scroll/모드는 global 유지). ← 이 분해 initiative의 마무리이자 **첫 의도적 동작 변경**.
3. **page-aligned storage**(§11, 별도 initiative): 평평한 `cells: []Cell` + Scrollback ring → Ghostty PageList식 page-pool 레이아웃. **architecture.md의 진짜 최종 골**이고, B-full이 이를 가능하게 하는 전제다.

**성격 차이 — 셋의 동작 보존 등급이 다르다**: Direction A·B-min은 순수 리팩터(동작·메모리 레이아웃 불변, 위치만 이동 → 매번 "정확성 버그 0"). **B-full(=§10.8 Option 3)은 의도적 동작 변경**(cursor를 화면에 귀속 → alt 전환 의미가 바뀜)이라 "정확성 버그 0"이 아니라 **"의도한 동작 변경 + 테스트로 핀"**이 기준이다. page storage(§11)는 **메모리 레이아웃·할당·성능 변경**이라 또 별개(perf 예산 검증). B-full → §11 순으로, 각자 doc-first.

### 10.7 B-min 리뷰 cleanup (B1~B3 `/code-review max` 후속)

누적 리뷰(B3 alt-swap 심층 감사 + 전수 rename 검증 + cleanup) 결과 **정확성 버그 0**: B3 struct swap이 baseline과 byte-for-byte 동작 일치(enter/leave/resize-during-alt/deinit/setMaxScrollback·소유권·leak 안전), rename 누락 repo-wide 0, B2 cap-0 회귀 없음(init만이 생성 경로), 289 테스트 green. cleanup 4건만 정리: 죽은 `const Scrollback` 별칭+stale doc 제거(sb/saved_sb가 Screen으로 흡수돼 core에 Scrollback 타입 필드 없음), `enterAltScreen` 헤더 doc을 struct-swap 모델로 갱신, semantic_state breadcrumb 빈 줄 분리.

### 10.8 B-full = Option 3 — cursor를 화면에 귀속(per-screen cursor, 의도적 동작 변경)

**결정**: B-full을 Ghostty식 **per-screen cursor 모델**로 진행한다(사용자 합의 — "옵션3으로 바로"). architecture.md §211 "cursor·grid 완전한 Screen"의 직접 구현이고, alt 전환이 cursor까지 포함한 **통째 swap**이 되어 현재의 흩어진 carry+DECSC-복원+선택 reset 로직이 사라진다. **순수 리팩터가 아니라 의도된 동작 변경**이므로(§10.6 성격 차이) 검증 기준은 "동작 보존"이 아니라 "바뀐 동작을 테스트로 핀"이다.

#### 10.8.1 레퍼런스 근거 (read-reference-terminals-early)

Ghostty `Screen`은 `cursor: Cursor` + `saved_cursor: ?SavedCursor`를 **소유**(per-screen). 반면 `Terminal`(global)은 `tabstops`·`scrolling_region`·modes를 둔다. → **cursor 클러스터만 per-screen, scroll region·tabstops·모드는 global**.
결정적 함의: maru는 지금 scroll region·tabstops·모드를 alt-swap **안 함(carry)** = Ghostty의 global과 동치 → **이동 불필요, 동작 불변**. 즉 Option 3에서 실제로 바뀌는 건 **cursor 하나뿐**이고, B-full의 범위가 §10.2의 광의(scroll/모드 전부 흡수)에서 **cursor 클러스터로 좁혀진다**(레퍼런스가 정정).

#### 10.8.2 필드 멤버십

- **Screen += `{ cursor, pen, pending_wrap, last_print, last_printed_cp, saved_cursor: SavedCursor }`** — cursor 위치·pen·deferred-wrap·grapheme 연속 상태 + DECSC 슬롯. 모두 화면 content에 귀속되어 swap을 탄다.
- **core 잔류(global, Ghostty `Terminal`과 동형)**: `scroll_top/scroll_bottom`(scrolling_region)·`tabstops`·`origin_mode`·`autowrap`·`insert_mode`·`cursor_visible/shape/blink`(DECTCEM/DECSCUSR)·`view_offset`·`semantic_state`·모든 터미널 모드(mouse·bracketed_paste·focus_events·kitty_flags…). `size`(공유 geometry)·`dirty`(렌더 추적)도 잔류.
  - `view_offset`·`semantic_state`는 enter/leave가 이미 명시 리셋(현 동작 유지). `cursor_visible/shape/blink`의 per-screen화는 추가 동작 변경이라 **이번 범위 밖**(차후 검토 — 주석으로 명시).

#### 10.8.3 새 alt enter/leave 의미

- `enterAltScreen`: `saved_screen = screen`(primary cursor+DECSC 슬롯 통째 보관) → `screen = .{ 새 grid, cursor=home, pen=.{}, saved_cursor=.{} }`. **alt는 home cursor에서 시작**.
- `leaveAltScreen`: `screen = saved_screen`(primary cursor+DECSC 슬롯 통째 복원).
- 모드 매핑: **47·1047·1049** → `enterAltScreen()`/`leaveAltScreen()`(save_cursor 플래그 제거 — cursor가 swap에 흡수). **1048** → `saveCursorState()`/`restoreCursorState()`(화면 전환 없이 현 screen의 `saved_cursor` 슬롯). **DECSC ESC 7/8·CSI s/u** → 동일 슬롯.

#### 10.8.4 의도적 동작 변경 목록 (document-basis-and-decision)

| # | 변경 | 베이스·근거 |
|---|------|------------|
| 1 | alt 진입 시 cursor가 **home(0,0)**에서 시작(현재: primary cursor carry) | per-screen 모델(Ghostty Screen.cursor 소유). TUI는 진입 직후 절대 이동 → 실사용 무영향 |
| 2 | alt 이탈 시 **항상** primary cursor 복원 — 1049뿐 아니라 **1047·47도**(현재: 1047은 복원 안 함) | cursor가 화면 귀속이면 1047/1049의 save/restore 구분이 소멸. xterm 1047(no-save)은 단일-cursor 모델 유물 |
| 3 | 1049h가 primary **DECSC 슬롯을 덮어쓰지 않음**(현 deviation 수정) | 현재 1049h는 live cursor를 `saved_cursor_primary`(=primary DECSC 슬롯)에 써 셸 선행 ESC7을 클로버. swap은 cursor를 DECSC 슬롯과 분리 보관 → 셸 ESC7 생존(xterm "separate private slot" 의도 부합) |
| 4 | (엣지) 이미 alt에서 1049h / 이미 primary에서 1049l → no-op(현재: 방어적 save/restore) | swap 대상 부재. pathological, 문서화만 |

#### 10.8.5 PR 분해

- **B4**: cursor 클러스터(`cursor`·`pen`·`pending_wrap`·`last_print`·`last_printed_cp`)를 Screen으로 fold + enter/leave를 cursor 포함 swap으로. 47/1047/1049의 save_cursor 흡수(플래그 제거). `saved_cursor_primary/alt`는 **일단 core 잔류**(1048/DECSC가 `alt_active`로 슬롯 선택 — 사실상 per-screen). **+ per-screen cursor 동작 테스트 다수**(§10.8.6).
- **B5**: `saved_cursor_primary`/`saved_cursor_alt` → per-Screen `saved_cursor`(DECSC 슬롯도 swap을 탐). `activeSavedCursor` → `&self.screen.saved_cursor`(플래그 선택 → swap 선택, 등가). **+ per-screen DECSC 테스트**.
- **B6**: 누적 `/code-review max`(B4~B5 배치) + cleanup.

#### 10.8.6 테스트 계획 (heavy — 동작 변경 방어, 사용자 요청)

B4(필수):
1. alt 진입 직후 `cursor == (0,0)` (변경된 동작 #1)
2. primary cursor (r,c) → 1049h → alt home → alt 이동 (r2,c2) → 1049l → primary (r,c) 복원
3. **1047(47)** 진입/이탈도 primary cursor 복원 (변경된 동작 #2)
4. alt 안에서 SGR/pen 변경·pending_wrap·last_print 설정 → 1049l 후 primary의 pen/wrap/last_print 불변(화면별 독립)
5. 셸 ESC7(r5) → 1049h/이동/1049l → 셸 ESC8 → r5 복원 (수정된 동작 #3 — 회귀 가드)
6. resize-during-alt: `saved_screen.cursor`도 clamp(행/열 축소)
7. nested 1049h(이미 alt) no-op 안전; 1049l-while-primary no-op 안전 (엣지 #4)
8. deferred autowrap 상태(줄 끝 pending_wrap)에서 alt 왕복 후 primary wrap 동작 정상

B5(필수, 위 전부 유지 + DECSC 슬롯 per-screen):
9. alt 안 ESC7/8(DECSC)이 primary 슬롯 불간섭; primary ESC7/8이 alt 슬롯 불간섭(swap 경유로 동일 보장)
10. CSI s/u(SCO save/restore)도 현 화면 슬롯 사용

### 10.8.7 B4~B5 리뷰 cleanup (`/code-review max` 후속, B6)

누적 리뷰(라인별·removed-behavior·cross-file/state·Zig pitfall·cleanup/altitude/conventions 6각 + verify/sweep) 결과 **정확성 버그 0**(crash-class 0): per-screen 커서/슬롯 swap이 모든 경로(1049/1047/47·이미-alt·이미-primary·DECSC·CSI s/u·resize-during-alt)에서 의도대로 동작, flat 필드 잔존 0(전 트리 grep), 레이아웃 cycle 없음(TerminalCore→Screen→SavedCursor→primitives 종료), snapshot/serialize/render/IME 모두 활성 `self.screen.cursor`만 읽음. 유일한 실버그였던 "resize-during-alt가 보관 primary 커서 미clamp → 복귀 시 OOB"는 **B4 구현 중 발견·동PR 수정+테스트**됐다(리뷰가 재확인).

cleanup 2건만 정리(B6):

1. **resize alt 분기 중복 → `clampScreenCursorForResize(s, size)` 헬퍼**: 활성·보관 두 화면에 같은 5연산(커서·DECSC 슬롯 clamp + pending_wrap/last_print 무효화)을 손으로 복제하던 것을 swap 단위(Screen) 한 헬퍼로 묶어 drift 위험 제거(altitude — 두 블록이 어긋나면 OOB-after-leave 버그 재발).
2. **`activeSavedCursor` 인라인**: B5가 `alt_active` 분기를 없애 `&self.screen.saved_cursor` 한 줄 래퍼만 남았고 doc 주석이 사라진 분기를 재정당화 → `saveCursorState`/`restoreCursorState`에 직접 접근 + 근거를 `saveCursorState` 주석으로 이관, 함수 제거.

**후속 발견 → ✅ 해결**: RIS(`ESC c`)가 DECSC 슬롯(`screen.saved_cursor`)을 안 비우던 기존 동작(B4/B5 이전부터 — 평평 슬롯 시절에도 미초기화, 분해가 도입한 게 아님)을 별도 fix PR로 정합성 수정했다(베이스 VT100 RIS + Ghostty `Screen.reset()` saved_cursor=null, §6 참조). 사용자 합의 후 page storage 설계 전 area를 깨끗이 닫음.

---
