# 사이드바 그룹 — 그룹 고정과 그룹-로컬 pin (§12~§13)

그룹 통째 고정(핀+그룹 통합, C2)과 멤버의 그룹 내 위치 고정(GL)의 계약이다. 그룹 전체의 진입점은 [사이드바 그룹](sidebar-groups.md)이고, 이 문서는 그 §12~§13을 소유한다.

> **절 번호는 파일을 넘어 이어진다.** 본문이 `§12.5`처럼 절만 가리키면 아래에서 소유 파일을 찾는다 — §1~§8·§10·§11 [sidebar-groups.md](sidebar-groups.md) · §9 [단계 분해](plans/sidebar-groups.md) · §12~§13 [그룹 고정과 로컬 pin](sidebar-groups-pinning.md) · §14 [top_level 재설계](sidebar-groups-top-level.md)

## 12. 그룹 고정(핀+그룹 통합, C2)

§10 백로그의 "그룹 고정 — 핀+그룹 조합의 파티션 무결성"을 별도 축으로 승격해 **C2(핀-리전 인식 파생)**로 설계 확정한다.
현재 pin(`[고정][비고정]` 프리픽스, session_model 88·`moveTab`)과 그룹(§2.1 위치 파생 마커)은 **각자 파티션**이라, "그룹
통째를 고정/강등"할 때 그룹이 고정/비고정 경계를 가로지르면 고정 프리픽스 불변식이 깨진다(SG4/SG5-1/SG8 모두 범위 밖).
C2는 **그룹 마커 `Tab.pinned`를 그룹 고정 권위**로 실어(§12.2) 리스트를 `[고정][비고정]` 2리전으로 나누고, **각 리전
안에서 §2.1 연속 파티션이 다시 성립**하게 한다. 단계 GP1~5(§12.12)는 **전부 완료** — 파생 코어 pin-region 인식(GP1)·
suffix-exclusion 정규화(GP2)·`toggleGroupPin`+plan clamp(GP3)·`pin_derived` 렌더(GP4)·잔재/문서 동기(GP5). 아래
§12.4~§12.11의 헤드리스와 `MARU_FORCE_GROUP_PIN` 스크린샷이 그 게이트다.

> **doc-first 적대검증 3회가 초안(scratchpad group-pin-draft.md)의 세 자기진단을 반박했고, 아래는 그 정정본이다.**
> 틀린 진단 셋 — ① "pass1 상태 폭발이 최대 리스크", ② "정규화를 rebuild 직전 단일 chokepoint로", ③ "group clamp를
> 이동 함수(moveGroupRange/simulateGroupMove)에" — 은 각각 §12.4·§12.5·§12.6에서 정정한다. 보강 9개는 §12.4~§12.11에 반영.

### 12.1 판정 — 삼중 파티션 공존이 C2로만 성립

- **I1(핀 프리픽스)**: 고정 탭이 `[0, pinned_count)`에 연속(`stablePartitionPinned`·`togglePin`·`clampMoveToGroup`).
- **I2(그룹 연속+최상위 전방)**: 각 그룹 `[마커, subtree_end)` 연속, 최상위 카드는 그 리전 첫 마커 이전(§2.1).
- **I3(중첩 gap-clamp 트리)**: `projectRowsCore` pass1·`effectiveDepthAt`·relevel.
- **[약점 최상] "고정 그룹 + 비고정 최상위 카드"**: §2.1의 **전역 앵커**(첫 마커 이전=최상위)와 핀 프리픽스가 리스트 앞을
  다퉈 표현 불가다. C3(멤버별 pin)=I1×I2 직접 모순 → 폐기. C1(전역 앵커 유지)=이 인접을 못 담음. **C2(핀-리전 인식
  파생) = 리전별 앵커 2개로만 공존 성립**. 계층은 **pin ⊃ group ⊃ nest**(엄격) — 핀 경계가 **최상위 단위 경계에서만**
  자르면 subtree가 통째로 한 리전에 들어가 I3이 자동 안전하다.
- **로컬 pin 축은 별개(GL §13, 상호참조)**: 위 삼중 파티션(I1/I2/I3) 위에 **그룹-로컬 pin**이 **직교하는 별개 축**
  (`Tab.local_pinned` — C2의 `Tab.pinned` 재해석과 달리 **새 필드**, §13.2)으로 얹힌다. C2의 pin 리전·정규화·전역 partition을
  **안 건드리고** subtree `[marker, end)` 내부만 재배열한다(§13.1 keystone). 단 그룹째 고정 **해제** 시엔 멤버 로컬 pin을
  리셋한다(직교는 '고정 켜는 동안'의 성질, §13.7 버그2). 상세·단계는 §13 단일 출처.

### 12.2 모델 — 새 필드 0개, `Tab.pinned` 재해석

`group_color`가 "마커 저장·멤버 위치 파생"의 선례이듯, **`Tab.pinned`를 두 층으로 재해석**한다(새 필드 0).

- **마커 탭 `pinned` = 그룹 고정 권위**(`group_color`/`group_depth`와 같은 층). 그룹 고정 = 마커 pinned=1.
- **그룹 멤버 카드 `pinned` = 파생 캐시**(권위 = enclosing 마커). `normalizePinnedFromGroups`가 `member.pinned :=
  enclosingMarker.pinned`로 동기화(§12.5). 최상위 카드는 개별 pin(현행 그대로).
- **왜 캐시 미러인가**: `countPinnedTabs`·`stablePartitionPinned`·`clampMoveToGroup`이 **per-tab pinned**를 읽는다. 마커만
  두면 `stablePartition`이 마커만 옮겨 그룹을 shred한다. 멤버를 마커 값으로 재기록하면 **기존 per-tab 핀 머신을 무변경
  재사용**한다.

### 12.3 파티션 통합 레이아웃

```
[고정 최상위카드] [고정 그룹들] [비고정 최상위카드] [비고정 그룹들]
└──────── 고정 리전 [0,pinned_count) ────┘ └──── 비고정 리전 [pinned_count,len) ────┘
       리전 안: §2.1(최상위 전방→그룹)          그룹 안: 중첩(SG5-3)
```

pin이 최외곽 2리전을 만들고, 리전 안은 §2.1, 그룹 안은 중첩이다. 불변식: I1 자명(pinned_count=고정 리전 끝, 항상 최상위
단위 경계 정렬 — normalize가 보장). I2 **리전별 first-marker**. I3 subtree가 한 리전 통째(핀 균일).

### 12.4 파생 코어 — pin-region 인식(보강 1·8, 정정 ①) — **GP1 완료**

**정정 ①(pass1 폭발 아님)**: 초안은 "pass1에 pin-region 리셋을 넣으면 상태(스택,order,group_depth,region)가 폭발"을 최대
리스크로 봤다. 검증 결과, 리셋은 **pass1 하나가 아니라 7개 subtree-스캔 경계 전부**에 필요하고, 각 경계는 "인접(또는
subtree 스캔 중) **per-position pinned 플립**에서 리셋/break" **한 줄**일 뿐이라 폭발이 아니다. "고정 그룹 + 비고정 최상위
카드" 인접이 **마커가 아닌 카드**에서 리전 경계를 만들므로, 마커만 보던 기존 경계 조건이 이를 못 잡아 ⓐ비고정 카드가
고정 subtree에 삼켜지고 ⓑ고정 접힘이 비고정 카드로 상속(숨김 shred)되고 ⓒ`(N)` 배지가 오염된다. 그래서 **경계 도메인 =
order-공간 per-position `self.tabs.items[order[i]].pinned`**(고정 count 아님, 보강 8)를 7 경계에 추가한다:

| # | 스캔(`app_session.zig`) | pin-region 처리 | 막는 증상 |
|---|---|---|---|
| 1 | `projectRowsCore` pass1 depth stack | `pinned` 플립 시 depth 스택 리셋(`top=0`) | 비고정 카드가 고정 그룹 depth 상속(삼킴) |
| 2 | `projectRowsCore` pass2 cstack collapse | `pinned` 플립 시 접힘 조상 스택 리셋(`ctop=0`) | 고정 collapsed가 뒤 비고정 카드로 상속(shred) |
| 3 | `effectiveDepthAt` | 스택 재실행 중 `pinned` 플립 시 리셋 | 리전 밖 카드 depth 오파생 |
| 4 | `groupSubtreeEnd` | 마커 pin과 다른 위치에서 break | 고정 subtree가 비고정 카드까지 삼킴 |
| 5 | `subtreeHasMatch` | 〃 | 검색 헤더 가시성이 다른 리전 매치로 오판 |
| 6 | `directCardCount` | 〃 | `(N)` 배지가 다른 리전 카드로 오염 |
| 7 | `ghostOverlapsSubtree` | 〃 | 드래그 고스트 flip/force-show 오판 |

또한 위치 앵커/소속 헬퍼를 리전 국소화한다:

- `firstGroupStartIndex` → **`firstGroupStartInRegion(lo, hi)`**(리전 안 첫 마커). `firstGroupStartIndex`는 `(0, len)` 위임
  래퍼로 남긴다.
- `pinRegionBounds(idx)` 신설 — idx가 속한 핀 리전 `[lo, hi)`(per-position pinned가 같은 최대 연속 구간; I1 프리픽스를
  **가정하지 않고** 인접 pinned 플립만 본다).
- **`enclosingGroupMarkerIndex` 핀 클램프** — 상향 스캔이 pin 플립을 넘으면 null(비고정 카드는 고정 리전 마커에 소속 불가).
- **라이브 8 호출처**: `promotePaneToNewWorkspace`(새 비고정 탭 삽입점 = `firstGroupStartInRegion(pinned_count, len)`)·
  `sidebarGroupDropBoundary`(리전 앵커)·`tabIsInGroup`(리전 소속)·`removeFromGroupForTab`(×2, 리전 안 최상위)·
  `ungroupTab`·`setGroupColorForTab`·`startRenameGroupForTab`(뒤 셋은 `enclosingGroupMarkerIndex` 클램프로 자동 리전화).

**동작 보존(SG8a identity 패턴)**: 현재 모든 워크스페이스는 그룹 고정 개념이 없어 **마커 pinned=0**(고정 그룹 0개)이다.
그러면 마커는 전부 비고정 리전이라 **리전 경계 = 리스트 양끝**이 되고, 7 경계의 pin 리셋/break는 flip 지점에서 스택이
비어 **no-op** → 기존 `projectRows` 산출과 **byte-identical**이다. 헤드리스 검증(§12.11)이 이를 고정한다.

### 12.5 정규화 — `normalizePinnedFromGroups`(보강 2, 정정 ②) — **GP2 완료**

**정정 ②(chokepoint 단일화 불가)**: 초안은 "정규화를 rebuild 직전 단일 chokepoint(`recomputeVisibleTabs` 안)로 모으자"
했으나 세 이유로 불가다 — ⓐ `recomputeVisibleTabs`는 매 rebuild O(n) 스택워크라 여기서 `self.tabs.pinned`를 mutate하면
매 프레임 비용, ⓑ **`sidebar_drag_preview != null` 게이트**(프리뷰 중 `self.tabs.pinned` mutate 금지 = SG8 "드래그 내내
`self.tabs` 불변" 보존 — `normalize` 첫 줄이 early-return), ⓒ **복원 특례**(`applyWorkspaceWindow`에서 `stablePartitionPinned`
**앞**에 명시 호출, §12.9). 그래서 정규화는 rebuild가 아니라 **pinned/그룹을 바꾸는 6 mutation 지점** 뒤에 1회씩 부른다:
`toggleGroupPin`·그룹 생성(`beginGroupForTab`)·`ungroup`·`removeFromGroup`(빼기 경로)·`closeTab` 마커 승계·
`commitSidebarDragPreview`(+복원 특례 `applyWorkspaceWindow`). **`togglePin`(개별 pin)은 정규화 없음** — 최상위 카드는 자기
값 유지, 그룹 멤버는 개별 pin 입구가 차단(§12.7 보강5)이라 desync가 안 생긴다.

**정정 ②′(marker-propagation → suffix-exclusion)**: 초안·GP2 서술은 "pass1과 동형 스택워크로 `member.pinned :=
enclosingMarker.pinned`를 재기록"(marker-propagation)이었으나, 그러면 GP1 렌더(`groupSubtreeEnd` **pin-인식**)가 "고정 그룹 +
비고정 top카드"(§12.1) 인접에서 top카드를 그룹에서 배제하는 것과 tension이 생겨 canonical이 어긋난다. 실제 구현은 **suffix-exclusion**
이다: 각 **최상위 그룹의 pin-무시 구조 subtree** `[i, e)`(`effectiveDepthAt`+형제/얕은 마커 break)에서 마커 pin이 **마지막으로
일치**하는 위치 `last_match`까지를 진짜 멤버 범위로 보고 `member.pinned := marker.pinned`로 재기록한다. 그 뒤 꼬리 `[last_match+1, e)`
(마커와 다른 pin이 subtree 끝까지 이어짐 = 다음 pin 리전의 **genuine 최상위 카드**)는 **배제**하고, 사이에 낀 desync 멤버(마커 pin이
뒤에서 재등장)는 **흡수**한다. 이렇게 하면 canonical 상태에서 GP1 렌더와 **동일 답**(top카드 안 흡수·idempotent)을 내면서, 손상/
레거시 혼합 파일(멤버 pinned=1·마커=0, 또는 desync)은 여전히 마커 기준으로 canonical화해 **shred를 막는다**(누락 시 shred가 실패 모드).

### 12.6 이동/드래그(정정 ③) — **GP3 완료**

**정정 ③(clamp는 이동 함수가 아니라 plan 산출부)**: 초안은 `moveGroupRange`/`simulateGroupMove`에 `clampGroupMoveToRegion`을
넣자 했으나, 두 함수는 프리뷰/확정 **이중 경로**라 양쪽에 넣으면 divergence(SG8 이중경로 위험)가 재발한다. 대신 **`groupDragPreviewFrame`의
plan 산출부에서 단일 clamp** — `insert_before`를 `DropPlan`에 굽기 **전**에 드래그 그룹의 리전으로 clamp한다. 확정(up)은
마지막 plan을 재사용하므로(SG8 iii) 프리뷰=확정이 같은 clamp를 본다. 카드 드래그는 이미 `clampMoveToGroup`(핀 경계)을
순수 코어에 태워(SG8) 정직하다. 중첩 넣기(`groupNestPlan`)는 **두 그룹 pin이 같을 때만 허용**(다르면 null→형제 폴백,
C3 재발 방지). 드롭 고정 승계는 **없음**(clamp가 애초에 막고, pin은 명시 토글 전용).

**`toggleGroupPin`의 리전 안착(정정 ③′ — `moveGroupRange` 대신 `stablePartitionPinned`)**: 그룹 통째 고정/해제(§12.10)는
드래그가 아니라 명시 토글이라 위 plan 경로가 아니다. 순서: (1) 토글 **전** `groupSubtreeEnd`(pin-인식, 개별 pin 차단으로
마커·멤버 pin 일치)로 완전 subtree `[mi, e)`를 잡고, (2) 마커+멤버 pin을 새 값으로 **직접 동기**(suffix-exclusion은 전량
flip 직후를 "꼬리"로 보고 안 흡수하므로 여기서 명시 flip이 유일 동기원), (3) **`stablePartitionPinned`**로 그 연속·uniform-pin
블록을 목표 리전 경계에 안착한다 — 복원과 **같은 프리픽스 정렬**이라 그룹 리전 양쪽에 다른 고정 단위가 있어도(예: 고정 그룹 앞에
또 다른 고정 그룹) 프리픽스 불변식(I1)을 항상 지킨다(`moveGroupRange`의 단일 `insert_before`로는 표현 못 하는 경계 케이스 —
stable 수집이 그룹을 통째로 붙여 옮겨 파티션 무결 유지). (4) `normalize`(idempotent 확인) 후 1회 rebuild. `clampGroupMoveToRegion`은
어디까지나 **그룹 드래그** plan 지점 전용이고, 토글의 리전 안착은 `stablePartitionPinned`가 맡는다.

### 12.7 removeFromGroup·개별 pin·마커 승계(보강 4·5·6)

- **removeFromGroup 고정 멤버 빼기(보강 4)**: 그룹에서 빼면 pin을 잃는다(빼기=pin 상실). `clampMoveToGroup`이 pin-trap이라
  **unpin을 move 전에** 결정한다(그러지 않으면 clamp가 고정 영역에 붙잡는다).
- **개별 카드 pin 입구 차단(보강 5, GL §13에서 라우팅 정정)**: 그룹 멤버는 개별 **전역** pin(`Tab.pinned=1`)을 **못 얻는다** —
  멤버만 개별 pin하면 전역 partition이 그룹을 shred(C3)하고 캐시 권위가 깨지기 때문이다(이 불변식은 그대로). 초기 GP3은 이
  입구를 멤버 우클릭 pin의 **그룹째 고정 위임**으로 막았으나, **GL §13이 이를 되돌려** 멤버 우클릭 "위치 고정"을 **그룹-로컬 pin**
  (`cardPinRole=.local`·`toggleLocalPin` — 전역 축이 안 읽는 별개 필드 `local_pinned`, §13.2·§13.6)으로 라우팅한다. 즉 전역 pin
  입구 차단(불변식)은 유지하고, 막힌 자리를 직교 축(로컬 pin)으로 채운 것이다(§12.10 cardPinRole 3분기).
- **`inheritGroupMarker` pinned 승계(보강 6)**: 마커 승계(`closeTab`·removeFromGroup) 시 `group_start/collapsed/depth/color`에
  더해 **`pinned`도 승계**해야 승계 과정에서 그룹 고정이 소실되지 않는다.

### 12.8 렌더 힌트 `pin_derived`(보강 7) — **GP4 완료**

멤버 캐시 `pinned=1`을 그대로 렌더하면 **모든 멤버에 📌가 떠 노이즈**다. `Row.card`에 **`pin_derived: bool` 힌트**를 실어
(`chrome/components/sidebar.zig`: `card: struct { …, pin_derived }`) `projectRows`가 비마커 멤버 카드엔 `true`, 최상위 카드·
마커 자기 카드엔 `false`를 굽는다(마커 pinned는 파생이 아니라 **권위**).

**단일 출처 `sidebarRowShowsPin(row)`**: `buildSidebarTitleFrame`이 `pins[]`를 채울 때와 헤드리스 테스트가 **공유**하는 하나의
판정 함수(live `tab.pinned` 산발 판정 금지). 규칙 — (a) `group_header` row = 마커 `pinned`면 **그룹 고정 인디케이터 📌**(헤더 이름줄
우측 끝, "이 그룹 고정됨"을 헤더 하나에만), (b) `card` row 중 `pin_derived`(멤버 파생 캐시)면 **억제**, (c) **그룹 마커 자기 카드**
(`group_start != null`)도 **억제**(헤더가 인디케이터를 드므로 자기 카드 📌는 중복), (d) 그 외 최상위 카드만 live `tab.pinned` 그대로
📌(개별 위치 고정 유지). rename 중 헤더는 호출처가 억제(편집 폭 보존). 도메인은 `sidebarRenderRows()`(드래그 중이면 preview_rows).

**로컬 pin 축 선두 분기(GL §13.6, 상호참조)**: 위 (a)~(d) **앞에** `card.local_pinned` 선두 분기를 둔다 — 그룹-로컬 pin 멤버(§13)는
**실제 사용자 pin**이라 (b) `pin_derived` 억제를 **우회**해 📌를 살린다. `pin_derived`(그룹째 고정 캐시 = `Tab.pinned` 파생)와
`local_pinned`(멤버 로컬 pin = 별개 필드)는 **직교**해 한 멤버에 **둘 다 참**일 수 있고(그룹째 고정 그룹 안 로컬 pin 멤버), 그때 헤더
그룹📌 + 멤버 로컬📌가 함께 뜬다(단일 글리프 U+1F4CC — 헤더/카드 **위치로 구별**, §13.6). `Row.card`에 `pin_derived`와 동형의
`local_pinned: bool = false` 힌트가 실린다(비마커 그룹 멤버 카드에만 채움 — 마커·최상위=false, §13.8 leaf 전용).

### 12.9 직렬화 — 새 키 0

`workspace.v1`의 `pinned={d}`(탭 라인 스칼라)가 마커 pin을 그대로 싣는다 — 그룹 고정 = 마커 `pinned=1`. 멤버 pinned 캐시는
저장돼도 무해(복원 정규화가 흡수). **복원 순서: (1) 탭 설치 → (2) `normalizePinnedFromGroups` → (3) `stablePartitionPinned`.**
지금은 (3)만 있으니 **(2)를 (3) 앞에 삽입**한다(§12.5 복원 특례). 손상 파일(멤버 pinned=1·마커=0)은 복원 정규화가 canonical로
흡수 — round-trip 테스트는 "정규화 후 canonical 단언"으로 둔다.

### 12.10 UX

- **헤더 우클릭 "그룹 고정" 토글**(`ctx_group_menu_pin` = 그룹 헤더 메뉴 Rename 다음 항목, `.group` 분기): `toggleGroupPin(marker)`
  → 마커+멤버 pin 직접 동기 → **`stablePartitionPinned`로 리전 안착**(§12.6 정정 ③′, `moveGroupRange`가 아님) →
  `normalizePinnedFromGroups`(idempotent) → rebuild → `assertPinnedPrefixRuntime`(디버그).
- **카드 우클릭 pin = `cardPinRole` 3분기(GL §13 GL2 — 아래 "그룹째 위임"은 되돌림)**: 초기 GP3은 그룹 소속 카드 우클릭 pin을
  `enclosingGroupMarkerTab`로 **그룹째 위임**(`toggleGroupPin`)했으나, **GL §13이 이를 되돌려** 멤버는 **그룹-로컬 pin**으로
  라우팅한다. 현행 dispatch(`acceptContextMenu`)·라벨(`buildContextMenuItems`)은 `cardPinRole` **단일 판정**을 공유한다
  (ctx_menu_pin=1 인덱스 고정, desync 원천 제거): **마커 카드=`.group`** → 그룹째 `toggleGroupPin`(마커는 그룹 시작이라 개별 pin이면
  C2 캐시 권위가 깨져 그룹째가 유일 안전 경로)·**비마커 멤버=`.local`** → 그룹 내 위치 고정 `toggleLocalPin`(GL §13 — `local_pinned`
  별개 축)·**최상위 카드=`.individual`** → 개별 전역 pin `togglePin`. 라벨도 "그룹째 고정"/"그룹 내 위치 고정"/"위치 고정"으로 갈린다.
  멤버가 개별 **전역** pin(`Tab.pinned`)을 얻는 입구는 여전히 차단(§12.7 보강 5)이라 캐시 권위 desync가 없다.
- pin 표시는 §12.8(`sidebarRowShowsPin` 단일 출처 — 멤버·마커 카드 📌 억제·헤더 인디케이터; **로컬 pin 멤버는 선두 분기로 📌
  유지**, GL §13.6 예외). pane 분리·removeFromGroup은 **각 카드가 속한 핀 리전의 첫 마커 앞**(§12.4 리전 헬퍼
  `firstGroupStartInRegion`/`pinRegionBounds`).

### 12.11 불변식·검증(보강 8·9)

- **경계 도메인(보강 8)**: order-공간 **per-position pinned**(고정 count 아님). 7 경계와 리전 헬퍼가 모두 이 도메인을 쓴다.
- **`assertPinnedPrefixRuntime` 확장(보강 9)**: 기존 "고정 프리픽스 연속"(비고정 뒤에 고정이 없음 = I1)에 더해 **핀 경계 =
  그룹(최상위 단위) 경계 정렬**을 런타임 assert(핀 경계가 subtree 중간을 자르지 않음 = I3 안전 전제). 정렬 판정은 **순수 함수
  `pinBoundariesAlignGroups()`에 위임**한다 — assert(panic)와 헤드리스 테스트(GP4(b))가 **같은 판정을 공유**하도록. 판정 구조는
  `normalizePinnedFromGroups`와 **동형(suffix-exclusion)**: 각 최상위 그룹 구조 subtree `[i,e)`에서 마커 pin이 마지막으로 일치하는
  `last_match`까지의 진짜 멤버 범위 안에 다른 pin 카드가 끼면(desync 샌드위치) `false`, canonical(normalize 후)은 항상 `true`,
  꼬리 top카드는 다음 리전이 다룬다. 호출처: `toggleGroupPin`·`applyWorkspaceWindow`(복원) 뒤 디버그 게이트.
- **헤드리스**: ① **identity byte-identical**(고정 그룹 0개면 리전 경계=양끝 → 기존 projectRows/SG3~SG8 회귀 0, `test "GP1: …"`).
  ② **7 경계**: "고정 그룹(마커 pinned=1) + 비고정 최상위 카드 + 비고정 그룹" 인위 배치로 비고정 카드가 안 삼켜지고(#4·#1)
  고정 접힘 뒤 안 숨고(#2) `(N)` 안 오염(#6) depth 리전별 정확(#3)함을 단언(GP1). ③ **정규화·안착**: shred→canonical·복원
  순서·마커 pinned 승계(GP2)·suffix-exclusion tension 해소·카드 pin 라우팅(`cardPinRole` — GP3(b)/GL2 결합 테스트에서 멤버는
  GL §13 로컬 pin으로 정정)·`toggleGroupPin`·`clampGroupMoveToRegion` 프리뷰=확정(GP3). ④ **렌더**: `pin_derived`·`sidebarRowShowsPin`·
  `pinBoundariesAlignGroups` desync 검출/흡수(GP4).

### 12.12 단계 분해

[사이드바 그룹 단계 분해](plans/sidebar-groups.md)가 소유한다 — 단계와 완료 이력은 계획 문서 몫이다.
### 12.13 리스크

- **[약점 최상]** "고정 그룹 + 비고정 최상위 카드"(§12.1) — C2 2앵커만 해소. **정정: 파생 2차 일반화 폭발은 없다**(§12.4 —
  7 경계 각 한 줄). 적대검증 1순위였고 GP1 헤드리스로 닫힘. 정규화도 이 인접을 **suffix-exclusion**으로 흡수(§12.5, GP3 tension 해소).
- **[약점]** 이중표현 정규화 누락 = shred — chokepoint 단일화 대신 **6 mutation 지점 호출 + 게이트/복원 특례**(§12.5).
- **[중]** SG8 이중경로 divergence — group clamp를 **plan 산출부 단일 clamp**(§12.6)로, `assertPinnedPrefixRuntime` 확장(§12.11
  — 순수 `pinBoundariesAlignGroups`)으로 방어.
- **[중]** 기존 테스트(`togglePin`·`clampMoveToGroup`·SG4/5/8) — 그룹 고정 0개/전부 비고정 byte-identical(GP1 identity)로 회귀 0.

**단순화 대안**(C2 churn이 과하면): **S1(Chrome식)** — 그룹 고정 폐기, 카드 pin=그룹 자동 제외(위치 파생 무변경, "그룹째
고정" UX 상실). 원리는 C2, 리스크 회피는 S1. **C2로 완결(GP1~5)** — churn이 관리 범위였고 위 방어들이 회귀 0을 유지했다.

## 13. 그룹-로컬 pin(멤버 그룹 내 위치 고정, GL)

§12(C2)가 "그룹**째** 고정"(전역 `[고정][비고정]` 리전)을 다뤘다면, GL은 **그룹 안 멤버를 그 그룹 subtree 내부에서 위로
고정**하는 별개 기능이다. 사용자 요구: 그룹 안 멤버 우클릭 "위치 고정" → 그 멤버가 **그 그룹 subtree 내부에서 프리픽스(마커
직후)** 로 뜬다. 헤더 우클릭 "그룹 고정"=그룹째(전역, §12 현행 유지)와 트리거·축이 분리된다. 드래그해도 로컬 pin은 유지된다
(전역 pin과 대칭). doc-first **적대검증 3회 보강**(아래 8개)이 초안(scratchpad group-local-pin-draft.md)을 정정·확정한 결과다.

### 13.1 판정 — C2와 **직교하는 새 축**(keystone 보조정리)

- **얹힘 = (a) C2에 깨끗이 얹힌다.** GL은 C2(전역 핀 리전)와 **직교하는 새 축**이라, C2의 파생/정규화/파티션 코어(pin-region
  7 경계·normalize·전역 partition·clamp §12.4~12.11)를 **전혀 안 건드리고** 새 필드 + subtree-로컬 물리 재배열로만 성립한다.
- **C3(§12.1 폐기)와의 차이**: C3=전역 멤버 pin은 멤버를 리스트 앞 고정 프리픽스로 끌어내 그룹에서 **뜯어낸다**(I1×I2 직접
  모순). GL=로컬 pin은 멤버를 **subtree `[marker, end)` 안에서만** 재배열한다 — 여전히 그 범위 안이라 §2.1 연속 파티션(I2)·
  중첩(I3)이 안 깨진다. GL은 "그룹 안의 §2.1을 한 단계 더 재귀"한 것.
- **keystone 보조정리(보강2 — 명문화)**: `stablePartitionPinned`(전역 2-pass §12.6)는 **pin-uniform 블록의 내부 상대순서를
  보존**한다(stable). 그래서 한 그룹 subtree가 전역 리전 안에서 통째로 옮겨져도, 그 subtree 안의 GL float 순서는 **파괴되지
  않는다**. 즉 GL과 C2는 단순히 "서로 다른 필드"라서 독립인 게 아니라, **전역 partition이 subtree 축 위에서 무연산(no-op)**
  이기 때문에 직교한다. 이 보조정리가 "그룹째 고정 × 그룹-로컬 pin 공존"(§13.4)의 합성 안전성을 떠받친다.
- **직교는 '고정 켜는 동안'의 성질 — 해제는 리셋(사용자 피드백 정정, 버그2 — 초안 "완전 직교 survival" 뒤집음)**: 위 keystone
  직교는 그룹째 고정이 **켜져 있는 동안** 로컬 pin float가 전역 partition에 안 흩뜨려짐을 뜻한다. **다만 `toggleGroupPin`으로
  그룹을 통째 해제(off)하는 순간**엔 그 subtree(중첩 자식 포함) 멤버의 `local_pinned`도 함께 **클리어**한다 — 사용자가 "그룹째
  고정을 풀었는데 자식이 개별 📌로 남는다"고 리포트해(버그2), 기대인 "그룹 고정만 풀리고 멤버는 그냥 그룹 멤버로 복귀"에 맞춘
  **리셋 시맨틱**이다. 즉 확정 시맨틱은 초안의 "survival(고정 해제 후에도 로컬 pin 유지)"이 **아니라** "고정 켜는 동안 직교 ·
  해제 시 리셋"이다(고정 카드가 개별 pin을 유지하는 것과 대조 — 그건 `Tab.pinned` 개별 축이라 그룹 토글과 무관). 배선·근거는
  §13.7, 회귀는 GL4(a)(재토글)·pin매트릭스 #2(버그2).

### 13.2 모델 — **새 필드 `Tab.local_pinned`**(재해석 불가, 보강1)

저장은 멤버 `Tab.pinned` 재해석이 **아니라** 새 스칼라 `Tab.local_pinned: bool = false`다(`session_model.zig` `Tab` 블록,
`group_color`/`pinned` 인접). 재해석이 불가능한 이유(보강1):

- **전역 파티션 머신이 로컬 pin을 전역 신호로 읽어 shred한다**: `countPinnedTabs`·`stablePartitionPinned`·`clampMoveToGroup`·
  `moveTab`이 **per-tab `pinned`를 전역**으로 읽는다. 비고정 그룹 안 멤버를 로컬 pin(=`pinned=1`)하면 그 멤버가 전역 고정
  프리픽스에 잡혀 **사이드바 맨 앞으로 끌려나가 그룹을 찢는다**(= C3 부활, §12.1).
- **`normalizePinnedFromGroups`가 로컬 pin을 덮어쓴다**: normalize는 canonical화를 위해 `member.pinned := marker.pinned`로
  재기록(§12.5)하므로, 로컬 pin을 멤버 `pinned`에 실으면 다음 mutation 때 마커값(보통 0)으로 **소실**된다. C2 모델은
  `member.pinned == marker.pinned`(캐시 미러)를 **불변식으로 요구**해 멤버 `pinned`에 다른 의미를 실을 수 없다.

→ **새 필드가 유일 해법**: `local_pinned`는 전역 머신이 **안 읽어**(count/partition/clamp/moveTab/normalize 전부 `pinned`만
본다) 전역 파티션에 절대 영향이 없고(C3 shred 원천 차단), normalize와도 **서로 다른 비트를 소유**해 무충돌이다. `local_pinned`는
group_start!=null(마커)·top-level 카드에선 무의미(마커=그룹 고정 권위, top카드=개별 pin은 `Tab.pinned`가 든다).

### 13.3 파생 — subtree-로컬 물리 stable partition(`stablePartitionSubtree`)

투영-only(order 순열)가 아니라 **물리 재배열**(self.tabs)이다 — "위치=self.tabs 순서"(§2.1)를 유지해 hit-test·드롭·SG8
order-aware 인프라가 **전부 무변경**(로컬 pin 0개면 no-op → byte-identical, GP1 안전망 패턴). 투영-only는 표시 order ≠
self.tabs order가 되어 드롭 타깃 매핑이 divergence(기각).

`stablePartitionSubtree(mi)`(신규, `stablePartitionPinned` 인접): 마커 `mi`의 subtree `[mi+1, groupSubtreeEnd(mi))` **안에서**
`local_pinned` 직접 멤버 카드를 마커 직후로 stable float한다. `reorderTabs`(공통 재배열 스캐폴딩) 재사용:

- **unit-aware(보강5)**: 재배열 단위 = subtree의 **직접 top-level 단위** — 직접 멤버 카드(크기 1, `local_pinned`면 float
  대상)와 **자식 subgroup 통째 블록**(`[j, groupSubtreeEnd(j))`, moveGroupRange/groupBlockPermutation 결). 자식 subgroup은
  절대 안 쪼개진다(per-tab 아님). pass1=`local_pinned` 직접 카드(상대순서 유지), pass2=나머지(비-pin 직접카드·자식 subgroup
  통째, 상대순서 유지). 마커 자신(index mi)은 앵커라 제자리.
- **subtree `[marker, groupSubtreeEnd)` 내부만**(I2/I3 보존): float는 그 범위 안에서만 일어나 subtree 끝·형제/얕은 마커 경계를
  안 넘는다. `groupSubtreeEnd`(pin-인식)·`effectiveDepthAt`는 재배열 후에도 불변(마커·자식 group_depth 무변, 카드만 셔플).
- **중첩 재귀 + 포인터 재탐색(보강5)**: 자식 subgroup **안** 멤버의 로컬 float는 그 자식 마커에 대해 이 함수를 **따로** 부른다
  (각 마커별 재귀). 재배열로 자식 마커 인덱스가 밀리므로 **heap-pin `*Tab` 포인터로 재탐색**해야 한다(인덱스 무효화 회피).

### 13.4 배선 — "항상 `stablePartitionPinned` **뒤**"(보강3, 단일화)

`normalizePinnedFromGroups`가 도는 mutation 지점(§12.5 6곳 + 복원)에서, subtree partition은 **항상 전역 `stablePartitionPinned`
뒤**에 실행한다. 초안 §3.3의 "normalize 직후"는 복원 경로(`applyWorkspaceWindow`: normalize→stablePartitionPinned)와 **순서
모순**이라(전역 partition 앞에 subtree float를 넣으면 전역 partition이 subtree를 다시 통째로 옮겨 무의미) 정정한다. 표준 순서:

```
(1) normalizePinnedFromGroups   — 멤버 pinned 캐시 = 마커값(전역 축 canonical, §12.5)
(2) stablePartitionPinned       — 전역 [고정][비고정] 리전 안착(§12.6)
(3) 각 마커에 stablePartitionSubtree — subtree-로컬 float(GL, keystone 보조정리로 (2)를 안 흩뜨림)
```

- **드래그 게이트(필수, 보강6)**: `stablePartitionSubtree`도 `sidebar_drag_preview != null`이면 early-return
  (normalize 게이트와 동일 규율) — SG8 "드래그 내내 self.tabs 불변" 보존. 확정(commit)은 `clearSidebarDragPreview` **후**라 통과.

### 13.5 드래그 — `simulateDrop`에 subtree-로컬 clamp(보강6, GL2 선결)

로컬 pin 멤버 드래그 시 **subtree-로컬 프리픽스 clamp**를 `simulateDrop`에 **구워** 프리뷰=확정을 맞춘다(SG8 불변식 B — 프리뷰가
확정이다). C2의 `clampGroupMoveToRegion`(전역 리전 clamp) 패턴을 한 단계 안쪽(subtree)으로 가져온 것. **GL1엔 인프라(파티션
코어)만**, 실제 드래그 clamp·토글은 GL2. (1차 fallback = re-partition-on-commit: 확정 후 `stablePartitionSubtree`가 다시 float
해 snap-back — 전역 pin drag가 `clampMoveToGroup`으로 리전에 갇히는 것과 같은 결.)

**확정 클램프 보강(GL3 — 프리뷰=확정 엣지 완성)**: re-partition-on-commit **하나만으로는 부족한 엣지**가 있다 — 로컬 pin 멤버를
**마커 자기 카드 위로**(target=마커 인덱스) 드래그하면 raw `moveTab(origin, marker)`이 카드를 마커 **앞**(그룹 밖 top-level)으로
eject하고, 그러면 뒤이은 `floatLocalPinsAllGroups`가 (더 이상 subtree 멤버가 아니라) 회수하지 못해 **프리뷰(clamp돼 그룹 안)≠
확정(밖으로 튐)** 이 된다. 그래서 `commitSidebarDragPreview`의 `.card` 경로도 `simulateDrop`과 **같은** clamp(`clampMoveToGroup`
위에 `localPinPrefixBounds` 겹침)를 태워 `moveTab` target을 프리픽스로 가둔다 — 프리뷰=확정을 완성한다. `bounds=null`(비-로컬-pin)
이면 raw target 그대로라 기존 카드 드래그 동작 불변. **단 "드래그로 그룹 밖 out"은 로컬 pin 해제(§13.7)라 clamp 대상이 아니다**
— clamp는 로컬 pin **멤버**의 그룹 **안** 이동만 프리픽스로 가두고(실제로는 멤버가 그룹 밖으로 못 나감), 밖으로 나간 top-level
카드의 stale `local_pinned`는 §13.7 위생 스윕이 지운다(두 기전은 상보적, commit에서 clamp→float→sweep 순서).

### 13.6 렌더 — `sidebarRowShowsPin` **선두 분기**(보강7)

현재 멤버 카드는 `pin_derived`(그룹째 고정 캐시)라 `sidebarRowShowsPin`(§12.8)이 **모든 멤버 📌를 억제**한다. 로컬 pin 멤버는
**실제 사용자 pin**이라 📌를 살려야 하므로 `sidebarRowShowsPin`에 **`local_pinned` 선두 분기**(pin_derived 우회)를 둔다:

```
.card => if (c.local_pinned) true          // ← 신규: 로컬 pin 멤버는 📌(pin_derived보다 우선)
         else if (c.pin_derived) false       // 그룹째 고정 캐시 멤버 억제(현행 §12.8)
         else if (마커 카드) false else tab.pinned // 최상위 개별 pin만(현행)
```

`Row.card`에 렌더 힌트 `local_pinned: bool = false`(chrome/components/sidebar.zig, `pin_derived` 동형) + `appendCardRow`·
`projectRowsCore` 전달(비마커 그룹 멤버 카드에만 `d > 0 and tab.local_pinned`, 마커 카드·최상위 카드=false — §13.8 leaf 전용).
그룹째 고정 📌(헤더)와 로컬 pin 📌(멤버 카드)가 **위치로 구별**된다. **공존 시각 모호**(둘 다 단일 글리프 U+1F4CC)는 **수용**
(별도 글리프 미도입). 구별은 **선두 분기와 힌트**가 하고, 공존은 헤드리스 단언과 제품 스크린샷(`MARU_FORCE_GROUP_LOCALPIN`)으로 고정한다.

### 13.6.1 마커 자기 카드 렌더 위치 — 로컬 pin **뒤**(그룹 절대 최상단 = 로컬 pin)

`stablePartitionSubtree`(GL1)는 로컬 pin 직접 멤버를 마커 **직후**로 float하지만(§2.1 위치 파생상 마커가 subtree 첫 탭이라
`self.tabs` 순서로는 로컬 pin을 마커 앞에 **못 둔다** — 소속·연속 파티션·직렬화가 그 순서 파생), 사용자는 로컬 pin이 그룹의
**절대 최상단**(마커 대표 카드 **포함** 그 위)에 뜨길 원한다. 그래서 **렌더/hit-test 레이어**(`projectRowsCore`, sidebar_rows·
preview_rows 공용 order-aware 투영)에서 마커 **자기 카드** row만 로컬 pin 뒤로 재배치한다 — `self.tabs`(저장/직렬화/전역
파티션)는 **불변**이다.

- **방식(버퍼링·재방출)**: 마커 진입 시 **헤더 row는 즉시** 내되(현행), 마커 **자기 카드**는 `PendingMarkerCard`(tab_idx·
  depth·visible·ghost)에 **버퍼링**한다. 이어지는 order 위치가 이 그룹의 **로컬 pin 직접 leaf 멤버**(`group_start==null` ∧
  `depth==마커 depth` ∧ `local_pinned`)인 동안 그 카드들을 먼저 내고, **첫 비-로컬-pin 위치**(비pin 멤버·자식 subgroup
  마커·subtree 끝·핀 리전 경계) **직전**에 `flushMarkerCard`로 마커 카드를 낸다. order 끝까지 로컬 pin만인 그룹은 **post-loop
  flush**가 낸다(그룹-끝 케이스). 결과 카드 순서 = `[로컬pin 멤버…, 마커 자기 카드, 비pin 멤버…]`.
- **로컬 pin 0개 = byte-identical**: 마커 직후 첫 위치에서 곧바로 flush돼 마커 카드가 여전히 헤더 직후(첫 카드) → 기존 렌더와
  **byte-identical**(회귀 0).
- **중첩**: 조상 마커 카드는 자식 subgroup 마커·비pin 멤버 진입 시 즉시 flush되므로 보류는 **한 번에 최대 1개**다(자식 subtree는
  통째 유지·depth 불변). 각 마커가 자기 그룹의 로컬 pin 뒤로만 재배치된다(재귀 동형).
- **hit-test 정합**: 각 `Row.card.tab`은 실제 tab index 그대로(순서만 재배치)라, slot→tab 역매핑(`visibleTab`/`displaySlotOf`)이
  정확하다. 마커 카드 row가 로컬 pin 뒤에 있어도 그 row.tab=마커라 **클릭 시 마커 워크스페이스 활성**(마커 카드 드래그 =
  그룹 통째 SG5도 `group_start!=null` 라우팅이라 위치 무관).
- **드래그 정합(SG8, 프리뷰=확정)**: sidebar_rows·preview_rows가 **같은 `projectRowsCore`** 를 쓰므로 재배치가 양쪽에 동형이고,
  확정은 `commitSidebarDragPreview`의 clamp→float→sweep이 `simulateDrop`과 동일 착지를 낸다. 로컬 pin 멤버 드래그(프리픽스
  clamp)·그룹 통째 드래그(subtree 블록 이동)는 프리뷰=확정이 유지된다(헤드리스 GL3(d)). **고스트 range**는 재배치된 마커 카드
  row까지 이어 붙는다(`flushMarkerCard`가 `pm.ghost`면 lo/hi 확장 — 로컬 pin만인 그룹 통째 드래그의 마커 카드가 range 밖으로
  새지 않게). `Row.card.tab`은 self.tabs **인덱스**(id 아님)라 프리뷰(불변 self.tabs)와 확정(재배열 self.tabs) 인덱스는 좌표계가
  달라, 정합 비교는 **실제 *Tab 포인터**로 한다(GL2(c) 선례).
- **엣지(수용)**: 비-로컬-pin 멤버를 로컬 pin **프리픽스 안**으로 드롭하면(프리픽스는 §13.5 clamp 대상=로컬 pin 멤버 origin뿐)
  프리뷰가 프리픽스 사이에 잠깐 보였다 commit `floatLocalPins`가 프리픽스 **아래**로 snap-back한다 — 이는 **order 레벨의
  pre-existing snap-back**(마커 카드 재배치와 무관)이라 그대로 수용한다(로컬 pin 프리픽스 = sticky top zone).
- **경로**: `projectRowsCore` 버퍼링·재방출 + `flushMarkerCard`. 순서·힌트·hit-test·byte-identical·프리뷰=확정은
  헤드리스 단언이, 📌가 그룹 절대 최상단(마커 대표 카드 위)에 오는 것은 스크린샷 `MARU_FORCE_GROUP_LOCALPIN`이 고정한다.

### 13.7 위생 — 멤버→top-level 전이 시 `local_pinned:=false`(보강4)

멤버가 그룹 밖으로 나가면(ungroup·removeFromGroup·드래그 out) **`local_pinned:=false`** 로 클리어한다 — top-level 카드에선
로컬 pin이 무의미하므로 고아 stale 📌를 원천 차단한다. 단일 출처 위생 스윕 `clearStaleLocalPins`
(그룹 마커·최상위 카드의 `local_pinned` 클리어; 중첩 부모로 **재소속**된 멤버는 여전히 그룹 안 leaf라 유지 — floatLocalPins가 부모
프리픽스로 재float)를 세 전이 지점(`ungroupTab`·`removeFromGroupForTab`·`commitSidebarDragPreview`)이 각자 float **뒤** 1회 부른다.
commit 지점의 스윕은 §13.5 확정 clamp가 로컬 pin 멤버의 실제 eject를 막으므로 top-level 전이한 카드의 stale/desync를 지우는
**불변식 net**이다. 헤드리스: GL3(b1/b2/b3).

**그룹째 고정 해제 = 로컬 pin 리셋(사용자 피드백 정정 — 초기 §13.1 "완전 직교" 보강)**: 로컬 pin은 그룹째 고정(§12)과
**직교하는 축**이라 그룹을 고정하는 동안엔 보존된다(keystone §13.4 — float가 전역 partition에 안 흩뜨려짐). 다만 **`toggleGroupPin`
으로 그룹을 통째 해제(off)하는 순간**엔 그 그룹 subtree(중첩 자식 포함)의 멤버 `local_pinned`도 함께 **클리어**한다 — 사용자가
"그룹째 고정을 풀었는데 자식이 개별 📌로 남는다"고 리포트했고, 기대는 "그룹 고정만 풀리고 멤버는 **그냥 그룹 멤버로 복귀**(개별
📌 없음)"였다. 즉 **직교는 '고정 켜는 동안'의 성질**이고, **해제는 그룹을 깨끗한 멤버 상태로 되돌리는 리셋 시맨틱**이다(고정 카드가
개별 pin을 유지하는 것과 대조 — 그건 `Tab.pinned` 개별 축이라 그룹 토글과 무관). 위치는 float된 자리에 남되 `local_pinned=false`·
📌 억제로 평범한 멤버가 된다(재배열 없음). 배선: `toggleGroupPin`의 off 경로가 pin flip 루프에서 subtree `[mi, e)` 통째로
`local_pinned:=false`를 함께 세팅한다(중첩 자식 로컬 pin까지 리셋). 이후 `floatLocalPinsAllGroups`가 로컬 pin 0개를 보고 재배열을
안 해 멤버는 해제 직전 위치(마커 직후)에 남되 📌만 사라진다. 헤드리스: GL4(a) 재토글(해제 후 `local_pinned=0` 단언으로 초안의
survival 단언을 뒤집음) + `pin매트릭스 #2`(사용자 리포트 버그2 회귀 — 로컬 pin 멤버를 그룹째 고정→해제 시 멤버 `local_pinned=0`·
카드 📌 0 "그냥 그룹 멤버로 복귀").

### 13.8 범위 — **leaf 멤버 로컬 pin만**

1차 스코프는 **그룹 안 leaf 멤버 카드**의 로컬 pin이다. **subgroup-as-member**(자식 subgroup 마커 자체를 부모 멤버로서 로컬
pin = 자식 subtree 통째를 부모 멤버 구역 안에서 float)·**마커 로컬 pin**은 초안 §2.3↔§6 모순이 남아 **GL5 후속(범위 제외)**.
`stablePartitionSubtree`의 unit-aware 통째-이동은 이미 그 확장을 수용할 구조지만, 트리거·의미 확정은 GL5로 미룬다.

### 13.9 직렬화 — 새 키 `local-pinned`(순수 additive)

`workspace.v1` `tab` 라인에 **`local-pinned` 스칼라**(`pinned`/`group-*` 패턴). group_start와 **무관**하게(멤버 카드=group_start
==null) 밖에서 쓴다. **true만 기록·false=키 생략**(round-trip 고정점·옛 파일 flat 정상·옛 리더 미지 키 skip으로 forward-compat).
캡처/복원 왕복(`local_pinned`)도 additive. 로컬 pin 0개면 기존 파일 **byte-identical**.

### 13.10 단계 분해

[사이드바 그룹 단계 분해](plans/sidebar-groups.md)가 소유한다 — 단계와 완료 이력은 계획 문서 몫이다.
### 13.11 리스크

- **[최상] 멤버 `Tab.pinned`가 전역 파티션 신호**(§13.2 보강1) — 새 필드 `local_pinned`로 격리(전역 머신이 안 읽음)해 닫힘.
  이 함정이 저장을 재해석 대신 새 필드로 강제한 근본 이유.
- **[중] 배선 순서 모순**(초안 "normalize 직후" vs 복원 순서) — §13.4 "항상 `stablePartitionPinned` 뒤" 단일화(보강3)로 해소.
- **[중] 자식 subgroup 쪼개짐 = I2/I3 붕괴** — `stablePartitionSubtree` unit-aware(자식 통째)·재귀+포인터 재탐색(보강5)으로 방어.
- **[중] 드래그 게이트 누락 = SG8 위반** — `sidebar_drag_preview != null` early-return(보강6, normalize와 동일 게이트).
- **[하] 공존 시각 모호**(단일 글리프 U+1F4CC) — 헤더(그룹째)/카드(멤버 로컬) 위치 구별로 수용(§13.6 보강7).
