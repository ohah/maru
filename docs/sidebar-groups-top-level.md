# 사이드바 그룹 — top_level 재설계 (§14)

리딩 break 플래그 `Tab.top_level`로 한 핀 리전 안을 `[탑카드, 그룹, 탑카드, 그룹]` 서브파티션으로 일반화한 §2.1 재설계의 계약이다. 그룹 전체의 진입점은 [사이드바 그룹](sidebar-groups.md)이고, 이 문서는 그 §14를 소유한다.

> **절 번호는 파일을 넘어 이어진다.** 본문이 `§12.5`처럼 절만 가리키면 아래에서 소유 파일을 찾는다 — §1~§8·§10·§11 [sidebar-groups.md](sidebar-groups.md) · §9 [단계 분해](plans/sidebar-groups.md) · §12~§13 [그룹 고정과 로컬 pin](sidebar-groups-pinning.md) · §14 [top_level 재설계](sidebar-groups-top-level.md)

## 14. §2.1 재설계(top_level, 고정 탭↔그룹 인터리빙 + 선택 탭만 그룹)

§2.1의 **연속 파티션 I2**("한 번 그룹이 시작되면 리스트 끝까지 그룹 안 — 중간 최상위 복귀 없음")를 **서브파티션으로
일반화**한다. 한 핀 리전 안에서 `[탑카드, 그룹, 탑카드, 그룹]`처럼 **최상위 카드가 그룹 뒤/사이에도** 오게 하는 리딩 break
스칼라 `Tab.top_level`를 도입한다. 계층은 **pin ⊃ subregion(top_level) ⊃ group ⊃ nest** — pin(§12)이 리스트를
`[고정][비고정]` 최외곽 2리전으로, top_level이 각 핀 리전 **안**을 서브파티션으로, group(§2.1)·nest(SG5-3)가 그 안을
다시 나눈다. C2(§12)가 `Tab.pinned` 플립을 7 subtree-스캔 경계에 리셋 신호로 꿴 것과 **동형**으로, `top_level`을 **두 번째
리셋 신호**로 같은 7 경계에 한 줄씩 꿴다.

**두 사용자 요구를 함께 연다**: (요구1) 그룹 만들 때 **선택 탭만 그룹**(현재는 마커 뒤 전부 흡수) — §14.5. (요구2) 드래그로
**고정 탭↔그룹 순서 직접 변경** — §14.6. 사용자가 (요구2를) **model-2(드래그가 top_level을 직접 전이, SG8급)** 로 결정했다
(model-1=메뉴 전용 기각). **규모**: 초안은 GP1급으로 봤으나 model-2 채택으로 SG8 order-aware 가상화가 얹혀 **GP1+SG8급**이다
(초안 과소평가 정정, §14.11). 이 절은 **적대검증 3회 보강 5건**(§14.3~14.7의 굵은 "보강 N")에 더해, 구현 중 드러난 **두 숨은
요구**를 반영해 확정한 설계다: (a) **기존 mutation/render 경로의 top_level 경계 유지**(code-review PR#1197 — §14.8: inherit·
removal·normalize·guard·run_hi·accent)와 (b) **고정 정책**(사용자 규칙 "고정된 건 어디에도 흡수 안 됨" — §14.9: 고정 탭
top_level 강제·고정 그룹 nest 금지·고정 리전 clamp, 3레이어 대칭 preview=commit).

### 14.1 모델 — 옵션 B(리딩 `top_level` break 플래그)

소속·depth·subtree 경계가 전부 "위에서 가장 가까운 마커" 한 축으로만 파생되고 **그룹 끝을 저장하는 필드가 없어서**, 마커
뒤 카드는 무조건 그 그룹에 흡수됐다("사이"≠"안" 구분 불가). 세 대안 중 **옵션 B**를 택한다: break하는 카드에 `top_level`
스칼라(+sticky-reset). A(트레일링 `group_end`)는 드래그로 마지막 멤버가 이동하면 경계가 소실돼 뒤 top카드가 재흡수되는
orphan 위험, D(명시 `group` id/count)는 §2.1·§9가 지운 group-tab 정합을 부활시켜 기각. B는 (1) **C2 리셋 패턴 완전 동형**
(같은 줄에 `or top_level` 한 조건 — §12.4가 증명한 "각 경계 한 줄, 폭발 아님"), (2) **리딩 앵커 = 마커와 같은 결**(마커=push,
top_level=pop-all·최상위 복귀 → self-describing이라 삽입·승계·드래그 orphan 없음), (3) **additive·byte-identical**(default
false ⇒ 새 조건 전부 no-op).

**데이터 모델(§3 인접, `local_pinned` 선례)**: `Tab.top_level: bool = false`. `group_start==null`(비마커)·leaf 카드 전용
(마커의 "형제 top-level 그룹"은 이미 `group_depth=1` pop으로 표현하므로 마커엔 세팅 금지, §13.8 leaf-only 규율). pin과 직교
(항상 한 핀 리전 **안**의 서브파티션, pin 프리픽스 I1 불변).

**파생 규칙(sticky-reset)**: 마커는 기존대로 push(parent+1). 비마커 카드는 `top_level=true` **또는** 스택 비어있음이면
depth 0(최상위·스택 리셋 유지), 아니면 스택 top(그룹 멤버). 플래그는 break를 **개시**만 하고, 개시 카드가 스택을 비우면
뒤 비-플래그 카드는 빈 스택을 타 자동 top-level이며, 새 그룹은 새 마커로만 재진입한다(§2.1의 "중간 그룹 복귀 없음"은 유지 —
한 번 최상위로 나가면 재진입은 새 마커로). 예: `[A(마커,d1), a1(d1), TOP(flag,d0), x(d0), B(마커,d1), b1(d1)]` — `x`는
플래그 없이도 sticky top-level, `B`는 빈 스택이라 형제 top-level 그룹(d1).

### 14.2 데이터·직렬화·렌더 (SR1 — 자동 정합)

- **직렬화(§4·§13.9 동형)**: `workspace.v1` `tab` 라인에 `top-level` 스칼라. `group_start`와 무관하게 밖에서 쓰고, **true만
  기록·false=키 생략**(round-trip 고정점·옛 파일 flat 정상·옛 리더 미지 키 skip으로 forward/backward compat). 캡처/복원 왕복.
  top_level 0개면 기존 파일 **byte-identical**.
- **렌더(§12.8 자동)**: top카드 depth 0 ⇒ `pin_derived=false`·`local_pinned=false` ⇒ `sidebarRowShowsPin`이 개별 `tab.pinned`
  📌 표시(정확 — 개별 pin 카드로 복귀). **📌 렌더 코드 변경 0** — depth 0 파생이 자동 처리. **단 accent 막대 색은 예외**
  (code-review PR#1197, §14.8): `rebuildSidebar` accent 루프의 `current_group_color`는 헤더 row에서만 갱신되고 카드 순회에서
  상속되므로, **top_level 카드에서 `current_group_color:=0`으로 리셋**해야 색 그룹 뒤 top카드가 그 그룹 색을 물려받지 않는다
  (핀 리전 경계 리셋과 **동형**). 이 한 줄이 없으면 "색 그룹 뒤 최상위 카드"가 무색이 아니라 그룹 색 막대를 단다.

### 14.3 파생 7 경계 + 헬퍼 — GP1급 동형 (**보강 1**, SR1 완료)

`top_level`을 **7 subtree-스캔 경계**에 리셋/break 신호로 꿴다. **edge 경계**(스택 리셋)는 `or top_level`로 depth 0 복귀,
**break 경계**(subtree 끝 스캔)는 `if top_level break`(OR=min, 여러 break 중 최소 지점 승). **순서 충돌 없음**(검증 확인 —
edge는 리셋이라 pin 리셋 뒤 무순, break는 min이라 pin/marker break와 교환법칙).

| # | 함수 | 종류 | 추가 |
|---|---|---|---|
| 1 | `projectRowsCore` pass1 depth stack | edge | `... or tab.top_level` → 카드 depth 0 자동 |
| 2 | `projectRowsCore` pass2 cstack | edge | `... or tab.top_level` → 접힌 그룹 뒤 top카드 **shred 방지**(C2 #2 증상) |
| 3 | `effectiveDepthAt`(loop+idx 두 곳) | edge | 두 곳 `if top_level top=0` |
| 4 | `groupSubtreeEnd` | break | `if (t.top_level) break` — **그룹 끝 표현의 핵심** |
| 5 | `subtreeHasMatch` | break | `if (k>i and top_level) break` |
| 6 | `directCardCount` | break | `if (k>i and top_level) break` → `(N)` 배지 오염 방지 |
| 7 | `ghostOverlapsSubtree` | break | `if (top_level) break` |
| + | `enclosingGroupMarkerIndex` | 상향 클램프 | 상향 스캔 중 `if (top_level) return null`(**마커 return 앞**) |
| + | `tabIsInGroup` | 재작성 | `enclosingGroupMarkerIndex(i) != null`로 교체 |

**`tabIsInGroup` 정확성 버그 수정**: 현재 "리전 첫 마커 이후 = 그룹 안"은 인터리빙에서 **그룹 뒤 top카드도 "첫 마커
이후"라 true 오판** → "그룹에서 빼기" 메뉴 오노출·remove 오동작. `enclosingGroupMarkerIndex(i)!=null`(위 상향 클램프로
top카드는 null)로 교체해 닫는다. top_level=false면 enclosing(상향 최근접 마커)과 "리전 첫 마커 이후"가 동치라 byte-identical.

**동작 보존**: 전 탭 top_level=false ⇒ edge `or top_level`는 never-flip·break·클램프는 never-fire ⇒ 7 경계 no-op ⇒ 기존
그룹/pin/GL/SG8 투영과 **byte-identical**(GP1/GL1 identity 안전망). ✅ SR1에서 구현·헤드리스 고정("SR1: top_level이 7 파생
경계에서 최상위 복귀 서브파티션을 만든다").

### 14.4 C2 정합 재작성 — `normalizePinnedFromGroups`·`pinBoundariesAlignGroups` (**보강 2**, SR2 — 최고 위험대)

두 함수는 **구조 subtree** `[i,e)`를 pin **무시**로 스캔(형제/얕은 마커에서만 break)하고 **suffix-exclusion**(마지막 pin
일치 `last_match`까지 진짜 멤버, 꼬리는 다음 리전 top카드로 배제)으로 canonical화한다. 인터리빙에서 top카드가 **subtree
중간**(두 그룹 사이·같은 핀 리전)에 오면, 현재 구조 스캔이 top_level에서 break 안 해 top카드를 A 멤버 범위로 오인한다.

- **수정 = `top_level` 하드 break를 구조 subtree end 스캔에 추가**(`groupSubtreeEnd`의 새 break와 정합). 그러면 진짜 멤버
  범위가 top카드를 절대 포함 안 하고, suffix-exclusion 꼬리 배제(핀 경계, soft)와 **공존**한다. `pinBoundariesAlignGroups`도
  top_level 인식 — 그룹 뒤 top카드가 subtree 중간을 자르는 **I3 위반을 위음성 없이 검출**하는 게이트다.
- **⚠️ exact-full-rewrite 폐기(code-review PR#1197 정정)**: SR2 초안은 suffix-exclusion 대신 **exact-full-rewrite**
  (`[i+1, break)` 전량 무조건 재기록)를 택했으나, 이는 **pin 리전 경계를 넘어** 비고정 tail 카드
  (`[고정그룹][비고정 x][top_level]`의 x)를 `pinned=1`로 **오염·persist**시킨다(구조 스캔이 pin flip에서 break 안 하므로 `[i+1,e)`가
  리전을 가로지름). "I1 uniform이라 shred no-op"이라던 초안 논거는 **인터리빙에서 "한 리전에 여러 pin"이 가능**해 무효다. →
  **suffix-exclusion 유지가 정답**: top_level 하드 break로 멤버 범위 끝을 정하되 **재기록은 pin flip도 존중**(리전 경계 넘으면
  중단). 같은 리전 내 sandwiched desync는 여전히 흡수·치유. `pinBoundariesAlignGroups`도 동형(위음성 없이 I3 검출). SR2(a)/(b)
  테스트는 이 계약(꼬리 top카드 pin 유지)으로 재작성.

### 14.5 createGroup write — "선택 탭만 그룹" (**보강 3**, 요구1, SR3)

SR3 이전 `beginGroupForTab`은 마커만 심고 **마커 뒤 전부를 위치 파생으로 흡수**했다(요구1 위반). "선택 탭만 그룹" = 마커 심은
뒤 **선택 범위 다음 첫 비선택 탭에 `top_level:=true` write**(그 카드부터 최상위 복귀 → 그룹이 선택 탭에서 끊김). 마커로
승격되는 카드가 top_level이었으면 leaf-only 규율상 `top_level:=false` clear(카드→마커 전이). 파생 스택 리셋(`beginGroupForTab`
inline depth stack에 `or t.top_level`)도 이 단계에서 함께.

- **시그니처(구현)**: `beginGroupForTab(tab, kind: GroupCreateKind{nested|sibling}, break_next: bool)`. 프로덕션 진입점
  `createGroupForTab`(=`.nested, true`)·`createSiblingGroupForTab`(=`.sibling, true`)은 **`break_next=true`**로 다음 leaf
  탭에 top_level break를 심어 "선택 탭만 그룹"을 연다. **`break_next=false`**는 SR3 이전 "마커 뒤 전부 흡수"를 재현하는
  **테스트/스크린샷 전용 훅**(`createGroupAbsorbForTab`/`createSiblingGroupAbsorbForTab`) — 다중 멤버 그룹으로 그룹-무관
  기능(중첩·로컬핀·그룹핀·드래그·헤더)을 검증하는 기존 테스트가 쓴다(전 탭 top_level=false → 인라인 리셋 never-fire =
  byte-identical). **엣지 안전(break_next 시)**: 다음 탭 없음(마커=리스트 끝)·다음이 이미 마커(연속 그룹)·다음이 다른 핀
  리전(pinned 불일치)이면 write 생략(이미 경계가 있음). write는 `normalizePinnedFromGroups`/`floatLocalPinsAllGroups` **전에**
  해야 그들이 top_level break를 인식해 멤버 범위를 정확히 잡는다.

- **정책 결정(다중선택 메커니즘 부재)**: 현재 우클릭은 단일 탭 대상이다. 두 안 — (a) **연속 range 선택**(shift-click 등
  다중선택 UI 선결) 후 그 범위만 그룹, (b) **단일 탭 + 뒤 탭 promote**(선택 탭 하나를 그룹으로, 바로 뒤 탭에 top_level write =
  "이 탭만 그룹"). 1차는 (b)가 메커니즘 추가 없이 요구1을 만족(SR3에서 확정).
- **중간 promote cascade는 option-B(§14.1) 고유(SR5 명문화)**: 다중 멤버 그룹 `[A(마커), m1, m2, m3]`에서 **중간 멤버** m2를
  "여기서 최상위로 분리"(promote-in-place)하면, m2에 `top_level:=true`가 sticky break를 개시해 **뒤 멤버 m3도 그룹에서 끊긴다**
  (m3는 플래그 없이도 빈 스택을 타 자동 top-level — §14.1 sticky-reset). 즉 promote는 "이 카드 하나"가 아니라 "이 카드**부터**
  그룹 끝까지"를 최상위로 되돌린다. 이는 **리딩 break 플래그(option B)의 직접 귀결**이다 — 트레일링 `group_end`(A안)였다면 중간
  카드만 뽑고 뒤는 그룹에 남길 수 있었겠지만, A는 드래그 시 경계 소실 orphan으로 기각됐다(§14.1). **마지막 멤버 promote**는
  cascade 대상이 없어 정확히 그 카드만 그룹 밖 top카드가 된다(그래서 "빈 gap 첫 인터리브"의 메뉴 경로이자, SR5 드래그 gap
  제스처(§14.6)와 같은 최종 상태를 만든다). 사용자가 "하나만" 빼려면 **removeFromGroup**(그룹 밖 이동, cascade 없음)을 쓴다 —
  두 eject flavor의 cascade 유무 차이가 §14.7 divergence의 실동작 측면이다.

### 14.6 model-2 드래그 — `top_level` 전이 (**보강 4**, 요구2, SR4, SG8급)

**model-2 채택(사용자 결정)**: 드래그가 `top_level`을 **직접 전이**한다 — 카드를 그룹 사이로 끌면 드롭 컨텍스트로 top_level을
세팅(고정 탭↔그룹 순서를 인터리빙으로 직접 조작). 이때 top_level은 **드래그 중 변하는 소속 결정 비트**가 되어, pin(드래그 중
불변)·group_depth(이미 SG8b에서 가상화)와 달리 **가상화가 필요**하다:

- `VirtualLayout`에 **`top_level[]` 병렬 배열** 추가(order·group_depth와 나란히) + card `DropPlan.top_level` + `simulateDrop`
  순열이 top_level도 재배치 + 프리뷰가 가상 배열 read + **프리뷰=확정 등가 테스트**(SG8 order-aware 불변식). 이것이 "위치 파생
  override가 SG8 order-aware와 충돌"의 실체이며, model-2는 그 이중경로 비용을 **감수**한다(사용자가 직접 조작 UX를 택함).
- **3레이어 대칭(cardDropPlan → simulateDrop → commitSidebarDragPreview, 프리뷰=확정)**: 카드 드래그의 top_level 전이는 세
  레이어가 **같은 조건**을 쓴다 — ① `cardDropPlan`(mouse 핸들러·헤드리스 단일 출처)이 커서 y로 `DropPlan.top_level`을 산출
  (그룹 뒤 gap=`sidebarCardDropAfterGroup`·타깃 최상위=`sidebarCardDropTopLevel`·고정 소스=강제 true), ② `simulateDrop`이 가상
  배열에 그 전이를 **meaningfulness 게이트**(`hasGroupMarkerAboveInRegion` — 리전 안 위에 그룹 마커가 있어 flag가 흡수 방지에
  **실제 필요**할 때만 write; leading/flat/top-run은 no-op=byte-identical)와 AND해 굽고, ③ `commitSidebarDragPreview`가
  **post-move self.tabs**에 같은 게이트로 실제 write한다(재계산 금지 — 마지막 plan 재사용). 이 3레이어가 어긋나면 "프리뷰는
  최상위인데 확정은 흡수" 같은 divergence가 나므로 등가가 게이트다.
- **`sidebarGroupDropBoundary` 인터리빙(SR4)**: top카드가 그룹 뒤/사이에 오면, target이 **그룹 밖 top카드**
  (`enclosingGroupMarkerIndex==null`)일 때 그 카드가 속한 **최상위 run**을 한 단위로 보고 그룹을 그 앞/뒤로 끼운다(그룹↔탭 순서
  교환). run 경계는 `run_lo`(위로 스캔이 top_level 개시 카드에서 정지)와 **대칭으로 `run_hi`도 다음 `top_level` 카드에서 정지**
  (code-review PR#1197 — 두 인접 top카드가 한 run으로 잘못 병합되면 두 top카드 사이 그룹 드롭이 어긋난다). 리딩 카드(리전
  첫머리·플래그 없음)는 옛 `first_group` clamp로 폴백해 SG5-1 byte-identical.
- **드래그 대상이 접힌 그룹이면 프리뷰=접힌 헤더만(`dragged_collapsed`, SG8g)**: SG8c의 고스트 force-emit(접힌 그룹 안 드롭 시
  카드 사라짐 방지)이 접힌 그룹을 **통째로 드래그**할 때도 subtree를 강제 방출해 펼쳐 보였다. `PreviewCtx.dragged_collapsed`
  (그룹 통째 드래그 && origin 마커 `group_collapsed`)로 **대상/타깃을 구분**: 대상=접힌 그룹이면 subtree force-emit·안쪽 헤더
  flip을 억제해 **접힌 헤더 한 줄만**, 타깃=접힌 그룹(카드를 그 안에 드롭)은 force-emit 유지(사라짐 방지). §14.6과 직교하는
  드래그 렌더 마감이나, 인터리빙 드래그의 실앱 UX 정합이라 여기 명시한다.
- model-1(메뉴 전용·드래그 불변·sticky-reset로 기존 run 넣기/빼기 공짜)은 SG8 divergence를 구조적으로 회피하지만 "드롭으로
  그룹 밖으로 빼면 자동 top카드"의 완전 positional UX를 못 준다 — **기각**. (SR1~3은 model 무관하게 공유되고, model-2 가상화는
  SR4 단독으로 얹힌다.)

**SR5 — "그룹 뒤 빈 gap" 첫 인터리브(요구2 완성)**: SR4는 카드를 **기존 top카드 옆**으로 끌 때만 top_level 전이를 열었다
(`sidebarCardDropTopLevel` = 타겟이 최상위면 true). 그런데 두 그룹 `[A, B]` 사이에 아직 top카드가 없으면 **row 모델에 그 빈
gap을 가리킬 row가 없어**(연속 파티션 — 그룹 사이 빈 gap row 없음) 드래그로 **첫** top카드를 못 만들었다. SR5가 이 엣지를
`sidebarCardDropAfterGroup`으로 닫는다: 커서가 **최상위 그룹의 마지막 멤버 카드**(또는 **접힌 최상위 그룹 헤더**)의 **아래
경계 영역**(하단 40%, `dragInRowLowerBoundary` = rowTop/rowHeight 가변 높이 누적 공유)에 있으면, 드래그 카드를 그 그룹의
**subtree 끝**(그룹 밖 gap)에 `top_level:=true`로 착지시킨다. **위치 계산은 접힌 헤더 드롭(`sidebarGroupDropTargetTab`)과
동형**(`from<m`이면 `j-1`·아니면 `min(j, len-1)` 방향 보정)이라 새 위치 로직이 아니고, **top_level만** 다르다(멤버 흡수 대신
그룹 밖 복귀). 착지 후 commit이 SR4 카드 경로와 **같은 `hasGroupMarkerAboveInRegion` 게이트**로 실제 write를 굽는다 →
프리뷰=확정 불변식 그대로. **제약**: (1) 같은 그룹 안 카드(`from∈[m,j)`) 드래그는 발화 안 함(그룹 안 재정렬 — gap-promote는
밖에서 끌어올 때만), (2) 펼친 헤더 아래 경계는 발화 안 함(첫 멤버와 모호 — 접힌 헤더만), (3) 중첩은 **최상위 그룹 끝만**
(`topLevelGroupMarkerIndex` 상향으로 중첩 subgroup 마지막 멤버여도 부모 최상위 그룹 끝 기준 — 중첩 gap의 "부모 depth 복귀"는
§14.7 sticky-reset 제약상 불가라 top-level 복귀만). 발화 조건이 아니면 기존 SR4 경로로 폴백해 **byte-identical**. **메뉴 경로
대안**: 마지막 멤버 "여기서 최상위로 분리"(promote-in-place)도 같은 최종 상태를 만든다(§14.5 cascade 문단) — 드래그/메뉴 두
경로가 같은 gap top카드로 수렴한다.

### 14.7 pinned × top_level 정합·eject flavor (**보강 5**, SR2/SR3 교차)

핀 리전 **안**의 서브파티션이라 `pinned=1·top_level=1` 상태가 가능하다(고정 리전 안 그룹 뒤 고정 top카드). 정합 divergence
2건: (1) **서브파티션 상태** — pin 프리픽스 I1은 여전히 최외곽이고 top_level은 그 안쪽이라 직교하지만, `normalize`/`align`이
고정 리전 안에서 top_level을 하드 break로 봐야 멤버 범위가 정확(§14.4와 같은 수정). (2) **eject flavor divergence** —
`removeFromGroupForTab`(맨 위 이동, 기존)은 §12.7 보강4로 **unpin**하지만, "여기서 최상위로 분리"(제자리 top_level:=true,
신규 promote)는 **pin을 안 건드린다**(고정 top카드로 남음). 두 flavor의 pin 처리 차이를 명문화하고 UX에서 구분(§14.5 미러:
제자리 vs 이동). (`removeFromGroupForTab`의 고정 경로가 move 전 unpin·비고정 리전 시작으로 moveTab하는 상세는 §12.7 보강4.)

### 14.8 기존 경로의 top_level 경계 유지 (code-review PR#1197 — 숨은 요구)

`top_level`은 **리딩 경계 플래그**(마커=push와 같은 결의 self-describing 앵커)라, tabs/마커/렌더를 건드리는 **모든 기존
mutation/render 경로가 이 경계를 유지**해야 한다. `/code-review max`가 §2.1 재설계 초기 구현이 이 경계를 유지 안 해 **무관
워크스페이스 그룹 재부모화**·**비고정 카드 고정 오염(디스크 persist)**을 낸다는 걸 잡았다 — 이게 §2.1 재설계의 **숨은 요구**다.
6+3건을 한 줄씩 꿴다(각 revert-fail 헤드리스 CR#1~6):

- **inheritGroupMarker `!next.top_level`(leaf-only 승계 가드)**: 마커 승계(closeTab·removeFromGroup 공유)는 다음 탭이
  `top_level`이면 마커를 **안 넘긴다**(false 반환 → 호출자가 마커 free = 그룹 소멸). top_level 카드는 "그룹 밖 최상위 복귀"를
  개시하는 경계 홀더라 그룹 헤더가 될 수 없다(마커=leaf-only §13.8 위반). 가드가 없으면 **단일 카드 그룹**의 마커가 뒤 top카드로
  넘어가 그 top카드를 오승격하고 sticky follower들을 무관 그룹으로 **재부모화**한다.
- **top_level 카드 제거 시 경계 재확립(closeTab + commit 드래그, finding #2)**: 닫는/이동하는 카드가 top_level **경계 홀더**면
  제거 후 그 뒤 sticky follower에 `top_level:=true`를 **재확립**한다 — 경계를 안 넘기면 follower가 앞 그룹에 흡수(재부모화)된다.
  게이트: follower가 같은 핀 리전 leaf(비마커·아직 top_level 아님)이고, 위(앞)에 이 리전 그룹이 있어(`enclosingGroupMarkerIndex
  (index-1)!=null`) 실제로 흡수될 때만. **`simulateDrop`이 rotateMove 전 같은 조건·같은 지점에 미러**해 프리뷰=확정이고,
  commit은 실제 이동이 없으면(`landed==origin`, 제자리 드롭) spurious flag를 되돌린다(경계 소실이 없으므로).
- **normalize/align: exact-full-rewrite → suffix-exclusion(finding #3, §14.4 상세)**: 재기록이 **pin flip을 존중**(리전 경계
  넘으면 중단)해 `[고정그룹][비고정 x][top_level]`의 x가 `pinned=1`로 오염·persist되지 않게 한다. 같은 리전 내 sandwiched
  desync는 여전히 흡수·치유. `pinBoundariesAlignGroups`도 동형(위음성 없이 I3 검출). §14.4가 이 계약의 단일 출처다.
- **removeFromGroupForTab: `ix<fm0` 가드 → `!tabIsInGroup`(enclosing 기반)**: 옛 "첫 마커 이전" 가드는 인터리빙의 **그룹 뒤
  top카드**를 out-of-group으로 못 봤다(그 카드는 `ix>=fm0`이지만 enclosing 마커가 없어 실제론 그룹 밖). `!tabIsInGroup`으로
  바꿔 top카드·top-level run·그룹 전무를 모두 밖으로 정확 판정 → **그룹 뒤 top카드 remove = no-op**(흡수·unpin 방지). 우클릭
  노출 조건(`tabIsInGroup`)과 no-op 판정이 같은 단일 출처라 desync 없음.
- **sidebarGroupDropBoundary run_hi `!top_level`(run_lo 대칭)**: 최상위 run 상단 스캔 `run_lo`가 top_level 개시 카드에서 멈추는
  것과 **대칭으로 `run_hi`도 다음 top_level 카드에서 정지** — 두 인접 top카드가 한 run으로 잘못 병합되면 **두 top카드 사이 그룹
  드롭**이 어긋난다(그룹↔탭 순서 교환 붕괴).
- **accent 색: top_level에서 `current_group_color` 리셋(§14.2 상세)**: 색 그룹 뒤 top카드가 그룹 색 막대를 물려받지 않게
  accent 루프가 핀 리전 경계 리셋과 **동형**으로 top_level에서 색을 0으로 되돌린다.

**효율(정답 — 스타일 아님)**: (1) **`topLevelGroupMarkerIndex` O(depth·n) → O(n)** — 옛 `while effectiveDepthAt(mi)>1` climb이
매 반복 `effectiveDepthAt`(O(n))를 재계산했다(드래그 프레임 핫패스). effectiveDepthAt과 **동형 단일 스캔**으로 마커 인덱스를
스택에 함께 쌓아 바닥(depth 1 마커) 1회 반환. (2) **cardDropPlan 중복 `dragTargetSlot` 제거** — 프리뷰 시프트 보정이 없으면
(`y_esc==y_px`) `raw_esc=raw_row` 재사용. (3) **sidebarCardDropAfterGroup `groupSubtreeEnd` 재사용** — 카드 branch는 위 가드가
이미 `groupSubtreeEnd(tl)==c.tab+1`을 확립하므로 j를 재계산하지 않고 `c.tab+1` 재사용(헤더 branch만 계산).

### 14.9 고정 정책 — 고정 요소는 흡수 불가 (사용자 규칙)

**사용자 규칙**: "고정된 애들은 어디에도 흡수되면 안 된다." pin이 **최외곽 리전**(pin ⊃ subregion ⊃ group ⊃ nest)이라, 고정
요소는 그 안쪽 계층(그룹·중첩)에 절대 안 빨려든다.

**근본 정정(commit divergence 아니었음)**: 처음엔 commit이 잘못이라 봤으나 commit은 이미 `plan.top_level`을 replay한다. 실증상은
`cardDropPlan`이 **드롭 위치 따라 top_level을 다르게** 냈다 — 고정 탭을 그룹 멤버 위치에 드롭하면 위치 판정이 `false`→흡수(중간
프레임 로그의 `true`는 up 직전 최종이 멤버라 `false`로 뒤집힘). 그래서 **위치 판정을 pin으로 override**하는 게 해법이다.

세 규율을 **레이어 대칭(preview=commit)**으로 편다:

- **고정 탭 = top_level 강제(그룹 흡수 금지)**: `cardDropPlan`이 `source_pinned`이면 드롭 위치와 **무관하게** `top_level=true`를
  OR한다(위치 기반 `sidebarCardDropTopLevel`=그룹 멤버 false를 덮음). `simulateDrop`(프리뷰)·`commitSidebarDragPreview`(확정)도
  **같은 `source_pinned`를 OR** — **3레이어 대칭**이라 프리뷰=확정. self.tabs 불변이라 origin의 라이브 pinned가 드래그 내내
  안정하고, commit은 moveTab **전에** pinned를 캡처(회전으로 origin이 소스가 아니게 되므로). 단 top_level 강제도 흡수 방지가
  meaningful할 때만 실제 write(`hasGroupMarkerAboveInRegion` AND) — flat/leading은 no-op=byte-identical.
- **고정 그룹 = nest 금지(sibling만)**: `groupNestPlan`이 드래그 마커가 `pinned`면 **`return null`**(Cmd nest여도 형제 폴백).
  고정 그룹은 고정 리전 안 **독립(top-level) 그룹**으로만 존재하며 다른 그룹의 자식이 될 수 없다. 이는 다른-pin-리전 차단(GP3
  §12.6)보다 **강한 규칙**(같은 고정 리전 안 고정↔고정 중첩도 금지)이라 GP3 체크보다 **먼저** 건다.
- **고정 탭/그룹 = 고정 리전 `[0, pinned_count)` clamp**: `clampMoveToGroup`(카드)·`clampGroupMoveToRegion`(그룹)이 착지
  위치를 고정 리전에 가둔다(top_level 강제와 **별개** 축 — 하나는 "그룹에 안 흡수", 하나는 "비고정 영역에 안 섞임"). 고정
  소스는 `[0, pinned_count]`로, 비고정 소스는 `[pinned_count, len]`로만. 프리뷰/확정 divergence 없게 **plan 산출부 단일 clamp**
  (이동 함수에 안 넣음, SG8 §12.6과 동일 규율).

**대칭 정리**: 고정 **탭** = cardDropPlan/simulateDrop/commit **3레이어** top_level OR. 고정 **그룹** = groupNestPlan nest 차단.
**리전** = clamp 2함수. 셋 다 preview=commit이라 실앱 드래그가 프리뷰대로 확정된다. **검증**: 헤드리스 SR-PIN1~5(전체 마우스
경로 preview→commit, commit 직접 호출 아님)·부정검증, commit MARU_DEBUG 로그(`src_pinned`·`top_level_written`).

### 14.10 단계 분해

[사이드바 그룹 단계 분해](plans/sidebar-groups.md)가 소유한다 — 단계와 완료 이력은 계획 문서 몫이다.
### 14.11 규모·리스크

- **규모 = GP1+SG8급**(초안 GP1 과소평가 정정): 코어 7 경계 + effectiveDepthAt(2) + enclosingGroupMarkerIndex + tabIsInGroup +
  normalize + align(SR2) + beginGroupForTab(SR3) — 대부분 한 줄 `or/break/return null`. **+ model-2 SG8 가상화**(`top_level[]`
  병렬 배열·`simulateDrop` 순열·프리뷰=확정 등가, SR4)가 얹혀 GP1 단독을 넘는다. **+ 직렬화 4 + Tab 필드 1 + UX(action·dispatch·
  catalog·우클릭)**.
- **[최상] SR2 — suffix-exclusion × top_level 하드 break 정합**(§14.4): canonical·idempotent 공존. exact-full-rewrite는
  pin 리전 넘어 비고정 tail 오염(code-review PR#1197 정정) → **suffix-exclusion 유지·재기록이 pin flip 존중**. pin 축은 항상 존재하므로 SR2는 남는다.
- **[중] model-2 SG8 이중경로**(§14.6): top_level이 드래그 중 변하는 소속 비트라 가상화 필요. 프리뷰=확정 등가 테스트가 게이트.
- **[중] tabIsInGroup 정확성 버그**(§14.3): 조용한 오노출/오동작 — enclosing 기반 교체로 닫힘(SR1 완료).
- **[중] 기존 경로 경계 유지 누락(code-review PR#1197, §14.8)**: top_level 리딩 플래그를 기존 mutation/render 경로가 유지 안 하면
  **무관 그룹 재부모화·비고정 카드 고정 오염(persist)**. 6+3건을 한 줄씩(inherit·removal·normalize·guard·run_hi·accent + 효율 3)
  꿰어 닫힘 — §2.1 재설계의 숨은 요구라 회귀 게이트(CR#1~6 각 revert-fail)로 잠갔다.
- **[중] 고정 정책 3레이어 대칭(§14.9)**: 고정 탭 top_level 강제가 cardDropPlan/simulateDrop/commit **세 곳**에 흩어져 하나라도
  빠지면 프리뷰≠확정("프리뷰는 최상위인데 확정은 흡수"). 셋 다 같은 `source_pinned` OR + SR-PIN1~5 전체 마우스 경로 등가가
  게이트. 근본 정정: **commit divergence 아님**(commit은 plan.top_level 이미 replay) — 실증상은 cardDropPlan 위치 의존 편차.
- **[하] leaf-only guard·스택 리셋 배치**: 마커·top-run 뒷카드에 top_level 세팅 금지(§13.8 선례), 리셋을 마커/카드 분기 **전**에
  (top카드가 depth 0 받고 뒤 카드 sticky) — GP1 pin 리셋과 같은 위치라 패턴 검증됨.
