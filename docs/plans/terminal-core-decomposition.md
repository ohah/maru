# TerminalCore 분해 기록 (§0 · §4 · §6~§9)

core.zig 분해가 **어떤 순서로 무엇을 옮겼는가**의 기록이다. 왜 그렇게 갈랐는지(분리 메커니즘·책임 분류·검증 프로토콜)는 [TerminalCore 분해 설계](../terminal-core-decomposition.md)가 소유한다.

> **절 번호는 파일을 넘어 이어진다.** 본문이 `§7`처럼 절만 가리키면 여기서 소유 파일을 찾는다 — §1~§3·§5 [terminal-core-decomposition.md](../terminal-core-decomposition.md) · §0·§4·§6~§9 [분해 기록](terminal-core-decomposition.md) · §10 [Screen struct fold](screen-struct-fold.md) · §11 [page-aligned storage](page-aligned-storage.md)

## 0. 현재 위치 (무엇이 이미 됐나)

| 단계 | PR | 무엇 | 결과 파일 |
|---|---|---|---|
| 분할 1~3/N | #930~#932 | OSC host-reply(색·팔레트 10/11/4/104, clipboard·notify 52/9/777, hyperlink·cwd·maru·semantic 8/7/5379/133) | `osc.zig` (293줄) |
| 분할 4/N | #933 | 스크롤백 ring `Scrollback` 구조체(storage 시작) | `screen.zig` |
| 분할 5~7/N | #936·#938·#939 | **Phase A 완료** — parser dispatch: DCS(DECRQSS·XTGETTCAP)·OSC 라우터·APC(kitty graphics) 파싱·라우팅 | `parser.zig` (320줄) |
| 분할 8~11/N | #940~#943 | **Phase B 완료** — 활성 화면 연산: tabstops·dirty 추적·G3 charset/이모지 폭·스크롤백 저장·재-wrap | `screen.zig` |
| 분할 12~18/N | #946~#952 | **Phase C 완료** — 화면 본체: cursor 이동·erase/insert/delete·scroll/feed·alt screen·print 핫패스(putCell)·resize/reflow·snapshot/viewport 합성 | `screen.zig` (~1990줄) |
| 분할 19~21/N | #954~#956 | **Phase D 완료 — 분해 완결** — parser 상태기계 본체: SGR/모드 dispatch·CSI 상태기계(handleCsiByte·dispatchCsi)·escape+UTF-8 intake+write 루프(`write`→`parser.feed` 위임) | `parser.zig` (989줄) |
| 리뷰 후속 | #944·#953·#957 | 배치 1~3 `/code-review max` cleanup(주석·모듈 doc·현황표 정합 — 정확성 버그 0) | (doc/주석) |

> 배치 1(5~11/N)·배치 2(12~18/N)·배치 3(19~21/N) 후 `/code-review max` 누적 리뷰 각각 완료(정확성 버그 0 — 순수 이동 검증). **분해 완결: core.zig 9962→7228줄(−2734), parser.zig 989줄·screen.zig 2001줄·osc.zig 294줄로 분리.** core.zig는 struct·필드·facade(write/resize/snapshot/renderSnapshot은 외부 점-호출이라 잔류, 본문은 parser/screen)·selection/search/url·kitty graphics 본체·host-reply·lifecycle만 보유. CSI param 접근자(csiRawParam/csiParam·max_csi_params)는 param 저장소(csi_params 필드)와 한 묶음이라 core 잔류 — parser/screen이 cross-file 호출(pub). 잔여(후속 별도 initiative): selection.zig 분리(**§7 진행 중** — S1서 `absRow`/`absRowWrapped`→screen 완료), Screen struct 필드-fold(architecture.md 2단계).

확립된 두 분리 패턴(이 분해의 토대):

- **osc.zig 패턴(연산 추출)**: 핸들러는 `pub fn handler(self: *TerminalCore, ...)` **free 함수**. 진입점(라우터 `dispatchOsc`)은 core에 남아 `osc.handler(self, ...)`로 위임. struct·facade 불변. 핸들러는 `self.<field>` 직접 접근 + `self.<pub method>()` 호출.
- **screen.zig 패턴(self-contained struct)**: `Scrollback`은 `TerminalCore`를 참조하지 않고 `types`만 의존. core가 `sb`/`saved_sb` 필드로 보유하고 메모리 수명만 struct가 소유, 행 push/get/rewrap 로직은 core가 필드를 직접 다룬다.

**남은 책임 두 덩어리** — 이번 문서 범위:

1. **VT 파서 상태기계** → `parser.zig`: 바이트를 해독하고(UTF-8·ESC·CSI·OSC·DCS·APC 상태) 시퀀스를 dispatch하는 "무슨 시퀀스인가" 층.
2. **활성 화면 storage/연산** → `screen.zig`: 그 시퀀스가 grid·cursor·scroll에 일으키는 "무슨 일이 일어나는가" 층(putCell·scroll·erase·resize·snapshot).

---

## 4. PR 시퀀스 (저위험 → 고위험)

번호는 `core.zig 분할 5/N`부터 이어간다. 원칙: **(a)** 파서/스크린 경계를 넘지 않는 leaf 클러스터를 먼저, **(b)** screen 연산을 parser dispatch보다 먼저 옮겨 parser가 screen을 단방향 호출하게(§1.6), **(c)** 가장 뜨겁고 얽힌 것(print·resize·snapshot·CSI dispatch·write 루프)을 마지막에. 각 PR은 독립 컴파일·동작 보존·green-only.

### Phase A — parser leaf (screen 결합 없음, osc.zig 동형)

| PR | 범위(이동) | pub 승격(예) | 위험 |
|---|---|---|---|
| **5/N** `parser.zig` 신설 | DCS 서브시스템(`dispatchDcs`+DECRQSS+XTGETTCAP+hex/SGR-report 헬퍼 11개). write 루프 `.dcs_escape`→`parser.dispatchDcs(self)` | `appendResponse`(이미 pub) | 낮음 |
| **6/N** | OSC 라우터 `dispatchOsc`→parser.zig(osc.zig 핸들러 위임). 루프 `.osc`/`.osc_escape`→`parser.dispatchOsc(self)` | `setWindowTitle`→pub | 낮음 |
| **7/N** | APC/kitty 파싱·라우팅(`dispatchApc`·`parseKittyGraphicsCommand`·`abortKittyChunk`). 루프 `.apc_escape`→`parser.dispatchApc(self)` | `execKittyGraphics`·`kittyDisplay`·`kittyDelete`·`storeKittyImage` 등→pub | 낮음~중 |

### Phase B — screen leaf (parser 결합 없음)

| PR | 범위(이동) | 비고 | 위험 |
|---|---|---|---|
| **8/N** `screen.zig` 확장 | tabstops(`isTabstop`·`resetTabstops`·`rebuildTabstops`·`writeTab`·`cursorBackTab`·`clearTabstop`) | core의 CSI dispatch가 `screen.x(self)`로 호출(아직 dispatch는 core) | 낮음 |
| **9/N** | dirty 추적(`markDirty`·`markCursorMoveDirty`·`markCursorRowDirty`; `takeDirty`/`clearDirty`는 위임 메서드) | 거의 모든 screen 연산이 부르는 헬퍼 — 먼저 옮겨 안정화 | 낮음 |
| **10/N** | charset·print 폭 헬퍼(`translateCharset`·`decSpecial`·`designateCharset`·emoji/RI 판정 6개·`wideContinuationCell`) | 순수 함수 다수 | 낮음~중 |
| **11/N** | 스크롤백 행 저장·재-wrap(`pushScrollback`·`clearScrollback`·`ensureScrollbackRewrapped`·`rewrapScrollback`/`Anchored`/`Inner`·`countRewrapRows`·`trimmedLen`) | rewrap 엔진 응집 이동. `absRow`/`absRowWrapped`는 selection 공유(19+6 호출)라 후속 accessor PR로 분리 — 본 PR을 작게·검증 가능하게. 잔류 헬퍼 4개(invalidateSelection·shiftCoordsForEviction·isBlankCell·clearTruncatedWideBase) pub 승격 | 중 |
| **11b/N(후속)** ✅ | 스크롤백 accessor(`absRow`·`absRowWrapped`) → screen.zig | selection 클러스터의 25 호출 redirect. **§7 S1로 완료**(selection 분리 전제) | 중 |

### Phase C — screen 본체

| PR | 범위(이동) | 비고 | 위험 |
|---|---|---|---|
| **12/N** | cursor 이동/위치(`cursorPosition`·`cursorVertical/Horizontal/ToColumn/ToRow`·`resolveRow`·`setOriginMode`·`setCursorStyle`·`clampSavedCursor`) | | 중 |
| **13/N** | erase/insert/delete(`eraseInLine`·`eraseCharacters`·`insertChars`·`deleteChars`·`eraseInDisplay`·`repairWideGlyphEdges`) | `clearScreen`은 `isPromptish` 결합으로 core 잔류(실제 결과) | 중 |
| **14/N** | scroll/feed(`lineFeed`·`reverseIndex`·`scrollRegion*`·`scrollRange*`·`insertLines`·`deleteLines`·`setScrollRegion`·`decAlign`) | scrollRangeUp의 history push가 스크롤백과 결합(11/N 이후라 안전) | 중~높음 |
| **15/N** | alt screen + saved cursor(`enterAltScreen`·`leaveAltScreen`·`save/restoreCursorState`·`restoreFromSlot`·`activeSavedCursor`) | grid+scrollback 스왑 | 중~높음 |
| **16/N** | print 핫패스(`writeCodepoint`·`putCell`·`clearCellForWrite`·`attachCombiningMark`·`promoteLastToEmojiWidth`) | grapheme/wide/combining — 가장 뜨거운 경로 | 높음 |
| **17/N** | resize/reflow(`resize` 위임·`ensureReflowScratch`·`copyRegionResize`·`trimmedRowLen`·`isBlankCell`·`outputRowBlank`·`clearTruncatedWideBase`) | 최대 함수·perf 예산 민감(`mise run perf`로 회귀 확인) | 높음 |
| **18/N** | snapshot/viewport(`snapshot`·`renderSnapshot` 위임·viewport 접근자) | 렌더 출력 계약 — 스냅샷 동작 보존 필수. preedit 합성은 현재 별도 Surface projection. | 높음 |

### Phase D — parser 상태기계 본체 (마지막, screen.zig 함수 참조)

| PR | 범위(이동) | 비고 | 위험 |
|---|---|---|---|
| **19/N** | SGR+모드 dispatch(`applySgr`·`applyExtendedColor`·`setPrivateModes`·`setAnsiModes`·`repeatLastChar`·report 3개·`kittyFlagsFromParam`) | 모드 setter가 screen·다수 필드 건드림 | 높음 |
| **20/N** | CSI dispatch(`dispatchCsi`·`beginCsi`·`csiNextParam`·`handleCsiByte`) | `csiRawParam`/`csiParam`은 param 저장소와 한 묶음이라 core 잔류(실제 결과). ~40개 `screen.x(self)` 호출(이미 이동됨) | 높음 |
| **21/N** | escape+UTF-8 intake+write 루프(`handleEscapeByte`·`completePendingUtf8`·`storePendingUtf8`·`utf8SequenceLength`·`decodeUtf8`; write 본문→`parser.feed`, core `write`는 위임) | 진입점 — 호출 대상이 전부 이동 완료된 상태 | 최고 |

> 위 21개는 선례(분할 1~4/N)의 granularity를 잇는 상한이다. 합의 시 인접 저위험 PR을 합쳐 수를 줄일 수 있다(예: 8+9, 5+6). granularity는 합의 사항.

---

## 6. 미해결/후속 (이번 범위 밖, 기록만)

- **2단계(Screen struct fold)**: §2 — 필드를 `Screen` 하위 struct로 접는 architecture.md 종착지. 연산 추출 완료 후 별도 initiative.
- **selection.zig** ✅ **완료(역사적 분해)**: 당시 선택/검색/URL/preedit 클러스터를 §7(S1~S5)로 분리했다. 이후 영속 host 경로를 위해 preedit은 core/selection에서 제거하고 `Surface`의 client-local overlay로 이동했다.
- **kitty.zig** ✅ **완료**: kitty graphics 본체를 §8(K1~K3)로 분리 완결(core.zig 6715→6233줄, kitty.zig 516줄). parser는 파싱(7/N) + `kitty.execKittyGraphics` 위임.
- **input_report.zig** ✅ **완료**: `reportFocus`/`reportMouse`/`encodeKey`/`encodeOptions`/`encodePaste` 입력→host-reply 인코딩을 §9(R1)로 분리 완결(core.zig facade 5개 + input_report.zig 112줄).
- **RIS가 DECSC 슬롯 초기화** ✅ **완료**(B4~B5 리뷰서 확인, §10.8.7): `fullReset`(ESC c)이 `screen.saved_cursor`를 안 비우던 기존 동작(평평 슬롯 시절부터 — 분해가 도입한 게 아님)을 고쳐, RIS가 슬롯도 공장 초기화한다(이후 DECRC/CSI u는 home 복원). **베이스**: VT100 RIS = power-on 상태 + Ghostty `Screen.reset()`이 `saved_cursor=null`. **결정**: RIS는 완전한 공장 리셋이므로 저장 커서도 비우는 게 정합(슬롯 생존은 사실상 버그). alt는 RIS의 leaveAltScreen으로 이미 폐기돼 활성(primary) 슬롯만 비우면 충분. 테스트 1건 추가.
- **setup-path OOM 누수**(§11 A1 OOM-sweep서 발견, 범위 밖): `FailingAllocator`로 write/resize 도중 할당을 실패시키면 일부 경로가 할당을 잃는다(스크롤백 page 저장과 무관 — 기존 코드). A1 rewrap OOM 테스트는 실패 주입을 rewrap 단계로 한정해 우회했다. 별도 후속으로 grapheme/reflow scratch·write 경로의 OOM errdefer를 감사한다(크래시 아님 — best-effort OOM 경로의 누수).

---

## 7. selection.zig 분리 (후속 initiative — ✅ 완료, S1~S5)

§6의 selection.zig 후속을 §1~§5와 **같은 절차·메커니즘**(방향 A, 연산 추출, facade 보존, 매 PR green auto-merge)으로 진행했다. 아래 S1~S5 표는 당시 이력이며, S5의 IME preedit 부분은 이후 `Surface` overlay로 대체되어 현재 core/selection 계약이 아니다.

### 7.1 경계 설계 (레이어 방향)

selection은 화면/스크롤백을 **읽어** 좌표·텍스트를 산출하는 **상위 레이어**다. 의존 방향은 `selection → screen → (types)` 단방향이어야 한다(`screen`이 `selection`을 import하면 하향 역전 — 금지).

- **selection.zig가 부르는 것**: `screen.ensureScrollbackRewrapped`·`screen.absRow`/`absRowWrapped`(S1 이후)·core 필드(`selection_anchor`/`head`/`block`·`sb`·`view_offset`·`size`·`link_store`)·top-level `core.fullDirty`. 단어/URL 경계 공백은 `screen.isBlankCell`(배경 기본값까지 요구)이 아니라 selection 내부 `isBoundarySpace`(배경 무관 — bce로 색칠한 공백도 경계)로 판정한다.
- **core 잔류 seam(screen↔selection 다리)**: `invalidateSelection`(screen이 6곳서 `self.invalidateSelection()` 호출 — 옮기면 screen→selection 역전이라 core 잔류, 본문은 `self.selectionClear()` 한 줄), `shiftCoordsForEviction`(선택+kitty placement eviction 조율 — selection 부분만 `selection.shiftSelectionForEviction(self,n)`로, kitty 부분은 core).
- **core 잔류 facade delegator(당시)**: `selectionStart`·`selectionExtend`·`selectWordAt`·`setSelectionBlock`·`selectLineAt`·`selectAll`·`selectionClear`·`selectionViewportSpan`·`extractSelection`·`extractUrlAt`·`urlAnchorAt`·`urlSpanAtAbs`·`findMatches`·`matchViewportSpan`가 남았다. 당시 포함됐던 `setPreedit`은 현재 제거됐다.
- **selection.zig 내부 전용**(완전 이동, **private `fn`** — osc/parser/screen와 동형): `wordBoundsAt`/`wordBoundsAtImpl`·`isWordSeparatorCell`·`isWordBoundaryCell`·`WordBounds`·`clipAbsSpanToViewport`·`cellLinkAt`·`linkBoundsAt`·`appendRowUtf8`·`normalizedSelection`·`extractBlockSelection`·`matchAtIgnoreCase`. (cross-file 호출 있어 pub 유지: `foldCase`·`urlSpanInWord`·`wordIsUrl`=테스트, `shiftSelectionForEviction`=core seam.) `absRowFromViewport`는 좌표 family라 **screen.zig로**(absRow와 함께, 리뷰 cleanup).
- **테스트 호출부 갱신**: core.zig 테스트가 직접 부르는 private 3개(`wordBoundsAt`@5371·`foldCase`@2388~·`urlSpanInWord`@5452/5455)는 selection.zig pub로 두고 호출부를 `selection.X(...)`로 바꾼다(§1.7 — 테스트는 core 잔류).

순환 import은 osc/parser/screen가 검증한 그래프와 동형(core↔selection 상호 import을 Zig lazy 분석이 푼다).

### 7.2 PR 시퀀스 (의존성 DAG 순 — leaf 먼저)

> ⚠️ **순서 결정 근거**: URL 함수(`urlAnchorAt`/`extractUrlAt`/`wordIsUrl`)는 `wordBoundsAt`(word-bounds)에, `wordBoundsAtImpl`은 `absRowFromViewport`·`isWordBoundaryCell`에 의존한다. 따라서 "URL을 먼저"가 아니라 **순수 leaf(자기-cluster 의존 없는 헬퍼)를 먼저** 옮겨야 각 PR이 컴파일된다(이동된 함수가 부르는 대상이 이미 selection.zig pub이거나 core 메서드/필드/screen). 초안의 "S2=URL leaf"는 이 의존성을 놓쳐 S2서 dependency-순으로 정정.

| PR | 범위(이동) | 비고 | 위험 |
|---|---|---|---|
| **S1**(11b/N) ✅ | `absRow`·`absRowWrapped` → screen.zig | 스크롤백 abs-좌표 accessor. 호출부 25곳(19+6) 전부 selection 클러스터(core) → `screen.absRow(self,...)`. selection→screen 단방향 확보 | 낮음 |
| **S2** ✅ | `selection.zig` 신설 + **순수 leaf 12개**(`cellLinkAt`·`linkBoundsAt`·`appendRowUtf8`·`urlSpanInWord`·`isWordSeparatorCell`·`isWordBoundaryCell`·`clipAbsSpanToViewport`·`normalizedSelection`·`absRowFromViewport`·`foldCase`·`matchAtIgnoreCase`·`shiftSelectionForEviction`) | 전부 private(facade 0). screen/필드/std만 의존(자기-cluster self 의존 없음). 테스트 호출부 `TerminalCore.foldCase`/`urlSpanInWord` → `selection.X`. `shiftSelectionForEviction`은 `self.selectionClear()`(core pub) 호출 | 낮음 |
| **S3** ✅ | word-bounds + 포인터 선택(`WordBounds`·`wordBoundsAt`·`wordBoundsAtImpl`·`selectWordAt`·`selectionStart`·`selectionExtend`·`setSelectionBlock`·`selectLineAt`·`selectAll`·`selectionClear`·`max_word_separators`) | leaf(S2) 위에 빌드. facade 7개(selectionStart·setSelectionBlock·selectionExtend·selectWordAt·selectLineAt·selectAll·selectionClear). `invalidateSelection`·`screen.clearScrollback`(core/screen seam)이 `self.selectionClear()`(→facade) 호출 유지(screen→selection import 없음). S4 함수의 `self.wordBoundsAt`→`selection.wordBoundsAt(self,)` | 중 |
| **S4** ✅ | URL 감지(`urlAnchorAt`·`urlSpanAtAbs`·`extractUrlAt`·`wordIsUrl`) | wordBoundsAt(S3)·cellLinkAt/clip(S2)에 의존. facade 3개(urlAnchorAt·urlSpanAtAbs·extractUrlAt). `wordIsUrl`은 app 호출 없어 facade 없이 selection.zig pub(테스트 `core.wordIsUrl`→`selection.wordIsUrl(&core,)`). `linkUri`(core link_store accessor)는 extractUrlAt(OSC 8)가 cross-file 호출하므로 pub 승격 | 중 |
| **S5** ✅ (역사) | 검색 + 추출 + 당시 preedit(`findMatches`·`matchViewportSpan`·`selectionViewportSpan`·`extractSelection`·`extractBlockSelection`·`setPreedit`) | 당시 preedit는 core 필드였고 selection.zig가 alloc/free했다. 현재 `setPreedit`/core 필드는 제거됐으며 `Surface` client-local overlay가 대체한다. | 중 |

> **selection.zig 분리 완결 당시 상태**(S1~S5 머지): core.zig 7228→6715줄, selection.zig 587줄(리뷰 cleanup 후). 이후 preedit facade/필드는 core에서 제거됐다. 후속 별도 initiative: kitty.zig(§6)·Screen struct fold(§2).

검증·리뷰는 §5 그대로(매 PR `zig build test`·`macos-app-build`·`check-boundaries`·`zig fmt`, green auto-merge --rebase). PR 5개라 마지막에 `/code-review max` 1회. `selection.zig`는 check-boundaries가 `terminal/`을 walk하므로 자동 포함(등록 불필요).

### 7.3 리뷰 cleanup (S1~S5 `/code-review max` 후속)

누적 리뷰 결과 **정확성 버그 0**(순수 이동 — build + 1227 테스트 + ast-check + boundaries green). 지적된 cleanup만 tip에서 정리:

- **API 표면 축소**: selection.zig의 intra-only 헬퍼 11개(`clipAbsSpanToViewport`·`cellLinkAt`·`linkBoundsAt`·`appendRowUtf8`·`normalizedSelection`·`matchAtIgnoreCase`·`isWordSeparatorCell`·`isWordBoundaryCell`·`wordBoundsAt`·`wordBoundsAtImpl`·`extractBlockSelection`)를 `pub fn`→`fn`로 데모트 — 모듈 doc의 "osc/parser/screen와 동형"(헬퍼는 private)에 정합. cross-file 호출 있는 것만 pub 유지(facade-backed 15 + `foldCase`/`urlSpanInWord`/`wordIsUrl`=테스트 + `shiftSelectionForEviction`=seam).
- **좌표 family 응집**: `absRowFromViewport`(viewport→abs, 선택 상태 무관)를 screen.zig로 — `absRow`/`absRowWrapped`(S1)와 한 곳. selection.zig는 `screen.absRowFromViewport(self,)`로 호출.
- **잔재 정리**: `findMatches`의 vestigial `start_abs` 상수 인라인, `wordIsUrl` pub-for-test 사유 주석, `src/width.zig` stale 주석(`core.appendRowUtf8`→`selection.appendRowUtf8`).

---

## 8. kitty.zig 분리 (후속 initiative — ✅ 완료, K1~K3)

§6의 kitty.zig 후속을 §1~§5·§7과 **같은 절차·메커니즘**으로 진행한다. kitty graphics 본체(현 core.zig ~1036~1530, 함수 17개 + 저장 struct 4개)를 `kitty.zig`로 떼어낸다. parser는 이미 파싱(`parseKittyGraphicsCommand`·`dispatchApc`, 7/N)만 갖고, core가 exec/storage/placement/transmit/render-view 본체를 들고 있다 — 그 본체를 옮긴다.

### 8.1 경계 설계

- **이동 struct(4개, 전부 self-contained — `Scrollback` 선례 동형, TerminalCore 미참조)**: `KittyGraphicsCommand`(parse↔exec DTO)·`StoredPlacement`·`KittyImage`·`KittyImageStorage`(map+add/clear/deinit 메서드 포함). core는 `const KittyGraphicsCommand = kitty.KittyGraphicsCommand;`처럼 **별칭**을 둬 필드 선언(`kitty_chunk_cmd: ?KittyGraphicsCommand`·`kitty_images: KittyImageStorage`·`kitty_placements: [...]StoredPlacement`)을 불변으로 둔다(§1.5 순환은 self-contained라 lazy 분석으로 해소).
- **core 잔류(graphics 아님)**: `KittyFlags`/`KittyFlagStack`/`KittySetMode`(kitty **keyboard** protocol — parser의 `kittyFlagsFromParam`·`reportKittyFlags`가 씀)·`kitty_flags` 필드. graphics와 별개 subsystem이라 안 옮긴다.
- **parser 연동**: `parseKittyGraphicsCommand`의 반환 타입을 `core.TerminalCore.KittyGraphicsCommand`→`kitty.KittyGraphicsCommand`로, `dispatchApc`의 `self.execKittyGraphics(...)`→`kitty.execKittyGraphics(self, ...)`로(parser가 kitty.zig import — osc import과 동형. execKittyGraphics는 외부 호출 없어 facade 불필요).
- **core facade(2개)**: `buildPlacementViews`·`buildImageViews`는 screen.zig snapshot/renderSnapshot이 `self.X()`로 호출 — kitty.zig로 옮기면 screen→kitty 하향 의존(레이어 역전)이라 core facade로 잔류(본문은 kitty.zig). screen은 kitty를 import하지 않는다.
- **core seam**: `shiftCoordsForEviction`(core)이 `self.shiftPlacementsForEviction(n)`→`kitty.shiftPlacementsForEviction(self, n)` 호출(selection의 shiftSelectionForEviction과 같은 결 — eviction 조율자는 core, 부분만 위임).
- **테스트**: `core.kittyImageHasPlacement(...)`(테스트 직접 호출) → `kitty.kittyImageHasPlacement(&core, ...)`(facade 없음 — app 호출 없고 테스트만, wordIsUrl과 같은 처리).
- **의존**: kitty.zig는 std·core·types·png(PNG 디코드)·(zlib는 std.compress)만 의존. check-boundaries가 `terminal/` walk라 자동 포함.

### 8.2 PR 시퀀스 (의존성 DAG 순 — leaf 먼저)

의존 그래프: orchestrator(`execKittyGraphics`→`kittyTransmit`/`kittyDisplay`/`kittyDelete`) → mid(`storeKittyImage`→`evictKittyImagesFor`→`pickKittyEvictionVictim`; 이들이 `removePlacementsForImage` leaf를 부름) → leaf(placement·view·`kittyImageHasPlacement`·`kittyAdvanceRows`). 그래서 **true leaf 먼저**(storage는 leaf 아님 — removePlacementsForImage 호출).

| PR | 범위(이동) | 비고 | 위험 |
|---|---|---|---|
| **K1** ✅ | `kitty.zig` 신설 + struct 4개 + **true leaf 8개**(`removePlacementsForImage`·`removeOnePlacement`·`addOrReplacePlacement`·`shiftPlacementsForEviction`·`kittyImageHasPlacement`·`kittyAdvanceRows`·`buildPlacementViews`·`buildImageViews`) | 다른 kitty fn 호출 없음(필드·types만). core 별칭 4개(KittyGraphicsCommand·StoredPlacement·KittyImage·KittyImageStorage) + facade 2개(buildViews) + `max_kitty_placements`·KittyImageStorage 메서드(add/clear/deinit/remove) pub 승격 + parser `KittyGraphicsCommand` 참조. 테스트 `kittyImageHasPlacement`→`kitty.X(&core,)` | 중 |
| **K2** ✅ | storage/evict mid(`pickKittyEvictionVictim`·`evictKittyImagesFor`·`storeKittyImage`·`deleteByZ`) | K1 leaf(removePlacementsForImage 등) 위에 빌드. storeKittyImage·deleteByZ는 pub(K3 orchestrator가 호출), evict/pick는 private(K2 intra). 호출부 self.X→kitty.X(self,) | 중 |
| **K3** ✅ | orchestrator(`execKittyGraphics`·`kittyDisplay`·`kittyDelete`·`kittyTransmit`·`kittyTransmitPng`) + parser `dispatchApc` 연동(`kitty.execKittyGraphics`) | execKittyGraphics만 pub(parser 호출), 나머지 private(intra). kitty.zig에 `png` import 추가. KittyImage 별칭·core png import 제거(미사용). **kitty.zig 분리 완결** | 중~높 |

> **kitty.zig 분리 완결**(K1~K3 머지): core.zig 6715→6233줄, kitty.zig 516줄. core 잔류 = 별칭 3개(필드 타입 KittyGraphicsCommand·StoredPlacement·KittyImageStorage)·필드(kitty_images·kitty_placements·kitty_chunk_cmd·placement_views·image_views)·facade 2개(buildPlacementViews·buildImageViews)·seam(shiftCoordsForEviction→kitty.shiftPlacementsForEviction)·KittyFlags/KittyFlagStack(keyboard protocol). 후속 남음: Screen struct fold(§2). (input/report.zig는 §9 R1로 분리 완료.)

검증·리뷰는 §5 그대로(매 PR 4종 게이트 green auto-merge --rebase). PR 3개라 마지막에 `/code-review max` 1회.

### 8.3 리뷰 cleanup (K1~K3 `/code-review max` 후속)

누적 리뷰(10 angle) 결과 **정확성 버그 0**(순수 이동 — 17개 함수 byte-identical 확인 + build + 322 테스트 + check-boundaries + ast-check green). selection §7.3과 같은 cleanup만 tip에서 정리:

- **API 표면 축소**: kitty.zig의 intra-only 6개(`kittyAdvanceRows`·`addOrReplacePlacement`·`removePlacementsForImage`·`removeOnePlacement`·`storeKittyImage`·`deleteByZ`) + `KittyImage` struct + `KittyImageStorage.add`/`.remove`를 `pub`→private 데모트. K2 시점엔 store/deleteByZ가 core orchestrator에 cross-file 호출돼 pub였지만 K3에서 orchestrator가 kitty.zig로 와 intra-only가 됨. **pub 유지(cross-file)**: `execKittyGraphics`(parser)·`shiftPlacementsForEviction`(core seam)·`buildPlacementViews`/`buildImageViews`(core facade)·`kittyImageHasPlacement`(테스트)·struct 3개(필드 타입)·`KittyImageStorage.clear`/`.deinit`(core fullReset/deinit).
- **stale 포인터**: `types.zig`의 KittyPlacement 주석 "core.zig의 KittyGraphicsCommand" → "kitty.zig의 …"(K1서 이동), `max_kitty_placements` 주석 정정.

---

## 9. input_report.zig 분리 (후속 initiative)

§6의 input/report.zig 후속을 §1~§5·§7·§8과 **같은 절차·메커니즘**으로 진행한다. 입력/이벤트를 host(PTY) 바이트로 인코딩하는 클러스터(현 core.zig, 함수 5개)를 `input_report.zig`로 떼어낸다(파일명은 core_owner.zig 선례의 underscore 컨벤션).

### 9.1 경계 설계

- **이동 5개(전부 외부 점-호출 → core facade)**: `encodeKey`(KeyEvent→바이트, input.encodeKey 위임)·`encodeOptions`(현재 입력 모드 → input.EncodeOptions)·`encodePaste`(bracketed paste 래핑 + CR 정규화 + ESC 인젝션 방어)·`reportFocus`(DECSET 1004, CSI I/O)·`reportMouse`(SGR/SGR-Pixels/urxvt/x10 마우스 리포트). 본문은 input_report.zig free 함수, core엔 위임 메서드.
- **core 잔류**: `appendResponse`/`pendingResponse`/`clearResponse`(host-reply 응답 버퍼 `self.response` primitive — parser/osc/kitty/report 전부가 씀, core 잔류. reportFocus/Mouse가 `self.appendResponse`로 호출). `dumpUtf8`(그리드→UTF-8 직렬화 — 입력/리포트 아니라 screen 덤프, test/smoke 8곳이 씀, core 잔류).
- **의존**: input_report.zig는 std·core·input(키 인코딩 primitive)만. self 필드(bracketed_paste·focus_events·mouse_tracking·mouse_format·application_cursor_keys·kitty_flags·application_keypad) 직접 접근. intra: encodeKey→encodeOptions(self).
- **레이어**: core↔input_report 상호 import(osc/selection/kitty와 동형). check-boundaries가 terminal/ walk라 자동 포함.

### 9.2 PR 시퀀스

5함수 cohesive·intra-dep는 encodeKey→encodeOptions뿐이라 **단일 PR(R1)**로 이동 + facade. 이어서 `/code-review max` 1회.

| PR | 범위(이동) | 비고 | 위험 |
|---|---|---|---|
| **R1** ✅ | input_report.zig 신설 + `encodeKey`·`encodeOptions`·`encodePaste`·`reportFocus`·`reportMouse` | facade 5개. appendResponse/dumpUtf8 core 잔류. reportFocus/Mouse는 self.appendResponse(core) 호출, encodeKey는 encodeOptions(self) intra. core.zig 6233→6166줄, input_report.zig 113줄 | 낮음~중 |

검증·리뷰는 §5 그대로(4종 게이트 green auto-merge --rebase + `/code-review max`).

### 9.3 리뷰 cleanup (R1 `/code-review max` 후속)

누적 리뷰 결과 **정확성 버그 0**(byte-identical 이동 + build + 테스트 + check-boundaries green, 모든 호출부 facade로 해소). cleanup 1건만 정리: `reportMouse` doc-comment의 중복 단락(원본 core.zig에서 그대로 옮겨온 pre-existing — col/row 0-based 설명이 두 번)을 한 블록으로 dedup.

---
