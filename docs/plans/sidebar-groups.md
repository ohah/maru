# 사이드바 그룹 단계 분해 (§9)

SG1~SG8의 단계 분해와 완료 이력이다. 계약은 [사이드바 그룹](../sidebar-groups.md)과 그 절별 소유 문서가 가지고, 이 문서는 그 계약을 어떤 순서로 구현했는지만 소유한다.

> **절 번호는 파일을 넘어 이어진다.** 본문이 `§12.5`처럼 절만 가리키면 아래에서 소유 파일을 찾는다 — §1~§8·§10·§11 [sidebar-groups.md](../sidebar-groups.md) · §9 [단계 분해](../sidebar-groups.md) · §12~§13 [그룹 고정과 로컬 pin](../sidebar-groups-pinning.md) · §14 [top_level 재설계](../sidebar-groups-top-level.md)

## 9. 단계 분해 — 각 단계 독립 동작·green

근본 모델(§2.2 Row 투영)을 **먼저** 깔고, 그 위에 그룹을 얹는다. 모델 이주는 동작 보존(그룹 0개면 현재와 동일)이라 위험이 낮다.

1. **SG1 — chrome Row 토대(동작 보존, 그룹 없음) ✅**: `sidebar.zig`를 `Tab`→`Row` union(card+group_header)으로
   일반화 — hit-test(`slotAt`/`dragTargetSlot`, count=row 수)·`view`가 row 위에서 균일 동작하고, host(`sidebarRows`)가
   `Row.card`를 공급한다(헤드리스 테스트: 헤더가 섞여도 카드 밴드만·슬롯=row 인덱스 유지). app_session 내부
   `sidebar_visible_tabs` → `sidebar_rows` **완전 격상은 헤더가 실제로 필요한 SG3로 미룬다**(카드만일 땐
   `sidebar_visible_tabs`로 충분 — YAGNI, 각 단계 green). 순수 리팩터라 검색·재정렬·스크롤 동작 그대로.
2. **SG2 — 데이터·직렬화 ✅**: `Tab.group_start`/`group_collapsed`(session_model + workspace 모델) + workspace.v1
   `group-start`/`group-collapsed` 스칼라(순수 additive) + 캡처/복원 변환(owned dup·errdefer·deinit free) +
   round-trip·하위호환·leak 테스트. 렌더는 아직 안 붙임(모델만).
3. **SG3 — sidebar_rows 격상 + 가변 높이 + 헤더 렌더 + 접기 + 만들기/이름/해제** (가변 높이라 커서 하위 분할):
   - **SG3a — sidebar_rows 격상 + 가변 프리미티브(그룹 없이 동작 보존) ✅**: app_session `sidebar_visible_tabs` →
     `sidebar_rows: []Row` 완전 격상(`recomputeVisibleTabs`가 `Row.card` 채움; `visibleTab`/`displaySlotOf`·rebuild
     tint/accent·glyph 조립·⌘숫자 배지·`anyAgentRunning`을 row switch로 — 조사 맵의 "표시 슬롯 도메인" 전부). `sidebar.zig`에
     가변 누적 프리미티브(`rowHeight`/`rowTop`/`contentHeight`) 추가 + 헤드리스 테스트(**카드만이면 `rowTop`==옛 `slotTop`**로
     동작 보존 증명). **`slotAt`/`dragTargetSlot`의 가변 교체·`slotTop`→`rowTop` 전환·두 latent 버그(rename caret·드래그)
     교정은 헤더가 실제로 가변을 요구하는 SG3b로 미룬다**(헤더 없는 SG3a는 고정 hit-test로 카드만 처리 = 균일이라 동작 보존).
   - **SG3b — 헤더 row + 가변 hit-test + glyph 가변 인코딩** (완료 + SG3c로 묶인 잔여):
     - **SG3b-1 ✅**(머지 #1174): `slotAt`/`dragTargetSlot` 가변 교체 + `slotTop`→`rowTop` + rename caret 버그 교정.
     - **SG3b-2-i ✅**(머지 #1174): `projectRows`가 group_header row 삽입·카드 depth·접힘·빈 그룹 규칙·member_count.
     - **SG3b-2-ii**(카드 glyph 완료, 헤더 실제 렌더는 SG3c): (a) `header_row_h` 메트릭 배선 ✅ — `props.CellMetrics` +
       `AppSession` 필드 + `refreshCellMetrics` 계산 + `slotAt`/`dragTargetSlot`/`rowTop`(caret·배지) 4곳 alias 교체. (b) **인덱스
       도메인 통일** ✅ — glyph slot을 압축 카드 서수(`active_card_ord`/`close_card_ord`)로 일치(§10 함정). (c) 렌더 y 가변 ✅ —
       tint/accent를 `rowTop`, 스크롤을 `contentHeight`로(#4·#7), 드래그 row→tab 변환(#2). (d) `.m` 디코드 **옵션 2** ✅ —
       `applySidebarGlyphPyTop`이 py_top을 Zig `rowTop`+블록중앙으로 계산해 셀 `origin_y`에 싣고 `.m`은 `origin_y+header-scroll`만
       (code-review #1·3·5·6 해소). (e)(SG3c) `view` 헤더 밴드 `rowTop` + `buildSidebarDrawList` 헤더 삼각(▾/▸)+이름 glyph +
       `card.depth` 들여쓰기 + **헤더 label borrowed 해소**(`group_header`에 소스 tab 인덱스/dupe — 현재 `tab.group_start` borrow해
       destroyTab 후 dangling, **code-review #8 UAF 잠복**). (f)(SG3c) **macOS 제품 스크린샷 검증**(create_group으로 헤더가 실제 떠야 가능).
     **참고: `/code-review max`가 SG3b-2-ii 계획을 findings #1~7의 정확한 해소 경로로 confirmed 검증했고, #1~7은 (a)~(d)에서 전부 닫혔다.**
   - **SG3c ✅ — 접기 + 만들기/이름/해제 + 헤더 실제 렌더(SG3b-2-ii-(e)(f) 흡수)**: `sidebar.view`가 group_header 밴드를
     내고 **모든 밴드 y를 `rowTop` 누적**으로(`bandFill`이 rows+header_row_h 수령, `sidebarBandRow`가 가변 y→row 역산 —
     옛 `@divTrunc(y,slot_h)` 대체). `buildSidebarTitleDrawList`가 헤더 삼각(▾/▸)+이름(접힘 시 `(N)`)+카드 `group_indent`
     들여쓰기를 그리고 `fillSidebarGlyphPyTop`이 row별 높이로 블록중앙(glyph 도메인=표시 row 인덱스). 헤더 클릭 →
     `toggleGroupCollapsedAt`·헤더 더블클릭 rename. `create_group`(`Cmd+Opt+G`)·`ungroup`·`rename_group` 액션
     (action.zig+keybinding+command_catalog+dispatch) → 팔레트·설정 리바인더·config·우클릭 노출. closeTab 마커 승계.
     **code-review #8 해소**: `Row.group_header.tab`(소스 탭 인덱스)로 헤더 glyph가 `tab.group_start`를 **live** 읽어
     borrowed dangling 제거(접기 토글·rename 타깃 겸용). **제품 스크린샷 검증 완료**(펼침 `▾ 그룹 1`+얇은 밴드+들여쓴 활성
     카드·접힘 `▸ 그룹 1 (2)`, 가변 높이 정확 — `MARU_FORCE_GROUP` 헤드리스 훅). **여기까지가 "접기 우선" 완료.**
4. **SG4 ✅ — 카드 드래그 넣기/빼기**: `sidebarGroupDropTargetTab`(드롭 row→moveTab 목표 탭 매핑 단일 출처 —
   카드=그 위치, 펼친 헤더=그룹 최상단(방향 보정), 접힌 헤더=그룹 끝 `[M,j)` §10). 드래그 핸들러가 헤더 드롭도
   처리(옛 visibleTab null-skip 대체), `sidebar_drop_slot` 드롭 하이라이트. **마커 탭 드래그는 가드로 무동작**(그룹
   통째=SG5). 연속 파티션은 마커 없는 카드만 재정렬해 사실상 공짜. 헤드리스 2테스트(넣기/빼기·펼친/접힌 헤더·마커
   가드·재투영 depth). 한계: 핀+그룹 조합·카드→마커카드 위-드롭은 헤더 드롭이 신뢰 경로.
   - **접힌 헤더 드롭도 drag-direction 보정(code-review #2)**: 접힌 브랜치는 `from<m`이면 마지막 멤버 자리 `j-1`, `from>m`이면
     마커 뒤 마지막 자리 `min(j, len-1)`을 쓴다(펼친 헤더의 `from<m`→`m`/`from>m`→`m+1`과 같은 결). 옛 코드는 항상 `j-1`이라
     **marker-only 그룹**(`j==m+1` → `j-1==m`)에 `from>m` 드롭이 `moveTab(from, m)`으로 카드를 마커 **앞**에 떨궈 그룹 밖으로
     샜다 — 이제 두 방향 모두 마커 뒤(그룹 안)에 안착한다.
5. **SG5 — 그룹 통째 드래그·색·(선택)중첩**:
   - **SG5-1 ✅ — 그룹 통째 드래그**: 헤더를 잡아 드래그하면 그룹 구간 `[M,j)`(마커 탭 + 소속 카드)가 통째 이동.
     `moveGroupRange`(구간을 블록으로 그룹 경계에만 삽입 — 파티션 위반 불가능)·`sidebarGroupDropBoundary`(드롭 row→그룹
     경계, 항상 경계 clamp)·헤더 클릭 vs 드래그 threshold 구분(mouseDown arm→미달=접기·초과=이동). SG4의 마커 탭 가드를
     실제 이동으로 대체. 헤드리스 3테스트. 한계: 핀+그룹 조합·floating 미리보기(선택) 미구현.
   - **SG5-2 ✅ — 그룹 색**: 헤더·소속 카드 공통 색(브라우저 탭 그룹식). `Tab.group_color`(?u32→u32, 0=색 없음)를
     **그룹 시작 마커 탭 하나에만** 저장하고 소속 카드는 위치 파생으로 그 색을 따른다(별도 저장 없음, §2.1 동형). 나타나는 곳:
     (a) **헤더 밴드 tint** — `lowerSidebar`가 group_header 밴드(.tab_hover_bg) 색에 그룹 색을 **카드 배경 tint와 같은 blend
     경로·같은 알파**로 섞는다(층 분리 — 개별 카드 background_color와 다른 row라 안 겹침). (b) **소속 카드 좌측 accent 막대** —
     `rebuildSidebar` per-tab 루프가 순회 중 위 헤더의 색을 기억해 카드 막대에 싣는다. 막대 색 우선순위 = 개별 `accent_color` >
     그룹 색 > 활성 기본 accent > 없음(개별 지정이 그룹 색보다 명시적). 설정 = **카드 우클릭**과 **헤더 우클릭**(SG5-2-header)
     "그룹 색: …" 프리셋(카드 색과 같은 `tab_color_presets` 팔레트·`setGroupColorForTab`이 소속 그룹 마커에 세팅, 그룹 밖이면
     no-op). 헤더 우클릭은 `renameTargetAt`이 group_header row의 마커 탭을 `.group` 대상으로 잡고, `buildContextMenuItems`/
     `acceptContextMenu`의 `.group` 분기가 카드 메뉴와 **같은 색 라벨/dispatch**를 재사용한다(중복 최소·같은 색 메뉴 공유). 직렬화 = workspace.v1
     `group-color` 스칼라(비영만 group-start 블록에 쓰고 0=키 생략 — additive·round-trip 고정, 옛 리더 미지 키 skip으로 양쪽 호환).
     헤드리스: projectRows/렌더가 헤더 밴드·카드 막대에 그 색을 싣는지 gpu_quad 단언 + workspace.v1 round-trip + 색 없는 그룹
     기본 폴백. **제품 스크린샷 검증 완료**(`MARU_FORCE_GROUP_COLOR=1` — 헤더 밴드 파란 tint + 소속 카드 파란 막대·최상위 카드 무색).
   - **SG5-3 ✅ — 중첩 그룹(그룹 안 그룹, 폴더 트리)**: 위치 파생을 **다단계 depth로 일반화**한다. `Tab.group_depth: u8`
     (마커에만 의미, 1=최상위·2=중첩·…, 기본 1) 추가. `projectRows`를 **스택 기반 2패스**로 재작성 — pass1이 `self.tabs`를
     스택으로 훑어 각 탭의 **정규화 eff_depth**(마커 pop→`부모+1` gap 클램프, 카드=스택 top)와 검색 매치를 계산하고, pass2가
     마커 스택(접힘 조상 추적)으로 row를 순서대로 방출한다(자식 헤더가 부모 직접 카드 뒤·자식 카드 앞에 자연 삽입 = §2.1
     다단계 제약). 렌더: 카드·헤더 `depth`×/(`depth-1`)×`group_indent` 다단계 들여쓰기(`card.depth`·신규 `group_header.depth`).
     **member_count = 그 그룹 직접 카드 수**(중첩 자식 그룹 안 카드 제외 — 접힘 배지 `(N)`은 "이 그룹에 직접 든 워크스페이스 수").
     - **접기(다단계)**: 마커를 접으면 그 subtree(같거나 낮은 depth 마커 전까지의 깊은 카드·자식 헤더)를 전부 숨긴다. **부모
       접기 = 자식 그룹 통째 숨김**(조상 접힘이 헤더까지 가림), **자식만 접기 = 자식 카드만 숨김**(자식 헤더는 `▸ name (N)`로 남음).
     - **create_group 중첩 생성 + create_sibling_group 형제 생성(명시적 2액션)**: `create_group`은 그룹 **안** 카드에서 실행하면
       그 카드의 현재 depth+1로 자식 그룹 마커(중첩), 최상위에서는 depth 1. 위치 파생상 마커 뒤 형제 카드들은 새 그룹으로 흡수된다.
       첫 그룹이 리스트 끝까지 뻗는 연속 파티션이라 첫 그룹 뒤 카드는 모두 "그룹 안"이므로 create_group은 **항상 중첩**한다 —
       그래서 **`create_sibling_group`**(SG5-3)을 create_group과 **명시적으로 분리**해 둔다: 그 카드의 **현재 그룹과 같은 depth**로
       마커를 얹어(그 카드부터 현재 그룹에서 분할돼 형제로 시작) 형제 그룹을 만든다(최상위 카드면 depth 1 = create_group과 동일).
       둘은 `beginGroupForTab(kind)` 공유 미러이고 depth 계산만 다르다(중첩=현재+1, 형제=현재). 이로써 §10의 "형제 못 만듦"
       tension이 해소된다(중첩/형제를 사용자가 액션으로 명시 선택).
     - **ungroup(중첩)**: 그 탭의 **가장 가까운(innermost) 마커**를 해제한다. 자식 ungroup → 자식 카드가 부모로 재소속(한 단계
       얕아짐). 부모 ungroup → 부모 직접 카드는 최상위로, 남은 자식 그룹은 부모가 사라져 projectRows의 **gap 클램프로 depth 1
       (최상위 그룹)로 자동 승격**(저장 group_depth는 그대로 두고 투영이 정규화 — 위치 파생 철학과 동형).
     - **직렬화**: workspace.v1 `group-depth` 스칼라(additive·기본 1=키 생략→round-trip 고정·옛 리더 미지 키 skip으로 양쪽 호환).
     - **드래그(subtree 통째 이동)**: 그룹 통째 이동(`moveGroupRange`)·드롭 경계(`sidebarGroupDropBoundary`)·접힌 헤더 드롭이
       "다음 마커" 대신 **subtree 끝**(`groupSubtreeEnd`=같거나 낮은 depth 마커 전까지)을 쓴다 — 부모+자식이 함께 이동해 무결성
       유지(비중첩이면 "다음 마커"와 동일이라 SG4/SG5-1 동작 보존). **드롭 위치로 depth 변경(넣기/빼기)은 SG5-4에서 구현**한다.
     - **헤드리스 검증**: 2단계 중첩(A>B) depth 0/1/2·헤더 depth·member_count·부모 직접카드가 자식 앞·다단계 접기(부모/자식)·
       ungroup 재소속/승격·workspace.v1 group-depth round-trip. **스크린샷 훅** `MARU_FORCE_GROUP_NESTED`(+`_COLLAPSED`/`_COLOR`).
   - **SG5-4 ✅ — 드래그로 중첩 넣기/빼기(드롭 컨텍스트 depth로 group_depth 조정)**: SG5-3의 subtree 통째 이동에, **드롭 위치가
     가리키는 depth로 명시적으로 넣고/뺀다**. 그룹 드래그의 드롭 해석을 **헤더 드롭 vs 카드 드롭**으로 나눠(`groupDragFrame` 분기):
     - **다른 그룹 헤더에 드롭 = 그 그룹의 자식으로 중첩**(`groupNestPlan`→`moveGroupNesting`). target_depth=타겟 그룹 eff+1,
       insert_before=타겟 subtree 끝(=마지막 자식 자리라 "부모 직접 카드가 자식 앞" §2.1 유지). 이동만으로는 dragged 마커가 부모를
       pop해 형제가 되므로, `relevelBlock`이 subtree 마커들의 `group_depth`를 target 기준으로 **상대 유지**(dragged=target·자식은
       상대 offset 유지)로 다시 쓴다 — 이동+depth 조정을 함께 해야 진짜 자식이 된다.
     - **카드/최상위에 드롭 = 형제 경계 이동**(기존 `sidebarGroupDropBoundary`) + **빼기(un-nest)**: `moveGroupSibling`이 새 위치의
       자연 eff(gap-clamp된)로 relevel한다 — 같은 레벨이면 no-op(SG5-1 보존), 얕은 곳(최상위 등)이면 저장 depth를 eff로 낮춰 빼기가
       저장에도 반영(gap 제거). **카드 드롭=형제·헤더 드롭=넣기의 명시적 분리**라 SG5-1(카드 드롭에 형제 이동) 헤드리스가 그대로 통과.
     - **카드 드래그**: 위치 파생이 이미 드롭 위치의 depth를 흡수한다(자식 그룹 카드 위=자식 depth·최상위=0). 접힌 자식 헤더 드롭도
       `groupSubtreeEnd`로 그 자식 subtree 끝을 타겟(SG5-3에서 배선). 별도 depth 편집 없음.
     - **트리 연속·연속 파티션 유지**: 삽입은 항상 마커 경계(moveGroupRange), depth relevel은 블록을 고립 subtree로 정규화(1,2,3…
       연속)해 target 기준으로 remap하므로 gap·역전이 없다. projectRows 스택 워크가 재투영 시 유효 트리를 보장(gap-clamp).
     - **드롭 하이라이트**: `sidebar_drop_slot`이 드롭 row(넣기면 타겟 그룹 헤더)를 `.drop_zone` 밴드로 표시 — 헤더 밴드가 켜지면
       "이 그룹 안으로 넣기"를 뜻한다. **한계**: 목표 depth를 미리 들여쓰기로 보여주는 **비커밋 프리뷰는 고스트+삽입선(§10·SG7 결론)이라야 성립**한다(적대검증 결론) — 현재는 라이브 relevel이라 indent 자체는 이미 실시간이고, 미구현인 건 "커밋하지 않는" 프리뷰 시맨틱뿐이다.
     - **헤드리스 검증**: ①그룹을 다른 그룹 헤더에 드롭→중첩(depth+1, subtree 상대 depth C:1→2·2→3 유지) ②중첩 그룹을 최상위 카드에
       드롭→빼기(depth1, 저장 relevel) ③카드를 자식 그룹 안→자식 depth·최상위→0 ④mouse 통합(헤더→헤더 중첩). 매 케이스 depth·연속
       파티션·트리 연속 단언. **스크린샷 훅** `MARU_FORCE_GROUP_DRAGNEST`(A를 B 헤더에 드롭한 결과 = A가 B 자식으로 들여쓰기, 검증 완료).
6. **SG6 — 그룹 UX 조정(그룹에서 빼기 + 헤더 밴드 정책) ✅**: 사용자 요청 2건.
   - **그룹에서 빼기(remove_from_group)**: 카드 하나만 자기 그룹에서 빼 완전 최상위로 옮긴다(§7 표 "그룹에서 빼기" 행).
     `removeFromGroupForTab`이 그 카드를 첫 `group_start` 마커 직전(최상위 구간)으로 `moveTab`하고, 카드가 마커면 다음 소속
     카드로 마커를 승계(closeTab 동형)해 그룹을 살린다(마지막 멤버면 소멸). 이미 최상위면 no-op. `action.zig`(Action+parseAction)·
     `dispatchAppAction`·`command_catalog`("Remove from Group")·우클릭("그룹에서 빼기", `tabIsInGroup`으로 그룹 소속 카드에만
     주입)에 배선(ungroup의 미러 — ungroup=그룹 통째 해제 vs remove=카드 하나만). 기본 키 없음(저빈도, ungroup과 동일 결).
   - **헤더 밴드 정책(기본 보더라인 제거)**: §5 "헤더 밴드 정책" — 무색 헤더는 밴드 없이 화살표+이름만, 색 지정 헤더만 밴드
     (그 색 tint), hover/active는 카드와 같은 경로로 유지(`Row.group_header.has_color` 스위치, `view` 헤더 밴드 루프가 그 값 게이트).
     헤드리스로 무색=밴드 op 0·색=1·호버=호버 밴드 있음을 단언, `MARU_FORCE_GROUP`(무색 깔끔)·`_COLOR`(색 유지) 스크린샷 검증.
7. **SG7 — 드래그 depth 프리뷰**: 초안은 "작게"(순서는 이미 라이브니 **depth만** 시각 프리뷰 — relevel 없이·`?u8` 한 스칼라·
   싸게)였으나, **doc-first 적대검증 3회가 전제를 전부 반박**해 "작게"는 폐기한다. 발견(근거 코드는 app_session.zig):
   - **이미 라이브 relevel이다(잉여)**: SG5-4 그룹 드래그는 매 프레임 `groupDragFrame`(4214)→`moveGroupNesting`/`moveGroupSibling`
     →`relevelBlock`(4304)이 `group_depth`를 **즉시 커밋 + rebuild**한다 — 드래그 중 indent가 오늘도 라이브로 바뀐다. 별도 depth
     프리뷰는 잉여다("live 프리뷰 미구현"은 오해 — 미구현인 건 *비커밋 프리뷰 시맨틱*뿐).
   - **"relevel 없이"는 모순+과소명세**: relevel을 미루면 `recomputeVisibleTabs`가 그 위치를 **"형제"로 파생**(gap-clamp)하므로,
     프리뷰가 그 파생값을 능동적으로 **뒤엎어야** 한다(모순 주입). 대상도 한 row가 아니라 **subtree**(헤더+직속카드+자식)라
     `relevelBlock`의 스택 정규화를 렌더에서 재현해야 해 `?u8` 하나로 과소명세.
   - **비용 회피는 허구**: 매 프레임 `rebuildSidebar`(O(n) 재투영)는 그대로 낸다. 건너뛰는 `relevelBlock` write는 `changed` 가드까지
     있어 무시 가능한 절감이다.
   - **`sidebarGroupDropBoundary`는 depth를 안 낸다**: 경계 인덱스만 반환. 빼기 depth는 `moveGroupSibling`의 **post-move**
     `effectiveDepthAt` — 실제 이동 뒤에야 존재. 카드 드래그(SG4)는 depth 계산 자체가 없다(위치 파생). "이미 산출하니 재사용"은 틀렸다.
   - **접힌 그룹 사라짐은 relevel 무관**: 사라짐은 `recomputeVisibleTabs` pass2의 가시성 게이트(투영 효과, `anyCollapsedInStack`)라
     relevel을 생략해도 발생. depth 프리뷰가 가장 필요한 이 케이스에서 삽입 row가 아예 없어 **SG7은 no-op**.
   - **정작 거슬리는 이동 커밋(yo-yo)은 SG7이 안 건드린다**: "순서는 라이브 유지"라 헤더 통과 시 그룹이 실제로 들락날락하는 커밋은 그대로.

   **결론**: "작게"는 잉여이거나 사실상 §10 고스트 리팩터로 수렴한다. **의미 있는 depth 프리뷰 = 위치까지 비커밋 프리뷰 = 고스트+삽입선
   (§10)** 하나로 귀결(중첩=depth라 order/depth 분리는 category error). 유리한 사실 하나: depth를 읽는 렌더 경로는 `buildSidebarTitleDrawList`
   glyph indent 2곳(13884·13956)뿐이고 밴드·accent·hit-test·배지는 depth 무관 → **고스트 구현 시 override 표면 자체는 작다**. 착수 시점은
   접힌 그룹 사라짐·드래그 yo-yo가 실사용에서 거슬릴 때(§10 고스트 리팩터). 그 전엔 현행 라이브 재배치로 충분(depth가 이미 실시간 보임).
8. **SG8 — 고스트+삽입선 드래그 프리뷰(완료 ✅ SG8a~f)**: SG7 폐기 결론(§9-7)이 가리킨 하나의 리팩터 — 사이드바 드래그를
   **라이브 재배치**(매 프레임 `self.tabs` 커밋+relevel+rebuild)에서 **고스트+삽입선**(비커밋 프리뷰 + 드롭 **1회** 확정)으로 전환한다.
   접힌 그룹 드롭 시 카드가 순간 사라짐·헤더 통과 시 그룹이 들락날락하는 yo-yo가 실사용에 거슬릴 때 착수했다(그 트리거가 왔다).
   초안은 **적대검증 3회**를 거쳐 아래 보강이 확정됐고, SG8a~f로 전량 구현·검증됐다. **결과**: 카드·그룹 드래그가 드래그 내내
   `self.tabs` 불변(비커밋)이라 **접힌 그룹 드롭 시 카드 사라짐·헤더 통과 yo-yo가 근본 해결**되고(SG7/SG8 국소 프리뷰 폐기의
   귀결 — 의미 있는 depth 프리뷰는 "위치까지 비커밋 프리뷰=고스트+삽입선" 하나로 수렴), 목표 depth가 subtree 고스트 들여쓰기로
   드래그 중 정직하게 보인다. 남은 것은 cosmetic(하이라이트 밴드 높이 등)과 별도 축 후속(그룹 고정=핀+그룹 파티션)뿐이다.
   - **핵심 결정 A — 고스트 복제(스냅) + 삽입선**: 드래그 대상(카드=1행·그룹=subtree N행)을 목표 위치·depth로 **반투명 고스트**로
     그리고 그 상단에 얇은 삽입선을 얹는다. 삽입선 단독은 기각 — 이동단위가 subtree(SG5-4)라 점 하나로는 상대 depth를 못 보인다.
     고스트는 floating이 아니라 목표 정지(snap)로 둔다(위치·depth 전달이 목적). depth를 읽는 렌더는 `buildSidebarTitleDrawList`
     indent 2곳뿐이라 override 표면이 작다(§9-7).
   - **핵심 결정 B — projectRows 가상배치 + 렌더/hit-test 도메인 분리**: 드래그 중 `self.tabs`는 **불변**. 프리뷰 상태를
     가상배치로 재투영해 **두 투영**을 둔다 — `sidebar_rows`(원본, 불변, hit-test·drop 계산이 봄) vs `sidebar_preview_rows`(신규,
     고스트 포함, 렌더가 봄). "사라짐"은 pass2 가시성 게이트(`anyCollapsedInStack`)가 원인이라 렌더-레이어 단독으로는 못 고친다 —
     투영이 프리뷰 입력을 받아 고스트를 **강제 방출**해야 성립한다. reflow·depth·연속 파티션은 가상배치에서 pass1/pass2 재사용으로 공짜.
   - **row-count 모델 = move(순열)로 확정(초안 정정)**: 고스트는 "복제(행 증가)"가 **아니라** 원본을 목표로 이동한 **가상 순열
     배치**(그 행을 반투명으로)다. 따라서 `preview_rows.len == sidebar_rows.len`(접힘 게이트로 빠질 행은 프리뷰가 예외로 **되메워**
     길이를 맞춘다)이라 **스크롤 높이가 발산하지 않는다**(복제 모델의 콘텐츠 높이 증가·스크롤 clamp 흔들림이 원천 제거). 프리뷰는
     `projectRowsFrom(order, group_depth)`에 **가상 order/group_depth**를 넘긴 결과일 뿐 — SG8a에서 이 코어가 이미 order를 존중한다.
   - **등가 안전화(이중경로 divergence 방어)**: 프리뷰(비커밋)와 드롭(커밋)이 갈리는 유일 위험은 두 경로가 다른 결과를 내는 것이다.
     완화 순서 — (i) **순열/depth 순수 코어를 *먼저* 단일화**(SG8a `projectRowsFrom` = 프리뷰·확정 공유 토대, 완료), (ii) 헤드리스
     **등가 테스트**로 `simulateDrop`이 낸 order/depth == 실제 move 후 read를 고정, (iii) up(확정)에서 **재계산하지 말고** 마지막
     프리뷰 `plan`을 재사용해 기존 `moveTab`/`moveGroupNesting`/`moveGroupSibling`을 **정확히 1회** 호출. `clampMoveToGroup`(핀 경계)을
     그 순수 코어에 포함해 **프리뷰가 클램프 전 목표를 보이는 고스트-확정 불일치**를 없앤다(고스트가 핀 경계에서 정직하게 멈춘다).
   - **게이트/투영 정합**: 프리뷰 투영은 타겟 헤더를 `collapsed=false`로 뒤집어(접힌 그룹에 넣어도 고스트가 보이게) code-review #6
     류 "접힘 표시인데 카드 보임" 모순 재발을 막는다. `member_count`와 pass2 헬퍼 — `directCardCount`·`subtreeHasMatch`·
     `effectiveDepthAt`·`groupSubtreeEnd` — 는 **order-aware**여야 가상배치 위에서 옳게 파생된다(**SG8a에서 완료**).
   - **도메인 인덱스 분리**: `sidebar_drop_slot` 하이라이트는 **preview 도메인**으로 재기준화(렌더가 보는 preview_rows 인덱스).
     고스트 범위는 상태 배열(`ghost_mask: []bool`, 길이 정합이 함정)이 아니라 **`ghost_lo`/`ghost_hi` range로 파생**(preview_rows에서
     고스트가 앉는 연속 구간). 표시-슬롯을 읽는 **놓치기 쉬운 렌더 소비자**를 preview 도메인으로 함께 이주 — **⌘1-9 배지**(app_session.zig
     14799 근처)·**IME caret**(2077 근처). 이 둘을 빠뜨리면 고스트 중 엉뚱한 행에 배지/caret이 간다.
   - **UX 완결 — 드롭 시 자동펼침**: 접힌 그룹 안으로 드롭하면 확정 후 그 그룹을 자동으로 펼친다(`group_collapsed=false`) —
     "드래그 중 안 사라짐"(고스트가 해결)에 더해 "드롭 후 접힌 폴더 안으로 사라짐"까지 닫는다.
   - **핀 파티션 — clamp 코어 포함으로 해소**: 위 등가 안전화의 `clampMoveToGroup`을 순수 코어에 태워 프리뷰·확정이 같은 클램프를
     본다(핀 경계 드롭이 프리뷰에서도 정직). **그룹 고정(핀+그룹 조합의 파티션 무결성)은 별도 축 후속**으로 §10 백로그.
   - **프리뷰 상태 모델**:
     ```zig
     sidebar_drag_preview: ?SidebarDragPreview = null,
     sidebar_preview_rows: ArrayListUnmanaged(Row) = .empty, // 렌더 전용(고스트 포함)
     const SidebarDragPreview = struct {
         origin: usize,      // 원본 subtree 시작(카드=tab, 그룹=마커). self.tabs 불변이라 안정
         origin_len: usize,  // subtree 길이(카드=1, 그룹=groupSubtreeEnd(origin)-origin)
         plan: DropPlan,     // 매 프레임 원본 sidebar_rows hit-test로 재계산(마지막 값이 확정에 재사용)
         cursor_y: f64,
     };
     const DropPlan = union(enum) {
         card: struct { target_tab: usize },                            // SG4: moveTab
         group_sibling: struct { insert_before: usize },                // SG5-1 형제 + SG5-4 빼기: moveGroupSibling
         group_nest: struct { insert_before: usize, target_depth: u8 }, // SG5-4 넣기: moveGroupNesting
         none,
     };
     ```
     depth 맵은 저장하지 않는다 — `group_nest{target_depth}`만 들고, 자식 상대 depth는 가상 order에 `projectRowsFrom` pass1을
     재실행해 파생한다(relevel 재현이 아니라 동일 pass1을 가상순서에 적용).
   - **simulateDrop 순수 코어**: `fn simulateDrop(self, plan, arena) VirtualLayout`이 plan을 `self.tabs`에 **커밋하지 않고** 이동
     후 순열 `order`·`group_depth`·`ghost_lo`/`ghost_hi`를 반환한다. 프리뷰 = `simulateDrop(plan)` → `projectRowsFrom(vl.order,
     vl.group_depth)` → `sidebar_preview_rows`(고스트 [lo,hi) 구간은 가시성 게이트 예외로 강제 방출). 확정 = 마지막 plan으로 기존
     move 1회. **적대검증 정정**: `surface_ptrs`/`active_tab`은 **divergence가 아니다** — `reorderTabs`가 활성 `*Tab` 포인터를
     추적해 새 인덱스로 보정하고 `surface_ptrs.items`는 `app_window.tabs`와 같은 backing이라, 순서/depth만 다루는 `simulateDrop`은
     포인터 셔플을 건드릴 필요가 없다(포인터 재배열은 확정 경로 `moveTab`/`moveGroupRange`에만 남는다).
   - **렌더 통합(모두 preview_rows를 봐야 함, 정합 핵심)**: 밴드(`view`)·glyph(`buildSidebarTitleDrawList`)·py_top/스크롤
     (`fillSidebarGlyphPyTop`·`contentHeight`)·accent/tint 순회가 드래그 중 **preview_rows**를 본다(고스트 알파↓≈40%, 무색/감쇠).
     hit-test·plan 계산은 항상 **원본 `sidebar_rows`**(불변)를 봐 yo-yo를 원천 차단한다. 삽입선은 `rowTop(preview_rows, ghost_lo)`에 얇은 quad.
   - **단계 분해(각 단계 독립 green)**:
     - **SG8a ✅ — projectRows를 order-aware 토대로(동작 보존, 프리뷰 없음)**: `recomputeVisibleTabs`를 `projectRowsFrom(order:
       []const usize, group_depth: []const u8)` 순수 코어 + **identity 래퍼**로 분리. pass1/pass2가 `self.tabs.items[order[i]]`를
       거치고 depth 파생은 `group_depth[i]`를 선언값으로 쓴다. `group_header.tab`=`order[i]`(원본 인덱스)·`.active`=`order[i]==active_tab`.
       pass2 헬퍼 4개 order-aware — `subtreeHasMatch`/`directCardCount`는 필수 `order`(투영 내부 전용), `effectiveDepthAt`/
       `groupSubtreeEnd`는 **optional `order`/`group_depth`**(null=라이브 self.tabs, 드래그/create 경로가 그대로 호출·byte-identical).
       **검증**: identity `projectRowsFrom` == 옛 flat/그룹 투영(모든 Row 태그·필드 byte-identical, 헤드리스 단언) + 뒤집힌 순열이
       표시 순서만 뒤집고 `self.tabs`는 불변임을 단언. 기존 projectRows/SG3~SG5 그룹 테스트 회귀 0.
     - **SG8b ✅ — `simulateDrop` 순수 코어 + 등가 테스트**: plan→VirtualLayout(order/group_depth/ghost 범위). 검증: `simulateDrop`
       산출 == 실제 move 후 read(헤드리스 등가).
     - **SG8c ✅ — 프리뷰 투영 + 고스트 방출 + 사라짐 예외**: `sidebar_preview_rows` + 게이트 예외([lo,hi) 강제 방출). 검증: 접힌 그룹
       카드 plan→preview_rows에 고스트 존재(원본 rows엔 없음).
     - **SG8d ✅ — 카드 드래그 고스트 렌더 + up 확정**: 반투명·삽입선·안 사라짐. 검증: up 후 `self.tabs`가 라이브 시절과 동일 + macOS 스크린샷.
     - **SG8e ✅ — 그룹 드래그 subtree 고스트 + depth 프리뷰**: 검증: up 등가 + 스크린샷.
     - **SG8f ✅ — 라이브 경로 잔재 제거·정리 + 완결**: SG8d/e로 동작은 이미 완성됐고, 이 단계는 옛 라이브 경로 잔재를 청소한다.
       (1) **매 프레임 앵커 팔로우 제거** — `groupDragFrame`→**`groupDragPreviewFrame`**로 개명(프리뷰 전용)하고 반환값을 `void`로.
       self.tabs가 드래그 내내 불변이라 마커 인덱스가 안정 → 옛 `sidebar_drag_index`/`sidebar_group_drag_marker`의 매 프레임
       반환값 대입(새-마커 추적 잔재)을 걷어냈다. (2) **`sidebar_drop_slot` 제거** — SG8d/e에서 고스트+삽입선으로 전환되며 이
       드롭 하이라이트 슬롯이 write-only-null(전부 dead)이 됐다. 필드+dead 분기+테스트 단언까지 제거(pane grip 드래그는 **별도**
       `pane_drop_slot`을 써 무관 — 상호배타). (3) **rebuild 수렴 확인** — 드래그 프레임은 `refreshDragPreview`(rebuild 없음)+
       `rebuildSidebar` 정확히 1회(두 투영: hit-test용 원본 `sidebar_rows` + 렌더용 `sidebar_preview_rows`는 설계상 필요, 이중
       rebuild 아님). 확정(up)의 `commitSidebarDragPreview`가 move 1회+rebuild로 마무리한다. 검증: `zig build test`+`mise run check`
       (oracle/e2e/stress) 회귀 0 + 스크린샷 4변형(카드·그룹·접힘·색) 정상 + 비드래그(`MARU_FORCE_GROUP`) 고스트 없이 clean.
   - **SG8g ✅ — 실앱 드래그 UX 마감(실 drop 위치 판정·접힌 그룹 드래그 렌더)**: 헤드리스가 `raw_row`를 직접 넣어 hit-test **함수**만
     보던 갭을, mouse 핸들러의 **`y_px`→`raw_row`→plan 실경로**로 메운다.
     - **(A) 카드 드래그 "그룹 뒤/사이 top_level 탈출" 실좌표 보정 — `cardDropPlan`(mouse 핸들러·테스트 단일 출처)**: hit-test는
       불변 원본 `sidebar_rows`(드래그 소스가 아직 자기 자리)로 하는데 사용자는 소스가 빠진 **프리뷰**를 본다. 소스 카드 아래
       콘텐츠가 소스 높이만큼 위로 밀리는 **프리뷰 시프트** 때문에, 사용자가 프리뷰의 그룹 꼬리를 겨냥해도 원본 좌표론 멤버 행
       중앙에 떨어져 **흡수**(top_level=false)됐다(증상). `cardDropPlan`이 소스 행이 `raw_row` 위면(드래그 다운) 탈출 판정 y에
       소스 행 높이를 더해(`sidebarCardDropAfterGroup`만 보정), 프리뷰의 그룹 꼬리 겨냥이 마지막 멤버 하단 경계(탈출 존)에 맞게
       한다. 일반 위치 판정(`sidebarGroupDropTargetTab`)은 보정 **없이**(moveTab from/to가 소스 제거를 이미 보정 — 이중 보정 방지).
       `MARU_DEBUG`면 `cardDropPlan`이 `origin/y/raw_row/y_esc/raw_esc/gap/top_level`을 로깅(실앱 자기검증). **잔여**: "첫 그룹
       **위**로 탭 끌어 leading 만들기"는 여전히 헤더=넣기라 미해결(별도 "before-group" 탈출 필요 — 후속).
     - **(3) 드래그 대상이 접힌 그룹이면 프리뷰=접힌 헤더만**: SG8c의 고스트 force-emit(접힌 그룹 드롭 시 사라짐 방지)이 접힌
       그룹을 **통째로 드래그**할 때도 subtree를 강제 방출해 펼쳐 보였다. `PreviewCtx.dragged_collapsed`(그룹 통째 드래그 &&
       origin 마커 `group_collapsed`)로 대상/타깃을 구분: 대상=접힌 그룹이면 그 subtree의 `force_card`를 끄고 안쪽 헤더 flip을
       억제해 **접힌 헤더 한 줄**만 낸다. 타깃=접힌 그룹(카드를 그 안으로 드롭, `dragged_collapsed=false`)의 force-emit는 그대로
       (사라짐 방지 유지). 헤드리스로 대상=접힌 그룹→헤더 1·멤버 0·collapsed 유지, 타깃=접힌 그룹→드롭 카드 고스트 방출 단언.
   - **검증 비대칭**: SG8a/b/c는 순수 함수라 **헤드리스가 1급**(byte-identical·등가·고스트 존재). SG8d/e/f의 반투명 알파·삽입선 y·
     depth 픽셀은 헤드리스로 안 잡혀 **macOS 제품 스크린샷이 1급**(검증 매트릭스). 훅 `MARU_FORCE_GROUP_DRAGGHOST`(예정).
   - **적대검증이 정정한 것(요약)**: ① `surface_ptrs`/`active_tab`은 divergence 아님(reorderTabs가 활성 포인터 추적·같은 backing). ②
     핀은 clamp 코어 포함으로 해소(그룹 고정은 독립 백로그). ③ 프리뷰 투영은 타겟 헤더 `collapsed=false` **flip이 필요**(code-review #6
     재발 방지). ④ row-count는 복제(행 증가)가 아니라 **move(순열)**라 스크롤 발산 없음. ⑤ `ghost_mask`는 상태 배열이 아니라 range 파생.
   - **리스크**: [높음] 이중경로 divergence(→ 등가 테스트→코어 단일화, SG8a가 첫 단추). [중] 도메인 분리 이주 누락(렌더 소비자를
     preview_rows로, hit-test는 sidebar_rows로 정확히 — ⌘1-9 배지·IME caret 포함). [중] 스크롤 중 드래그 프리뷰 재투영·삽입선 트리거
     (autoscroll 없음=기존 한계). [낮] pane grip 별도 경로(상호배타)·rename 중 드래그 confirm 게이트가 up 삼키면 프리뷰 잔류(정리 경로 필요).
