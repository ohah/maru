# page-aligned storage (§11)

[초기 아키텍처](../architecture.md)가 말하는 스크롤백 storage의 종착지다. 현 모델과 페이지 모델의 차이, 마이그레이션 옵션, P0 측정 결과와 그에 근거한 진행 결정을 담는다. 하위 설계 일부는 **합의 대기**이고 일부는 **불가로 정정**됐다 — 각 절 제목이 그 상태를 적는다.

> **절 번호는 파일을 넘어 이어진다.** 본문이 `§7`처럼 절만 가리키면 여기서 소유 파일을 찾는다 — §1~§3·§5 [terminal-core-decomposition.md](../terminal-core-decomposition.md) · §0·§4·§6~§9 [분해 기록](terminal-core-decomposition.md) · §10 [Screen struct fold](screen-struct-fold.md) · §11 [page-aligned storage](page-aligned-storage.md)

## 11. page-aligned storage (architecture.md 진짜 최종 골 — 설계·합의 대기)

architecture.md §192/§211 종착지: "scrollback/page 책임을 별도 모듈로 분리 + cursor·grid 완전한 Screen에 **page-aligned storage**를 얹는다"(+ §180 mmap/VirtualAlloc backing). 방향 A·B로 Screen 토대가 완성됐으니(grid+sb+cursor+saved_cursor 전부 Screen 귀속) 이제 그 storage 레이아웃을 바꾼다. **A·B와 성격이 다르다 — 순수 리팩터가 아니라 메모리 레이아웃·할당·성능 변경**이라 동작·perf 검증 폭이 넓고, **측정으로 전제 확인 후 단계적**으로 간다(§11.4).

### 11.1 현 모델 vs 페이지 모델

- **현재**: 활성 grid = 평평 `cells: []Cell`(rows×cols 연속) + 병렬 `wrapped`/`prompt_marks`. 스크롤백 = `Scrollback.ring: []?[]Cell`(행마다 `allocator.dupe` heap) + 병렬 메타 + head/count/cap + lazy rewrap. **활성과 스크롤백의 저장 모양이 다르다.**
- **페이지 모델**: 고정 용량 `Page`(연속 rows×cols cells + 메타) 덩어리들을 리스트로 잇고, 활성 화면 = 리스트 꼬리 N행, 스크롤백 = 그 앞 전부(통합). 페이지 pool/freelist로 재사용, 바이트 단위 메모리 bound.

페이지 저장이 주는 것: ① 스크롤백 push의 per-row alloc(dupe) churn 제거(페이지당 1 alloc) ② 활성 scroll의 O(rows) memmove를 페이지 경계 포인터 이동으로 ③ 바이트 단위 메모리 bound(현 행 수 cap) ④ 활성+스크롤백 통합 ⑤ mmap zero-fill backing(§180).

### 11.2 maru 적응 — Ghostty 복잡도의 대부분은 불필요

레퍼런스 Ghostty PageList는 ~19000줄(PageList 14710 + page 3918)이지만, **maru는 그 핵심 복잡도 대부분을 안 짊어진다**(블래스트 분석 확인):

- **Pin 불필요**: maru 커서는 순수 `(row,col)` u16이 전 코드(262곳)에 박혀 있고 포인터 커서가 없다. Ghostty의 Pin(page ptr+offset+tracked pin pool, reflow마다 갱신) 인프라 전부 생략 — resize 시 지금처럼 `(row,col)` clamp/재계산만.
- **offset 기반 직렬화 불필요**: maru는 mmap-to-disk COW/serialize를 안 하므로 페이지는 평범한 포인터 기반 struct로 충분(Ghostty의 `Offset(T)` 자료형 전부 생략).
- **renderer 경계 이미 격리**: `RenderSnapshot`은 활성을 zero-copy slice, 스크롤백 뷰는 memcpy로 materialize(스크롤 시 이미 그렇게 함). 페이지 저장이면 뷰포트를 flat로 materialize만 하면 되고 renderer·selection(`absRow` 추상)·snapshot API는 **불변**.
- **style pool 생략**: style은 `Cell`에 inline(self-contained)이라 Ghostty식 page-local style intern pool은 채택 안 함.
- **grapheme 저장은 전역 dedup store(page-local 회수는 ❌ 보류)**: 처음엔 grapheme도 별도 `grapheme_store`(HG 작업)라 page pool을 생략했고, 활성 grid가 page로 가는 B 단계에서 grapheme을 **page-local로 옮겨 구조적 회수**를 얻으려 했다(원래 결정). **그러나 그 vehicle인 B가 A2와 구조적으로 충돌해 불가(§11.10)**해지며 page-local 회수는 보류됐다 — dedup된 전역 `grapheme_store`(HG dedup, append-only)가 distinct cluster 수로 메모리를 bound하는 **standing 답**이고(측정된 병목 없음), 재개가 필요하면 활성 grid를 안 건드리는 split 모델(스크롤백만 page-local)로 간다. 상세·정정 근거는 §11.8 §595.

→ maru `Page ≈ { rows, cols, cells: []Cell, wrapped: []bool, prompt_marks: []RowPrompt }` 한 덩어리 + pool. 훨씬 작다.

### 11.3 마이그레이션 옵션 (블래스트: reflow/rewrap ~430줄이 비용의 대부분)

| 옵션 | 범위 | 비용(대략) | 위험 | payoff |
|------|------|-----------|------|--------|
| **A 스크롤백만 페이지화** | 활성 grid 평평 유지, `Scrollback.ring`을 페이지 리스트로 | ~150줄(pushScrollback·rewrapScrollback·scrollbackRow 접근자 뒤) | 중 | per-row dupe churn 제거 + 바이트 bound. 활성 hot-path·활성 reflow 불변 |
| **B 전면 통합** | 활성+스크롤백 한 PageList, 활성=tail | ~400~600줄, reflow/print/scroll 전면 | 높음(직접 인덱싱→page-fetch perf 회귀 가능) | 전부(scroll O(1) 포함) |
| **C 하이브리드(권장)** | A를 1단계로 굳히고, 측정 뒤 B를 후속 단계로 | A + (측정) + B | 단계별 통제 | A 즉시, B는 게이트 뒤 |

### 11.4 P0 측정 결과 + scale 단서 (no-defensive-code 정신 — 추측 말고 측정)

**P0 측정(로컬, cap 1K~10K)**: `core_large_output` 344ms/100k줄(3.44µs/줄), 스크롤백 push는 steady-state에 슬롯을 같은 폭 `@memcpy`로 재활용해 **0 할당**. 메모리 probe(counting allocator): `Cell`=44B, 스크롤백 메모리는 99.7%+가 raw cell 데이터(cap×cols×44)이고 **할당자 오버헤드 0.1~0.6%**. → **cap 1K~10K에선 페이지화의 perf·메모리 이득이 사실상 0.**

**그러나 목표는 cap "수백만 줄"**(사용자 제품 목표) — 이 scale에서 전제가 뒤집힌다:
- ring `[]?[]Cell`은 **행마다 독립 할당** → 100만 줄 = **100만 할당**(메타데이터·단편화 수십 MB, setCap이 100만 포인터 O(cap) 재구성). 페이지 모델은 ~`cap/ROWS_PER_PAGE` 페이지로 할당 압력을 수천분의 1로 낮춘다.
- 100만 줄을 RAM에 다 올리는 비용(1M×cols×44 = 수 GB)은 Cell 그대로면 비현실적 → **mmap backing(콜드 히스토리 OS 페이징)이 핵심 enabler**이고, 그 전제가 page 저장이다.

→ **결론: 페이지화는 1K~10K에선 불필요, "수백만 줄" 목표에서 정당화된다.** 측정이 scale 의존성을 드러냈다(작은 cap 측정만으로 "보류" 결론을 내면 목표를 놓침).

### 11.5 리스크

- **reflow 재작성이 정확성 위험 최고**(soft-wrap·wide-glyph spacer·prompt_mark 경계 — 페이지 경계까지 얹힘). 단계마다 누적 `/code-review max` + 기존 reflow 테스트 보존.
- **mmap backing은 platform 경계**(§180: allocator 주입 + 특수 영역만 직접) — terminal층이 mmap 직접 호출하면 이식성/경계와 충돌. 도입 시점·책임 위치 별도 결정.
- **hot-path perf 회귀**(page-fetch 오버헤드)가 perf 게이트 위협.

### 11.6 결정 — 진행(basis: 수백만 줄 스크롤백 제품 목표)

**Basis(document-basis-and-decision)**: 제품 목표가 **"수백만 줄 스크롤백을 읽게 한다"**이다. §11.4가 보였듯 작은 cap(1K~10K)에선 페이지화가 무의미하지만, 수백만 줄에서는 (a) per-row 할당 압력(100만 할당→수천 페이지)과 (b) mmap backing 전제로 **정당화된다**. 이 basis가 없으면 보류가 맞고, 있으면 진행이 맞다 — scale 의존 결정.

**중요(정직)**: A1 하나로 수백만 줄이 viable해지지 않는다. 순서가 필요하다:

| 단계 | 내용 | 수백만 줄 기여 |
|------|------|--------|
| **A1 ✅** | `Scrollback.ring`(행마다 `dupe`) → **page 리스트 + pool**. 행 연산은 `pushScrollback`·`scrollbackRow*`·`rewrapScrollback*` 접근자 뒤 캡슐화(공개 API·renderer·selection 불변). 동작 보존(row-count cap·eviction·setCap 반환 그대로). **uniform-width 페이지**(폭 변경 시 새 페이지) | **할당 100만→~수천**, mmap-ready 토대 |
| **A2 ✅ 가변폭/trim** | 페이지 행을 가변폭(per-row desc, hard 행 끝-공백 trim)으로 → 전형 출력 메모리 절감 | 메모리 viable |
| **P4 ✅ mmap backing** | cell arena를 `std.heap.page_allocator`(mmap/VirtualAlloc, §180) → demand-commit + 콜드 OS swap(RAM 미점유) + free 즉시 반납 | RAM 한계 돌파 |
| **B** ❌ **불가(미진행)** | 활성 grid 통일 PageList — **A2(가변폭 스크롤백)와 구조적 충돌로 불가**(§11.10 정정). 활성=고정폭 mutate vs 스크롤백=가변폭 packed 불변. ring 대안은 perf~0. grapheme page-local도 vehicle(B) 상실 → 측정 시 split 모델 후속(§11.8) | — (A2 메모리 이득과 동시 불가) |

> **§11 종료**: 수백만 줄 목표는 **A1+A2+P4로 달성·초과**(할당 ~128×↓·메모리 ~5.8~94×↓·history>RAM). full B(Ghostty식 통일)는 A2와 양립 불가(§11.10)이고 ring/grapheme-recovery는 측정 이득 없어 보류. architecture.md §211은 maru가 A2로 택한 "가변폭 스크롤백 + 고정 활성 grid 분리 모델"로 재해석한다. 더 진행은 측정된 필요(grapheme 메모리 blowup 등) 시에만.

> grapheme 메모리는 그 전까지 **dedup된 전역 `grapheme_store`**(HG dedup PR)가 distinct cluster 수로 bound한다. 화면 밖으로 사라진 cluster까지 회수(구조적)하는 건 위 **B**에서 grapheme을 page에 귀속시킬 때 온다 — 전역 refcount/GC는 flat `cells:[]Cell`+`memcpy` 위에서 위험·임시품이라 도입하지 않는다(§11.8).

**A1 측정 결과(validated)**: counting-allocator probe — cap 10,000: 스크롤백 할당 10,003 → **82**(122×↓). cap 1,000,000: ~1,000,003 → **7,824**(~128×↓). perf 게이트 회귀 없음(large_output 344→330ms). 동작 보존 — 기존 스크롤백 테스트 전부 green + ring.len 의존 테스트 3개를 관측 동작 기준으로 갱신.

**A2 측정 결과(validated)**: live-bytes probe(cap 10,000, cols 200) — 1칸 행: 88MB → **0.94MB(~94×↓)**, 평균 40칸 행: 88MB → **15MB(~5.8×↓ = trim 비율)**. 절감이 "내용이 얼마나 짧으냐"에 비례(§11.7대로). 핵심 구현 교훈: **arena를 binding 제약**으로(고정 cell arena + grow하는 desc) — 처음의 "고정 arena + 고정 desc cap" 모델은 짧은 행에서 desc cap이 arena를 반만 채워 1칸 행이 23.8MB(겨우 ~3.7×)였다. arena-binds로 바꿔 94×. TDD(hard-trim RED→GREEN) + soft 비-trim·render-pad 가드, OOM 트랜잭션·cap·eviction 보존. 0폭 행 스트림 무한 grow는 desc 상한(arena_cells)으로 봉인.

**P4 구현 결과**: `Scrollback.arena_alloc`(기본 page_allocator, init이 core 일반 alloc로 override → 테스트 leak 추적, production은 app_session chokepoint가 page_allocator로 재-override, `count==0` assert). cells alloc/realloc/free만 arena_alloc, page struct·descs·리스트는 일반 alloc(두 allocator 짝 맞춤). rewrap 임시도 같은 arena 복사. boundary: `std.heap.page_allocator`는 std라 platform import 없이 통과(check-boundaries green). **검증**: P4 테스트(주입된 arena allocator로 cell 할당됨 — FailingAllocator 카운팅 + 내용 정합) + 전체 green + leak-clean + 누적 리뷰 정확성 버그 0. **정직한 한계**: RSS 이득(demand-commit·콜드 swap·즉시 반납)은 anon mmap의 본질적 OS-레벨 속성이라 단위 수치 대신 **기능 정합**으로 검증했다 — 정밀 RSS 수치는 OS-RSS 계측(getrusage/mach)이 필요해 런타임 관측으로 남긴다. **basis 재확인**: A1+A2로 "수백만 줄"은 이미 RAM에서 viable했고, P4는 그 위 "history > RAM" enabler(목표 초과분 — 사용자 합의로 진행).

각 단계 doc-first + 누적 `/code-review max`. A1은 동작 보존이라 "정확성 버그 0" 기준, A2/P4는 메모리·동작 변경이라 측정+검증.

**A1 확정 세부**: `ROWS_PER_PAGE` 고정(예 512), uniform-width 페이지(폭 변경=새 페이지), page **pool**로 steady-state 0 할당 유지(ring과 동률), row-count cap 유지(바이트 cap은 A2/config 후속), 논리 행 i→(page,row)는 cumulative 인덱스.

### 11.7 A2 설계 — 가변폭/trailing-trim (실제 메모리 절감, **구현 완료** — 위 §11 종료 노트가 단일 출처)

**목표**: 스크롤백 행을 끝 default-cell까지 잘라 **가변폭**으로 저장 → 전형 출력(짧은 줄 다수)에서 메모리 ~10×↓. A1은 할당 수만 줄였고(데이터는 여전히 cap×cols×Cell), **A2가 실제 메모리를 줄여** 수백만 줄 viability에 기여한다.

**소비자 안전(grounding 완료)**: 짧은(cols 미만) 스크롤백 행은 이미 안전하다 —
- `renderSnapshot`이 read 시 pad한다: `n=@min(src.len, cols); @memcpy(dst[0..n], src); @memset(dst[n..], blank)`(screen.zig). wide 끝 잘림도 `clearTruncatedWideBase`로 정리.
- `rewrap`은 hard 행에 `trimmedLen` 적용(이미 가변폭 가정).
- 단 **A2 착수 시 selection/search/absRow 소비자가 `row.len`을 존중하는지 전수 확인**(현재 scrollback 행은 resize transient에만 가변폭이었고 rewrap이 곧 정규화 → A2는 영구 가변폭).

**페이지 모델 변경**: A1의 uniform-width(`rows_per_page × width` 연속) → **per-row-descriptor arena**. `Page = { cells: []Cell(arena), row_descs: [{ offset, len, wrapped, prompt }], used }`. 행을 trim된 len으로 arena에 팩, `locate(i)`는 cumulative row count로 페이지+desc 이진탐색. soft-wrap 행은 full width(내용이 끝까지)라 trim 안 함; **hard 행만** 끝 default trim(rewrap `trimmedLen` 규칙과 동일 — 단일 출처). 구현 시 `wrapped_flag` 분기 필수: `stored_len = if (wrapped) cells.len else trimmedLen(cells)` — soft 행을 trim하면 내부 trailing space가 사라져 rewrap이 논리 줄을 잘못 잇는다(검증됨, A2 prep).

**arena 크기(중요 — 실제 절감의 핵심, A2 prep 발견)**: arena를 `rows_per_page × cols`로 잡으면 trim된(짧은) 행이 **desc cap(rows_per_page)을 먼저 채우고 arena는 반만 차** → 절감 0(A1과 동일 메모리). 절감하려면 arena를 **cols와 무관한 고정 셀 예산**(단 `≥ cols`라 어떤 단일 행도 들어감)으로 두고 페이지를 `min(desc cap, arena full)` 양쪽으로 bound한다 — trim 행이 고정 arena에 촘촘히 팩돼 페이지 수↓(= 총 메모리↓), wide 행은 arena가 먼저 차 페이지↑되 데이터는 원래 큼(정상). 절감은 "내용이 얼마나 짧으냐"에 비례. pool 재사용은 arena 크기 고정이라 단순(폭 무관 — A1의 width별 realloc 불필요).

**동작 영향**: `scrollbackRow(i).len`이 cols보다 작을 수 있다(A1까진 push가 full-width 저장). 관측 동작은 불변(render가 pad, 내용·선택·검색 결과 동일). OOM 트랜잭션(rewrap)·row-count cap·eviction 유지.

**위험**: per-row-descriptor arena가 A1보다 복잡(arena 팩·eviction 시 단편화/compaction, locate 이진탐색 2단). wide-glyph 끝 trim 경계. **메모리 절감을 probe로 검증**(게이트 — 전형 출력 ~10×↓ 확인, 안 나오면 재고).

**테스트**: trim len 정확성(짧은 줄), render pad 동일성(snapshot 불변), selection/search 짧은 행 안전, 메모리 probe(절감 수치), OOM 트랜잭션 유지. A2는 동작 보존이라 "정확성 버그 0" + 메모리 절감 측정.

### 11.8 grapheme의 page 귀속 (B 단계 계획 — ❌ 정정: B 불가로 보류, §595)

**결정(본 세션)**: 활성 grid가 page로 가는 **B 단계에서 grapheme 저장을 page-local로 옮긴다**(§11.2 §502의 "page pool 생략"을 grapheme에 한해 뒤집음 — style은 그대로 Cell inline 유지). 동기: 전역 `grapheme_store`는 dedup해도 **세션 동안 본 distinct cluster 누계**로만 bound돼 화면 밖으로 사라진 cluster를 회수하지 못한다. grapheme을 page가 소유하면 **page free(eviction/recycle) 시 grapheme이 함께 사라져** A1의 recycle/eviction-frees 속성을 grapheme도 물려받는다(메모리 ∝ live 내용). page는 자족적이 되고("page를 free = 그 page의 모든 것 free"), 전역 store·교차 수명축이 사라진다.

**왜 지금(미리) 코드로 안 하나**: 활성 grid의 grapheme이 붙을 **page 구조 자체가 B의 산출물**이라 B 전에는 만들 수 없다(스크롤백만 먼저 하면 page-local 스크롤백 + 전역 활성의 split 모델 — 더 나쁨). 또 같은 스토리지 레이어를 동시 리팩터하면 충돌·rework다. 그래서 **B의 한 step으로** 진행하고, 그 전엔 dedup 전역 store가 브리지다.

**왜 전역 refcount/GC가 아닌가**: flat `cells:[]Cell`의 `memcpy`(스크롤·reflow)가 `grapheme_id`를 값 복사해 한 항목을 여러 셀이 공유 → 전역 refcount는 모든 셀 수명 이벤트를, GC는 모든 root를 빠짐없이 추적해야 해 위험하고, B가 들어오면 버려질 임시품이다. page 귀속은 회수가 **구조적**(page 수명)이라 refcount/GC가 불필요하다.

**B에서 할 일(플랜)**:
- `Page`에 grapheme 풀 추가(예: `[]u21` arena + per-cluster (offset,len), 또는 `ArrayList([]u21)`). cell의 `grapheme_id`는 **page-local 인덱스**가 된다. dedup은 page 내(rows_per_page 범위)로 — 페이지가 작아 within-page 중복은 작다(필요하면 측정 후 결정).
- 해석을 `page.graphemeCluster(id)`로(현재 `core.graphemeCluster`/`snapshot.graphemes` 전역). page free/recycle 시 풀을 free/clear(cells와 같은 pool 재사용).
- **reflow/cross-page 이동**: 셀이 다른 page로 옮겨갈 때 grapheme을 목적지 page 풀로 re-intern(id 재매핑) — B가 만드는 셀 이동 로직에 얹는다(이 단계의 주된 신규 복잡도).
- **renderer/직렬화 API 불변 유지**: `RenderSnapshot.graphemes`·`RowCodepoints`는 그대로 두되, 뷰포트 materialize(스크롤 시 이미 memcpy) 때 보이는 셀의 cluster를 **flat 뷰포트 grapheme 풀로 재수집**해 snapshot이 단일 `graphemes` 슬라이스를 노출하게 한다 — draw_list/selection/snapshot.zig 호출부 불변.
- 전역 `grapheme_store`·`grapheme_ids` 제거(page로 흡수). 검증: 기존 HG 단위·`nfd_hangul` oracle·`test-macos-coretext-smoke`(NFD '한'≡완성형) green 유지 + eviction 후 grapheme 메모리 회수 측정.

**seam 준비(지금 가능, 충돌 0)**: grapheme 해석이 `graphemeCluster(id)`/`snapshot.graphemes` 한 군데로 모여 있어, B에서 이 seam만 page-local로 바꾸면 호출부(RowCodepoints·draw_list·selection)는 안 바뀐다.

> **정정(§11.10 발견 반영)**: 이 계획의 **vehicle인 B(활성 grid 통일)가 A2와 충돌해 불가**해졌다(§11.10). 따라서 "B의 한 step으로 grapheme page-local"은 진행 불가. 남는 길은 (a) 위에서 "더 나쁨"으로 평가한 **split 모델**(스크롤백만 page-local grapheme + 전역 활성), 또는 (b) **현 전역 dedup store 유지**(브리지)다. **결정: (b) 유지·보류** — dedup이 distinct cluster 수로 메모리를 bound하고(100만 줄이라도 고유 cluster는 보통 수천~수만·각 몇 코드포인트 → MB급), **측정된 grapheme 메모리 병목이 없다**(measure-first). grapheme **렌더링** 작업(dedup·무손실 cluster 저장·NFD 한글·CoreText 셰이퍼)은 이미 완료·유효하며, **회수(page-local)만 보류**다 — huge history에서 grapheme 메모리가 실제로 커짐이 측정되면 그때 split 모델(스크롤백 page-local, 활성 grid 안 건드림)로 재개한다.

### 11.9 P4 설계 — mmap backing for 스크롤백 page arena (**구현 완료** — 위 §11 종료 노트가 단일 출처)

**목표**: A2가 만든 **고정 크기 cell arena**(ScrollbackPage.cells)를 일반 allocator 대신 **mmap/VirtualAlloc 기반 page allocator**로 받쳐, (1) demand-commit(안 쓴 arena tail은 물리 메모리 미점유), (2) 메모리 압박 시 콜드 히스토리 arena가 OS swap으로 디스크에 내려감(= history > RAM 가능), (3) free 시 즉시 OS 반납(general allocator의 caching과 달리)을 얻는다. architecture.md §180("hot terminal page backing → mmap/VirtualAlloc 직접, hot storage가 명확해지면 그 책임만 교체")의 실현. A1/A2로 hot storage(=고정 arena)가 명확해진 지금이 교체 시점.

**경계(중요 — terminal은 platform import 금지)**: maru `platform/`을 import하면 check-boundaries 실패다. 그러나 **`std.heap.page_allocator`(std의 mmap/VirtualAlloc 래퍼)는 std라 terminal에서 직접 써도 경계 위반이 아니다**. 따라서 platform 레이어 추상화 없이 std만으로 boundary-safe하게 구현한다(Ghostty가 직접 mmap하는 것과 같은 효과를 std로).

**스코프(최소)**: **ScrollbackPage.cells arena만** page allocator로. descs(작은 ArrayList)·pages/pool 리스트·active grid는 일반 allocator 유지(작거나 hot이 아님). 즉 Scrollback에 `arena_alloc: std.mem.Allocator` 필드를 두고 acquirePage/freePage의 cells alloc/realloc/free만 그걸 쓴다.

**주입(테스트 leak 추적 유지)**: production은 `std.heap.page_allocator`, **테스트는 `std.testing.allocator`를 arena_alloc로 주입**(page_allocator는 leak 추적이 안 돼 테스트가 arena 누수를 못 잡으므로). TerminalCore.init이 arena allocator를 받거나(시그니처 +1) 기본 page_allocator + 테스트 override. → init 시그니처/배선 변경이라 합의 필요.

**정직한 가치**: A1+A2만으로 이미 100만 줄이 viable하다(평균40칸 ~1.76GB). P4는 그 위에 demand-commit + 콜드 swap + 즉시 반납을 더해 **history > RAM**(수천만 줄, 콜드는 디스크)을 가능케 하는 증분이다. 목표가 "수백만"이면 P4 없이도 충분할 수 있고, "수천만~RAM 초과"면 P4가 enabler. **committed RSS를 측정해 이득을 수치 확인**(게이트).

**결정 사항(합의 필요)**:
1. **anonymous mmap(OS swap) 먼저** vs 명시적 file-backing. anon-mmap은 std.heap.page_allocator로 즉시 되고 콜드는 OS swap으로 디스크행 — 대부분 충분. swap보다 큰 초거대 history는 file-backing(별도 후속).
2. **init 시그니처**: arena allocator 주입(+1 파라미터) vs 기본 page_allocator(테스트만 override 훅).
3. **granularity**: page_allocator는 OS page(4KB+) 단위 — arena가 360KB(8192×44)라 무시 가능한 반올림.

**리스크**: 테스트 leak 추적(주입으로 해결), per-arena mmap syscall 비용(arena가 크고 pool 재사용이라 syscall 적음), realloc(초광폭 행) 시 remap(page_allocator 지원). 동작 보존(저장 위치만 이동 — 관측 불변).

### 11.10 B 설계 — 활성 grid까지 통합 PageList (❌ 정정: A2와 구조적 충돌로 **불가**, 미진행)

> **정정(B1 착수 직전 발견 — 이 설계는 폐기)**: 아래 "활성=통합 리스트 꼬리" 설계는 **A2와 양립 불가**임이 구현 스코핑에서 드러났다. **근거**: A2는 스크롤백 행을 **가변폭**(trim해 arena에 팩, append-only·불변)으로 만들었는데, 활성 grid는 **고정 `rows×cols`·제자리 mutate**(putCell이 아무 칸이나 즉시 씀, 고정 stride `r*cols+c` 필수)다. 가변폭 팩 구조에선 한 행을 늘리면 뒤를 통째 밀어야 해 활성 grid의 in-place mutation이 불가능하다. Ghostty의 통일이 되는 건 **모든 page가 균일 고정폭**이기 때문인데, maru는 A2로 스크롤백을 비균일하게 만들어(메모리 94×↓) 그 전제를 깼다. "경계 이동 O(1) scroll"도 밀려난 고정폭 행을 A2 스크롤백으로 넣으려면 **trim=복사**라 zero-copy가 안 된다. 즉 **A2의 메모리 이득과 Ghostty식 통일은 한 구조에서 동시 불가** — maru는 millions 목표상 A2(메모리)를 택했고 그게 통일을 막는다(트레이드오프, 버그 아님).
>
> **대안 평가**: ① 활성 grid를 ring(anchor)으로 → scroll O(1)이지만 P0서 활성 scroll 이미 싸 **perf~0** + hot-path 재작성 위험만 → 비채택. ② grapheme page-local(§11.8의 진짜 이득)은 활성 grid 통일 없이 스크롤백 page에 얹을 수 있으나 §11.8 자체가 "split 모델은 더 나쁨"이라 평가했고, 전역 dedup store가 이미 메모리를 bound해 **측정된 필요 없음** → 보류(measure-first).
>
> **결론**: **full B 미진행. §11은 A1/A2/P4로 완성**(수백만 줄 목표 달성·초과). architecture.md §211의 "통일 PageList"는 Ghostty 균일-페이지 모델 전제였고 maru는 A2로 다른 최적점을 택했다 — §211을 "maru는 A2(가변폭 스크롤백) + 고정 활성 grid의 분리 모델로 메모리를 우선한다"로 재해석한다. 통일을 정 원하면 A2를 되돌려야 하는데 그건 메모리 이득 포기라 millions에 역행.

아래는 폐기된 원설계(기록 보존용):

**(폐기) 결정**: full B 선택 — architecture.md §211 종착지(통일 저장 모델) + grapheme page-local 메모리 회수(§11.8). 위 정정으로 무효.

**모델**: 스크롤백 PageList(A1/A2)를 활성 grid까지 확장 — **활성 화면 = 페이지 리스트의 꼬리 `rows`행**, 스크롤백 = 그 앞 전부. 별도 `screen.cells` 평평 배열 제거. scroll = 활성 윈도가 리스트를 따라 내려가는 것(맨 위 활성행이 스크롤백이 됨) — 페이지 경계 포인터 이동(O(1) 잠재).

**커서 표현(핵심 결정 — Pin 대신 (row,col)+anchor)**: maru 커서는 `(row,col)`이 전 코드(262곳)에 박혀 있다. Ghostty식 Pin(page ptr+offset, tracked)로 바꾸면 그 262곳 전수 재작성이라 위험·비용 과대. 대신 **커서를 활성-상대 `(row,col)` 그대로 두고**, cell 접근 원시함수(`index`/`getCellPtr`/`putCell`)만 **활성 region anchor**(활성 행 0이 시작하는 page+offset, scroll/resize 때 1회 재계산)를 통해 `(row,col)→(page,cell)`로 O(1) 변환한다. → 262 커서 사이트 불변, 변환은 cell-access 층에만. hot-path는 anchor 캐시로 직접 인덱싱과 동급(perf 회귀 방지의 핵심). (대안: Pin — 채택 안 함, 비용·위험 과대.)

**단계(각 PR 동작 보존 + 게이트)**:
| 단계 | 내용 | 게이트 |
|------|------|--------|
| **B1** | 통합 PageList 골격 — 활성 region을 페이지 리스트 꼬리로 표현하되 동작·레이아웃 보존(활성 anchor 도입, `screen.cells`→page tail 매핑). cell-access 원시함수만 변경 | 전 테스트 green(동작 보존) + hot-path perf 게이트 |
| **B2** | scroll/clear/erase/insert/delete를 page-tail 연산으로(활성 윈도 이동) | 동작 보존 + scroll perf |
| **B3** | reflow 통일(활성+스크롤백 한 경로) — 가장 위험. 기존 reflow 테스트 전수 보존 | 누적 리뷰 + reflow 테스트 |
| **B4** | grapheme page-local(§11.8) — page가 grapheme 풀 소유, evict 시 동반 소멸. snapshot.graphemes seam만 page-local로 | HG oracle·NFD smoke green + grapheme 메모리 회수 측정 |

**perf 게이트(필수)**: B는 perf 이득이 ~0이므로 **회귀가 없어야** 정당하다 — hot-path(putCell/large_output)·scroll·reflow가 현 budget 유지. anchor 캐시가 (row,col)→cell을 O(1)로 지키는지 각 단계 측정.

**리스크**: (1) hot-path page-fetch 회귀 — anchor 캐시로 직접 인덱싱 동급 유지(측정 강제). (2) reflow 통일 정확성(soft-wrap·wide-glyph·prompt·커서 행) — 단계 분리 + 누적 리뷰. (3) 활성 anchor 무효화 누락(scroll/resize/alt swap 후 stale) — anchor 재계산 지점 전수. (4) alt swap이 활성 region 통째 교체 — 페이지 리스트 swap으로 표현.

**정직한 종착지 확인**: full B 완료 = architecture.md §211 "cursor·grid 완전한 Screen + page-aligned storage" 달성. 그 이상(file-backing 등)은 측정된 필요 시 별도.
