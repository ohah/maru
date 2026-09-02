# 여러 뷰 축 — 실측·선례·미결

한 문서를 **여러 뷰로 보는 축**의 검토 기록이다. 세 항목을 함께 다룬다 — 「같은 파일 두 곳 보기」
(계약: [layering §2.4](../native-editor-layering.md)) · **3-way 병합 편집기**(계약 없음) ·
**Split in Group**(계약 없음). 셋 다 *"한 화면에 편집기가 둘 이상"*이라는 같은 인프라 물음을 공유한다.

**이 문서는 계약이 아니라 실측·선례의 원장이다.** 계약의 단일 출처는 각 항목의 소유 문서이고
(배치·분할 방향은 [tabs-splits-layout.md](../tabs-splits-layout.md), 불변식은
[file-panel.md](../file-panel.md) §1), 여기 적힌 것은 **그 계약들을 고치기 전에 재어 둔 값**이다.

**왜 별도 문서인가.** 2026-09-02 검토에서 §2.4 계약의 구멍 아홉과 구조 실측 서른둘이 나왔는데,
그 대부분이 §2.4·계획 문서 어디에도 적을 자리가 없었다(계약이 아니라 *"계약을 고치려면 무엇을
알아야 하는가"*이기 때문이다). 흩어 두면 다음 사람이 같은 측정을 다시 한다.

## 1. 결정 (2026-09-02 사용자)

**기본 편집 기능을 먼저 한다.** 아래 셋은 예정으로 적어 두고 지금 착수하지 않는다.

| 항목 | 상태 |
|---|---|
| 같은 파일 두 곳 보기 | 계약은 있음([layering §2.4](../native-editor-layering.md)) · **구멍 아홉이 열려 있음**(§2) |
| 3-way 병합 편집기 | **계약 없음** — 새로 써야 한다 |
| Split in Group | **계약 없음** · 선례는 있음(§5) |

## 2. §2.4 계약의 구멍 — 적대적 검증 (2026-09-02)

계약을 코드와 맞대어 아홉을 찾았다. **H4만 계약이 맞았다.**

### H1 — 「두 번째 Term 생성」만으로는 나란히 안 보인다 (치명적)

실측: `src/platform/macos/app_session.zig` — 렌더가 leaf마다 **활성 Term 하나만** 그린다.

```zig
const drawn = editor_ops.appendPaneFrame(self, lr.rect, lr.leaf.activeTerm()) orelse continue;
```

pane 안의 Term은 **탭**이다. 계약의 목적은 *"긴 파일의 위아래를 **나란히** 보는 것"*인데, 표는
*"두 번째 Term 생성"*만 적고 **어디에**를 안 적었다. 같은 pane에 만들면 탭이 겹쳐 하나만 보인다.

**배치는 §2.4가 답할 자리가 아니다** — [tabs-splits-layout.md](../tabs-splits-layout.md)가 탭·split
배치의 단일 출처다. §2.4는 자기 불변식조차 file-panel.md에 넘기는 규율을 지키고 있다.

### H2 — 「공유」 목록이 전부 Term 소유이고, 계약이 가리킨 소유자는 없다

계약의 「공유(문서가 하나다)」 = 버퍼·undo/redo·revision·dirty. 실측하면 **전부 `TermRuntime`**이다.

| 계약이 「공유」라 한 것 | 실제 사는 곳 |
|---|---|
| 버퍼 | `TermRuntime.editor_doc` (`Opened.file: edit_doc.EditableFile`) |
| dirty | 같은 `Opened`의 **clean 해시**(개정 번호가 아니라 내용 해시) |
| undo/redo | `TermRuntime.editor_undo`·`editor_undo_len`·`editor_redo`·`editor_redo_len` |
| 줄 배열 | `TermRuntime.editor_lines` |

수명도 Term에 묶여 있다 — `app_session/editor.zig`가 Term을 놓을 때 `if (term.rt.editor_doc) |*d|
d.deinit(self.allocator);` 한다.

**계약이 가리킨 소유자가 코드에 없다.** §2.4는 *"경로 → 문서 하나의 매핑은 [editor-surface.md](../editor-surface.md) §4의
app-global `DocumentRegistry`가 **이미 그 자리다**"*라고 적었는데, `DocumentRegistry`는 소스 전체에
**한 번도 안 나온다**. 그리고 소유 문서가 직접 못박는다:

> [editor-surface.md](../editor-surface.md) — *"제품 file capability 발급, editor bridge,
> **DocumentRegistry**, watcher, diff service는 **모두 미구현이다**."*

「이미 그 자리다」는 **역할의 소유**를 말한 것이지 존재를 말한 것이 아닌데, 슬라이스를 계획하는
사람은 있는 것으로 읽는다. 그리고 **수명 규칙**(뷰 둘이 참조하는 문서를 언제 놓는가 — 참조 계수인가,
마지막 뷰가 놓는가)은 아무 문서도 안 적었다.

### H3 — 「가장 최근에 활성이었던 뷰」를 고를 데이터가 없다

계약: *"「기존 Term 활성화」의 대상은 가장 최근에 활성이었던 뷰다. 여럿 중 임의로 고르면 사용자가
방금 보던 곳이 아닌 데로 튄다."*

실측: `TermRuntime`에 `last_active`·`activated_at` 류 필드가 **없다**. 규칙은 있는데 지킬 근거가 없다.

### H4 — 경로 → Term 조회 1:N (계약이 맞다)

계약이 *"그 조회를 쓰는 곳(열기 중복 판정·rename remap)은 전부 목록을 받도록 바꾼다"*고 했고,
실측한 프로덕션 호출자도 **둘**이다 — `app_session/pane.zig`(열기 중복 판정,
`fileTermForPath(self, path)` → `activateExistingFileTerm`)와 `app_session/file_panel.zig`.

### H5 — 「나눠서 보기」 명령이 없다

`split_editor`·`open_in_split` 류 action이 소스에 없다. action·chord·팔레트 행을 새로 만들어야 하고,
계약은 **이름만 적고 chord를 안 정했다**.

### H6 — 외부 변경·비교 뷰 구분이 없다

- 파일이 밖에서 바뀌면(watcher) 두 뷰를 어떻게 하는가. 문서가 하나라 갱신은 한 번이지만 **두 뷰의
  스크롤·선택**을 어떻게 할지는 별개다.
- 비교 Term은 `(경로, kind, base)` 키라 이 예외와 **다른 축**인데 그 구분이 §2.4에 없다.

### H7 — 상태바가 어느 쪽 선택을 말하는가

Maru는 `ItemId.editor_cursor`로 **선택이 있을 때 `줄:열`**을 낸다. 뷰가 둘이면 어느 쪽 값인지 정해야
하는데 계약에 없다. **선례는 답을 갖고 있다** — VSCode Split in Group은 *"상태바가 포커스를 가진
쪽의 선택을 반영한다"*(§5).

### H8 — 비교 뷰에서는 이 기능을 주지 않는다 (선례가 그렇게 한다)

VSCode Split in Group은 *"diff 편집기 같은 미지원 편집기에는 나타나지 않는다"*(§5). H6의 「비교 뷰
구분」에 선례가 답을 준 셈이고, 계약이 그것을 적으면 된다.

### H9 — 되돌리기(합치기) 명령이 없다

계약은 나누기만 적었다. 선례에는 **Join in Group**이 있다(§5). 되돌릴 길이 없으면 사용자는 탭을 닫아야
한다.

## 3. 구조 실측 — `TermRuntime`의 편집기 필드 64개

성격이 셋으로 갈린다. **이 분류가 §4의 비용 계산 근거다.**

| 성격 | 개수 | 필드 |
|---|---|---|
| **문서 상태**(파일당 하나 — H2가 옮겨야 할 것) | 약 12 | `editor_doc` · `editor_lines` · `editor_path` · `editor_syntax` · `editor_undo`/`_len` · `editor_redo`/`_len` · `editor_edit_group` · `editor_last_edit_kind`/`_ms` · `editor_tab_width` |
| **뷰 상태**(뷰마다 하나) | 약 35 | 세로 `editor_first_line`·`first_piece`·`max_top_line`·`max_top_piece`·`total_visual_rows`·`row_cache` / 가로 `first_col`·`max_cols` / 접힘 `fold_ranges`·`visible_lines`·`visible_numbers`·`fold_marks`(+len)·`folded_buf`(+len)·`syntax_folds_applied`·`folded_prev` / 선택·caret `selection`·`extra_selections`·`selection_marks`·`selection_mark_buf`·`caret_rows`·`caret_buf` / IME `preedit`·`preedit_at`·`auto_closed_at` / hit `hit_rows`(+len)·`hit_lines`·`hit_geom` / 스크롤바 `scrollbar`·`horizontal_scrollbar` / 찾기 `find_marks`·`find_mark_buf`·`find_reveal_pending` / `crumb_spans` · `wrap` |
| **비교 전용** | 약 13 | `editor_diff` · `editor_diff_selection` · `diff_marks_left`/`_right` · `diff_mark_buf_left`/`_right` · `diff_hit_rows_left`/`_right` · `diff_hit_len_left`/`_right` · `diff_hit_geom` · `scrollbar_right` · `horizontal_scrollbar_right` · `first_col_right` · `max_cols_right` |

부수 실측:

- **입력이 Term을 고르는 자리 약 50곳** — `activePane(self).activeTerm()` / `paneTargetAt`
  (`src/platform/macos/app_session/*.zig`, 테스트 제외).
- **pane 상한** `max_panes_per_tab = 1024` (`src/session/workspace.zig`). 「pane 무한 증식」은 사실이
  아니다.
- **방향 포커스가 이미 있다** — `app_session/pane.zig`의 `focusPaneInDirection`(⌥⌘←/→가 쓴다).
  「어느 pane이 옆인가」를 새로 만들 필요가 없다.

### 3.1 계약이 이미 정해 둔 판단 기준 (2026-09-01 열 포커스 조사에서 나옴)

이 축의 결정은 **저장소가 이미 문장으로 갖고 있다.** 새 기준을 지어낼 자리가 아니다.

- **[문서 모델](../native-editor-document-model.md)** — *"`side`(어느 열인가)는 selection 안에 없다.
  그것은 축이 아니라 「한 Term이 두 열을 든다」의 부산물이고, **뷰가 일급이 되면**(§2.4 같은 파일 두
  곳 보기) 사라질 필드다. 값을 **드는 쪽**이 든다."* — 즉 **§2.4가 서면 없어지는 필드들이 이미
  이름으로 예고돼 있다.**
- **[문서 모델](../native-editor-document-model.md)** — *"**결정적 근거는 생명주기다** … 생명주기가
  같은 것을 다른 곳에 두면 동기화 책임만 늘어난다."* 어떤 상태를 문서에 둘지 뷰에 둘지는 **이 기준
  하나로** 가른다.
- **[레이어 배치](../native-editor-layering.md)** — 뷰 상태의 정본 목록: **selection · caret · 스크롤 ·
  랩 토글 · 접힘 상태**. §3의 실측 분류가 이 목록을 코드로 확인한 것이다.

### 3.2 지금 「두 열」은 필드 짝으로 흉내 내고 있다

`_right` 접미로 손수 붙인 짝이 **열두 쌍**이다.

| 주인 | 짝 | 무엇 |
|---|---|---|
| `TermRuntime` | 6 | `editor_scrollbar_right` · `editor_horizontal_scrollbar_right` · `editor_first_col_right` · `editor_max_cols_right` · `editor_diff_hit_rows_right` · `editor_diff_hit_len_right` — **뷰** |
| `editor_diff.State` | 6 | `left/right_lines` · `_texts` · `_endings` · `_numbers` · `_marks` · `_bands` — **내용** |

**주인이 둘로 갈려 있고 수명이 다르다.** `editor_diff.invalidate`는 **State 구조체를 살린 채 내용만
비우고**(포인터로 잡아 필드를 `&.{}`로), 그와 함께 `editor_first_col`·`_right`·`max_cols`·`_right`·
`first_line`·`row_cache`·`editor_diff_selection`을 되돌린다. 즉 **내용은 버리고 뷰 축은 0으로 리셋하되
구조체는 산다.** 이 둘을 한 `Column` 구조체로 묶으려면 그 수명 차이를 먼저 정해야 하고, **세로는 짝이
아니라서**(공유) 그 구조체에 못 들어간다.

### 3.3 기존 포커스 개념 둘은 이 축에 재활용되지 않는다

- **`FocusOwner`**(`workspace` · `dock_pending` · `file_tree`) — **세션 수준**이다. 워크스페이스냐 파일
  트리냐 도크냐를 가르지, 편집기 안을 가르지 않는다.
- **`AppSession.InputFocus`**(`terminal`·`find`·`palette`·`settings` … 15종) — **저장하는 값이 아니라
  열린 오버레이에서 계산하는 값**이고, 답하는 물음이 *"어느 오버레이가 키를 갖나"*다. 편집기 안의
  「어느 뷰인가」는 그 `.terminal` **안쪽**이라 이 축과 층이 다르다.

즉 **뷰 포커스는 새 개념이다** — pane 분할 길에서는 `focusPaneInDirection`이 그 자리를 대신하고,
Split in Group 길에서는 새로 세워야 한다(§4).

## 4. 두 길의 비용 — pane 분할 vs Split in Group

| | **pane 분할** | **Split in Group형** |
|---|---|---|
| 뷰 상태 35개 | **공짜** — Term마다 이미 하나씩 | **둘로 만들어야 함**(최대 작업) |
| 문서 공유(H2) | **필요** — 12개를 Term에서 문서 객체로 | **불필요** — 한 Term = 문서 하나 |
| 포커스 | **공짜** — `focusPaneInDirection` | **새 축** |
| 입력 라우팅 | **공짜** — pane 단위로 이미 갈림 | 50곳이 *"Term 안 어느 뷰인가"*를 또 골라야 함 |
| 렌더 | **공짜** — leaf마다 `appendPaneFrame` | 분기 필요 |

**비교 뷰 기계는 Split in Group에 재활용되지 않는다.** 겹치는 것은 `diff_frame.columns()`(사각을 반
가르기)뿐이고 그것이 **가장 싼 조각**이다. 정작 필요한 넷을 안 준다:

| 두 뷰포트에 필요한 것 | 비교 뷰가 주는가 |
|---|---|
| 세로가 **각자** | **반대다** — [visual-mapping](../native-editor-visual-mapping.md)이 *"가로는 열마다 따로, **세로는 공유**"*로 **일부러** 묶었고, 실측해도 `editor_first_line_right`가 **없다** |
| 선택·caret 둘 | 없다 — `editor_diff_selection`이 **하나**뿐 |
| 편집 입력 라우팅 | 없다 — 비교 뷰는 **읽기 전용**(`editor_diff != null` 거절 27곳) |
| 접힘 각자 | 없다 — 비교에서는 접힘을 **거절**한다 |

**긴 파일의 위아래를 보려면 세로가 달라야 하는데, 비교 뷰는 세로를 같게 하려고 만든 것이다.**

## 5. 선례 실측 (2026-09-02 — 웹 출처)

**clean-room**: 동작·설정 이름·화면 구성만 확인했고 코드 표현은 보지 않았다.

### 5.1 VSCode — 같은 파일 두 곳 보기의 길이 **둘**이다

| | 무엇 | 방향 |
|---|---|---|
| **Split Editor** | **새 editor group** 생성 | 기본 `right`(좌우). `workbench.editor.openSideBySideDirection: down`으로 상하 |
| **Split in Group** | **그룹을 안 늘리고** 한 탭 안에서 둘로 | `workbench.editor.splitInGroupLayout` 설정 + 분할 툴바 액션으로 토글 |

Split in Group의 확인된 동작(마이크로소프트 이슈 #133756):

- 명령 위치: **탭 컨텍스트 메뉴 · View 메뉴 · F1 팔레트**
- **Join in Group** — 다시 하나로 합치는 짝 명령
- **뷰 상태(스크롤 위치·선택)가 양쪽에 각각 보존된다** — Maru §2.4의 「독립」 목록과 일치
- **상태바는 포커스를 가진 쪽의 선택을 반영한다** (→ H7)
- **diff 편집기 같은 미지원 편집기에는 나타나지 않는다** (→ H8)

**같은 그룹에 같은 파일 탭을 둘 두는 것은 out-of-scope로 닫혔다**(이슈 #41289). 요청 동기가 우리
것과 같았다 — *"현재 뷰를 복제해 다른 곳으로 스크롤하고, 돌아갈 땐 탭을 닫는다."* 그 자리를
Split in Group이 대신했다.

**모델은 공유된다** — 같은 인스턴스의 여러 뷰가 같은 메모리 문서를 참조해 저장 안 한 편집도 즉시
동기화된다. Maru §2.4의 「공유」 결정과 같은 방향이다.

### 5.2 VSCode — 3-way 병합 편집기 (한 탭에 편집기 **넷**)

VSCode 1.69(2022-06)에 들어갔고, **충돌 마커가 있는 파일을 열면 자동으로** 뜬다.

| pane | 무엇 |
|---|---|
| **Incoming**(왼쪽) | 병합해 오는 브랜치의 변경 |
| **Current**(오른쪽) | 지금 브랜치의 변경 |
| **Result**(아래) | 저장될 결과 — **편집 가능** |
| **Base**(선택) | 양쪽이 고치기 전 원본 |

- 충돌마다 **체크박스**가 붙고, CodeLens로 **Accept Incoming / Accept Current / Accept Combination
  (양쪽을 합침) / Ignore**를 고른다
- Result는 커서를 놓고 **직접 편집**할 수 있다
- **Complete Merge**를 누르면 스테이지하고 편집기를 닫는다

**대안(더 단순한 길): 인라인 충돌 마커.** 충돌 파일을 평범하게 열면 `<<<<<<< HEAD` / `=======` /
`>>>>>>> branch`가 강조되고, 그 자리에 **Accept Current Change · Accept Incoming Change · Accept
Both Changes** CodeLens가 붙는다. 손으로 마커를 지우고 고쳐도 된다. **간단한 충돌에는 이쪽이 빠르고,
복잡한 것에는 3-way가 낫다**는 것이 문서의 서술이다.

### 5.3 비교 편집기는 **2 pane 하드 리밋**

VSCode의 diff 편집기는 정확히 두 pane으로 만들어져 있고 설정으로 바꿀 수 없다.

### 5.4 출처

- [User interface — VS Code Docs](https://code.visualstudio.com/docs/editing/userinterface)
- [Resolve merge conflicts in VS Code](https://code.visualstudio.com/docs/sourcecontrol/merge-conflicts)
- [microsoft/vscode#133756 — split an editor into 2 without creating a second editor group](https://github.com/microsoft/vscode/issues/133756)
- [microsoft/vscode#41289 — same file in multiple editors of the same group (out-of-scope)](https://github.com/microsoft/vscode/issues/41289)
- [How to Compare Two Files in VS Code (Built-In Diff)](https://tms-outsource.com/blog/posts/how-to-compare-two-files-in-vscode/)

## 6. Maru에 병합 편집기의 자리가 이미 반쯤 있다

- SCM 패널의 **충돌 행**이 이미 있고, `app_session/git.zig`가 그 행에 `DiffBase.conflict`를 붙여
  비교를 연다.
- 그런데 **비교 뷰는 읽기 전용**이라(§4) 그 화면에서 충돌을 고칠 수 없다 — 사용자는 같은 파일을
  **다른 편집기 탭으로 따로 열어** `<<<<<<<` 마커를 손으로 지워야 한다.
- **계획 문서에 병합 편집기·충돌 해결 항목이 없다**(`docs/` 전체에서 `3-way`는 전부 터미널 적합성
  오라클 서술이다).

**그래서 인라인 방식(§5.2 후단)이 가장 작은 중간 단계다** — pane을 여럿 만들 필요도, 계약을 새로 세울
필요도 없이 *"충돌 해결이 앱 안에서 닫힌다"*를 이룬다. 선행은 **충돌 파일을 편집 가능하게 여는 것**
하나다.

## 7. 이 검토에서 틀렸던 판단 (기록)

**남기는 이유**: 같은 근거로 같은 결론을 다시 내지 않기 위해서다. **여덟 중 일곱이 *"측정 전에 말한
것"***이고, 나머지 하나는 소유권을 안 본 것이다.

| 틀린 판단 | 무엇이 반증했나 |
|---|---|
| *"VSCode·Zed가 하는 것도 이것이다(Split Editor)"* | 근거 없이 기억으로 말했다. 실제로는 **길이 둘**이고(§5.1) 저장소에 레퍼런스 소스가 없다(`references/`는 `.gitignore`) |
| *"좌우(세로 분할)가 자연스럽다"* | ⑴ 이 저장소는 `⌘D`=**좌우 분할**(`split_horizontal`)이라 괄호가 **반대**였다([tabs-splits-layout.md](../tabs-splits-layout.md), 코드도 `.horizontal => .vertical_line`). ⑵ 선례도 방향을 **설정으로 넘긴다** — "자연스럽다"고 단정할 근거가 없다 |
| *"같은 pane에 탭으로 두는 안이 구현이 가장 작다"* | 세 안의 차이는 몇 줄이고 **작업의 대부분은 H2**다. 크기를 변별점처럼 제시한 것이 오도였다 |
| *"pane이 무한으로 늘어난다"* | 상한 `max_panes_per_tab = 1024`가 있다. 진짜 물음은 *"「나눠서 보기」를 두 번 누르면 세 번째 뷰가 생기나"*였고 그것은 배치와 **독립**이며 계약에 없다 |
| *"어느 pane이 옆인지 애매하다"* | `focusPaneInDirection`이 이미 방향을 답한다 |
| *"열 포커스는 상주 축(a′)으로 세우는 것이 계약이 가리키는 방향이다"* | **두 번 뒤집혔다.** 계약이 정반대를 적어 뒀다(§3.1 — *"축이 아니라 부산물"*·*"값을 드는 쪽이 든다"*), 그리고 판단 기준(*"결정적 근거는 생명주기다"*)을 대자 답이 다시 갈렸다. **소유 문서를 읽기 전에 추천을 낸 것**이 원인이다 |
| *"Split in Group형이 Maru에 기계가 있는 유일한 안이다"* | **틀렸다.** `columns()` 하나만 보고 말했고, 비교 뷰가 **세로를 일부러 공유**한다는 정반대 사실을 안 봤다(§4) |
| 배치·분할 방향을 §2.4에 적으려 한 것 | **소유권 위반.** [tabs-splits-layout.md](../tabs-splits-layout.md)가 탭·split 배치의 단일 출처다 |

### 7.1 이 문서를 쓰면서 잡힌 함정

**`docs/plans/` 안에서 상대 경로는 `plans/` 쪽으로 먼저 풀린다.** 본문에 `editor-surface.md §4`라고
적었더니 `check-doc-links`가 *"절이 그 문서에 없다"*로 잡았다 — `docs/plans/editor-surface.md`가
**따로 있어서** 그쪽으로 풀렸기 때문이다. 같은 이름의 문서가 `docs/`와 `docs/plans/` 양쪽에 있는
경우가 여럿이므로(`editor-surface`·`native-editor`·`scroll-area`·`web-panel`·`workspace-restore`…),
**이 디렉터리에서는 `../`를 붙인 링크 형태로 적는다.**

## 8. 미결 — 착수할 때 답해야 할 것

**§2.4(layering)가 답할 것**: H2(공유 상태의 소유자와 **수명 규칙**) · H3(MRU 근거 필드) ·
H6(외부 변경 시 두 뷰의 스크롤·선택, 비교 Term 구분) · H7(상태바가 어느 쪽) · H9(되돌리기).

**[tabs-splits-layout.md](../tabs-splits-layout.md)가 답할 것**: 두 번째 뷰의 **배치**(pane을 쪼개는가,
이미 쪼개진 곳에 넣는가) · **분할 방향**(좌우/상하, 설정으로 열 것인가) · **두 번 누르면 어떻게
되는가**.

**[file-panel.md](../file-panel.md) §1이 답할 것**: 「파일 1개 = 창당 Term 1개」 불변식 문구의 갱신
(§2.4가 *"그 문서가 소유자"*라고 명시했다).

**병합 편집기**: 계약이 없다. 착수하면 §5.2를 선례로 두고 새로 쓴다 — 그때 요구는 이 문서가 잰
것보다 **크다**(뷰 3~4개 · Result가 편집 가능 · 배치가 2차원).
