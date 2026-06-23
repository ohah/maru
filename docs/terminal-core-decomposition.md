# TerminalCore(core.zig) 분해: Parser/Screen 분리 설계

`src/terminal/core.zig`(분해 시작 시점 9,962줄·573KB·함수 236개·테스트 289개)는 VT **파서 상태기계** + **화면/스크롤백 storage** + **host-reply/encoding**을 한 struct에 섞고 있었다. 이는 `docs/project-rules.md` "구조와 파일 분리"(한 파일이 parser·storage·encoding처럼 서로 다른 이유로 바뀌면 facade는 유지하되 구현을 목적별로 분리) 위반이었다. 이 문서는 그 분해(parser·active screen storage)의 설계·메커니즘·PR 시퀀스를 단일 출처로 둔다.

> **상태: 분해 완결**(분할 1~21/N + 리뷰 3배치 머지). core.zig는 7,228줄로 줄고 parser.zig(989줄)·screen.zig(2,001줄)·osc.zig(294줄)로 분리됐다. 이 문서는 이제 **완료된 분해의 설계 기록**이며, §0 현황표가 최종 결과를, §2가 채택한 전략(방향 A)을, §6이 후속 별도 initiative를 담는다.

이 문서는 `AGENTS.md` 설계 문서 인덱스에 연결된다. 분해 작업의 경계·메커니즘·PR 시퀀스를 바꿀 때는 이 문서를 먼저 갱신한다.

> 관련 전략 문서: [초기 아키텍처](architecture.md#스크롤백은-화면screen에-귀속한다) §"스크롤백은 화면에 귀속한다"(2단계 = 완전한 `Screen` 구조체), [레이어링과 이식성](layering-and-portability.md), `src/terminal/README.md`(parser·screen·cursor·scrollback·key/mouse encoding으로 분리한다는 폴더 계약).

---

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

## 1. 분리 메커니즘 (Zig 제약 + 선례에서 유도)

이번 분해의 모든 PR이 따르는 불변 규칙. **무엇을 베이스로 했나**: Zig 0.16의 가시성/메서드 규칙 + 이미 머지되어 컴파일이 검증된 osc.zig/screen.zig 그래프.

### 1.1 필드는 cross-file로 자유롭게 접근된다 (이동 비용 0)

Zig에는 **필드 privacy가 없다**. 다른 파일의 free 함수도 `self.cells`·`self.cursor`·`self.parser` 같은 필드를 직접 읽고 쓴다(osc.zig가 `self.default_fg_rgb` 등을, core가 `Scrollback.ring`을 직접 다루는 것이 증거). → **이번 범위에서 필드는 옮기지 않는다.** 함수(연산)만 목적별 파일로 옮긴다. 필드를 `Screen` 하위 struct로 접는 일은 §2의 별도 후속(2단계)이다.

### 1.2 dot-call 메서드는 struct decl에 남아야 한다 (얇은 위임 메서드)

`term.write(bytes)`·`term.resize(...)`·`term.snapshot()`처럼 **외부(app/session/test)가 점 문법으로 부르는 메서드**는 `TerminalCore`의 decl이어야 한다(Zig의 `a.b()` = `@TypeOf(a).b(a)` — `b`는 그 타입의 decl). 따라서 public API는 core에 **얇은 위임 메서드**로 남고 본문만 옮긴다:

```zig
// core.zig — 경계상 필연(Zig dot-call 문법). 본문은 screen.zig가 소유.
pub fn resize(self: *TerminalCore, cols: u16, rows: u16) !void {
    return screen.resize(self, cols, rows);
}
```

이는 레거시 shim이 아니라 **facade 메서드**다(osc.zig의 `dispatchOsc` 라우터가 core에 남은 것과 같은 결). `docs/project-rules.md` "구조와 파일 분리"의 facade-유지 원칙 그대로이며, 위임임을 주석으로 밝힌다(근거 없는 병존 금지 — full-removal 규칙 준수).

외부가 점 문법으로 부르는 public 메서드 실측(범위 확정용):

| 메서드 | 외부 호출 수(src/session·app·renderer) |
|---|---|
| `.write(` | 38 |
| `.snapshot(` | 37 |
| `.resize(` | 8 |
| `.scrollViewport(` | 4 |
| `.setMaxScrollback(` `.selectionStart(` `.renderSnapshot(` | 각 1 |

→ 이 메서드들은 위임 래퍼로 **시그니처 불변** 유지. 외부 호출부·ABI·스냅샷 포맷은 **한 줄도 바뀌지 않는다**.

### 1.3 내부 leaf 함수는 free 함수로 완전 이동 (shim 금지)

`self.cursorPosition()`·`self.dispatchCsi()`처럼 **내부에서만 호출되는** 함수는 새 파일에 `pub fn cursorPosition(self: *TerminalCore, ...)` free 함수로 옮기고, **모든 호출부를 `screen.cursorPosition(self)`/`parser.dispatchCsi(self, ...)`로 전수 갱신**하며 core의 원본은 삭제한다(병존·shim 금지 — `full-removal-no-legacy-shims`). 컴파일러가 누락을 강제하므로 동작 보존이 기계적으로 검증된다.

### 1.4 pub 승격은 terminal 레이어 내부 가시성일 뿐

이동한 free 함수가 core에 남은 메서드를 `self.x()`로 부르려면 그 메서드가 `pub`여야 한다(private는 core.zig 안에서만 보임). 이 **pub 승격은 terminal 레이어 내부 가시성**이며, facade(`terminal.zig`)가 re-export하는 큐레이션된 표면과 **무관**하다(terminal.zig는 지정한 심볼만 노출). 즉 core.TerminalCore의 내부 pub decl이 늘어도 외부에 새 API가 새지 않는다.

### 1.5 ParserState enum·파서 버퍼 필드는 core에 남긴다 (순환 회피)

`parser: ParserState` 필드의 타입을 parser.zig로 옮기면, core struct 레이아웃이 parser.zig 해석을 강제하고 parser.zig의 `const TerminalCore = core.TerminalCore`가 다시 core를 강제하는 comptime 순환 위험이 있다. **field 타입은 옮기지 않는다** — `ParserState` enum과 `csi_*`·`osc_*`·`dcs_*`·`apc_*`·`kitty_chunk*`·`utf8_tail*` 필드는 core.zig struct에 그대로 둔다. parser.zig free 함수는 `self.parser = .escape`처럼 **enum 리터럴**로 쓰므로 타입명을 명시할 필요가 없다(명시가 필요하면 `pub const ParserState`를 core에 둔 채 참조).

### 1.6 순환 import은 osc.zig가 이미 검증한 그래프

```
core.zig  ⇄  parser.zig      (core가 parser.* 위임 호출, parser가 *TerminalCore 사용)
core.zig  ⇄  screen.zig      (동형)
parser.zig →  screen.zig     (CSI dispatch가 screen 연산 호출)
parser.zig →  osc.zig        (OSC 라우터가 핸들러 호출)
```

이는 `core.zig ⇄ osc.zig`(이미 머지·컴파일됨)와 동형이다. Zig는 함수 **본문을 lazy 분석**하고 free 함수는 `*TerminalCore`(포인터 — 레이아웃 의존 없음)만 쓰므로 순환이 풀린다. parser↔screen 상호 import도 같은 이유로 안전하되, **불필요한 의존을 줄이려 screen.zig가 parser.zig를 import하지 않도록** 이동 순서를 잡는다(§4: screen 연산을 먼저 옮겨 parser가 screen을 단방향 호출).

### 1.7 테스트는 core.zig에 남아 public API로 동작을 보존한다

core.zig의 289개 테스트는 내부 함수를 이름으로 부르지 않고(유일 예외: 테스트-로컬 헬퍼 `cellsText4`) `write()`/`snapshot()` 등 **public API로만 구동**하며 필드를 읽는다. → 함수를 옮겨도 테스트는 안 깨지고, 이 테스트 묶음이 **매 PR의 동작-보존 그물**이 된다. 테스트는 facade를 검증하므로 core.zig에 둔다(파서/스크린 전용 순수 헬퍼 단위 테스트는 필요 시 새 파일에 소량 추가).

---

## 2. 전략 정합성 — 채택한 결정 (방향 A, 확정·완료)

> **결정 완료:** 아래 두 옵션 중 **(A) 연산 추출 우선**을 사용자와 합의해 채택했고, 분할 5~21/N으로 전부 실행·머지했다. 필드는 평평하게 둔 채 함수만 parser.zig/screen.zig로 옮겼다. Screen struct fold(2단계)는 §6 후속 별도 initiative로 남는다. 아래는 그 결정의 근거 기록이다.

[architecture.md §"스크롤백은 화면에 귀속한다"](architecture.md#스크롤백은-화면screen에-귀속한다)가 분해의 **종착지(2단계)**를 정의한다 — cursor·grid까지 포함한 완전한 `Screen` 구조체로 필드를 접고 그 자리에 page-aligned storage를 얹는 것(원문·갱신은 그 문서를 단일 출처로 둔다; 여기서는 verbatim 복제 대신 링크로 참조). 즉 최종 목표는 `cells`/`cursor`/`wrapped`/`prompt_marks`/`sb` 등 **필드를 `Screen` 하위 struct로 접고** `TerminalCore`가 `screen: Screen`을 보유하는 형태다. 그런데 이번 작업을 **그 형태로 직행**하면:

- `self.cells`→`self.screen.cells`, `self.cursor`→`self.screen.cursor`가 core.zig 9,962줄 + 외부 호출부(`term.cursor`/`term.cells`를 읽는 곳) + 289 테스트 + 스냅샷/ABI 전반에 퍼진다.
- 한 PR이 거대해지고 동작-보존 검증이 어려워진다(고위험 단일 도약).

그래서 이번 문서는 **연산 추출(중간 단계, 잠정 "1.5단계")**을 제안한다:

- **필드는 평평하게 둔 채**(§1.1) parser 상태기계와 active-screen 연산만 목적별 파일로 가른다(osc.zig + Scrollback 선례 그대로).
- 외부 호출부·ABI·스냅샷 **불변**(§1.2). 위험은 PR 단위로 격리되고, 매 PR을 기존 289 테스트로 보존 검증.
- 연산이 깨끗이 갈린 뒤, **필드를 `Screen`으로 접는 2단계**는 별도 initiative로 진행(그땐 함수가 이미 screen.zig에 모여 있어 fold가 기계적).

### 검토한 옵션 (A 채택)

| 옵션 | 내용 | 위험 | 정합성 |
|---|---|---|---|
| **(A) 연산 추출 우선** ✅ 채택 | 필드는 평평하게, 함수만 parser.zig/screen.zig로. 2단계(Screen struct fold)는 후속 별도 initiative. | 낮음(PR별 격리, 선례 동형) | architecture.md 2단계의 **선행 단계**임을 문서·커밋에 명시 |
| **(B) Screen struct 직행** | cells/cursor/… 필드를 Screen struct로 접으며 동시에 연산 이동. | 높음(필드 접근 전수 변경·ABI·스냅샷·외부 호출부) | architecture.md 2단계 종착지에 한 번에 도달 |

(A)를 채택했다 — "코어 심장부라 위험하니 doc-first, 저위험 단위부터"라는 요청과 직접 부합하고, architecture.md 전략을 **수정하지 않고 그 1.5단계로 정렬**하기 때문이다. §3~§5대로 진행해 분할 5~21/N으로 완료했다.

---

## 3. 책임 분류 (함수 단위)

함수를 행선지별로 분류한다. `(pub)`=현재 외부 가시. 굵은 항목은 외부 점-호출 facade(위임 메서드로 잔류).

### 3.1 → `parser.zig` (바이트 해독 + 시퀀스 dispatch)

- **상태기계 루프**: `write`(pub, 위임 메서드로 잔류 — 본문은 `parser.feed(self, bytes)`로), `handleEscapeByte`, `beginCsi`, `csiNextParam`, `handleCsiByte` — ⚠️ **실제 결과**: `csiRawParam`/`csiParam`은 계획과 달리 **core 잔류**(param 저장소 `csi_params` 필드와 한 묶음, parser/screen이 cross-file 호출, §3.3 참조)
- **CSI dispatch**: `dispatchCsi`, `setPrivateModes`, `setAnsiModes`, `repeatLastChar`, `kittyFlagsFromParam`
- **SGR 파싱**: `applySgr`, `applyExtendedColor`
- **OSC 라우터**: `dispatchOsc`(→ osc.zig 핸들러 위임)
- **DCS 서브시스템**: `dispatchDcs`, `dispatchXtgettcap`, `respondXtgettcap`, `appendXtgettcapInvalid`, `appendHexEncoded`, `decodeHex`, `hexNibble`, `dispatchDecrqss`, `appendDecrqssSgr`, `appendSgrColor`, `appendSgrUnderlineColor`
- **APC/kitty graphics 파싱·라우팅**: `dispatchApc`, `parseKittyGraphicsCommand`, `abortKittyChunk`(파서 버퍼 리셋) — 실제 kitty 이미지 exec/display/transmit/delete는 **core 잔류**(범위 밖, 후속 `kitty.zig` 후보), parser는 파싱 후 `self.execKittyGraphics(...)`(pub) 호출
- **UTF-8 intake**: `completePendingUtf8`, `storePendingUtf8`, `utf8SequenceLength`(top-level), `decodeUtf8`(top-level)
- **host-reply report**(시퀀스 응답): `deviceStatusReport`, `reportPrivateMode`, `reportKittyFlags`

### 3.2 → `screen.zig` (활성 grid/cursor/scroll storage·연산)

- **cursor 이동/위치**: `cursorPosition`, `setOriginMode`, `resolveRow`, `cursorVertical`, `cursorHorizontal`, `cursorToColumn`, `cursorToRow`, `setCursorStyle`, `clampSavedCursor`(top-level)
- **erase/insert/delete**: `eraseInLine`, `eraseCharacters`, `insertChars`, `deleteChars`, `eraseInDisplay`, `repairWideGlyphEdges` — ⚠️ **실제 결과**: `clearScreen`은 계획과 달리 **core 잔류**(`isPromptish`(prompt 마크 storage)와 결합, §3.3 참조)
- **scroll/feed**: `lineFeed`, `reverseIndex`, `scrollRegionUp`, `scrollRegionDown`, `scrollRangeUp`, `scrollRangeDown`, `insertLines`, `deleteLines`, `setScrollRegion`, `decAlign`
- **print 경로**: `writeCodepoint`, `putCell`, `clearCellForWrite`, `attachCombiningMark`, `promoteLastToEmojiWidth`, `wideContinuationCell`, `isSkinToneModifier`, `isRegionalIndicator`, `lastCellIsWideEmoji`, `lastCellIsLoneRegionalIndicator`, `translateCharset`, `decSpecial`, `designateCharset`
- **alt screen + saved cursor**: `enterAltScreen`, `leaveAltScreen`, `saveCursorState`, `restoreCursorState`, `restoreFromSlot`, `activeSavedCursor`
- **tabstops**: `isTabstop`, `resetTabstops`, `rebuildTabstops`, `writeTab`, `cursorBackTab`, `clearTabstop`
- **dirty 추적**: `markDirty`, `markCursorMoveDirty`, `markCursorRowDirty`, **`takeDirty`(pub)**, **`clearDirty`(pub)**
- **resize/reflow**: **`resize`(pub)**, `ensureReflowScratch`, `copyRegionResize`, `trimmedRowLen`, `isBlankCell`, `outputRowBlank`, `clearTruncatedWideBase`
- **snapshot/viewport**: **`snapshot`(pub)**, **`renderSnapshot`(pub)**, `drawPreeditCells`, `snapshotWithPreedit`, **`viewportRow`/`viewportHasBlink`/`viewportRowPrompt`/`viewOffset`(pub)**
- **스크롤백 행 저장·재-wrap + 절대행 accessor**(screen.zig로 이동): `pushScrollback`, `clearScrollback`, `ensureScrollbackRewrapped`, `rewrapScrollback`, `rewrapScrollbackAnchored`, `rewrapScrollbackInner`, `countRewrapRows`, `trimmedLen`, `absRow`, `absRowWrapped`(`absRow`/`absRowWrapped`는 §7 S1/11b/N에서 이동 — selection→screen 단방향 확보)
- ⚠️ **실제 결과 — core 잔류 스크롤백 accessor**: `scrollbackLen`/`maxScrollback`/`setMaxScrollback`/`scrollbackRow`/`scrollViewport`/`scrollToBottom`/`scrollToAbs`/`scrollbackRowWrapped`/`scrollbackRowPrompt`(pub)는 §3.2 계획과 달리 **core 잔류** — `self.sb` 필드를 직접 읽는 trivial accessor(scrollbackRow=`self.sb.ring[...]` 3줄 등)라 이동 이득이 작고, screen.zig가 `self.scrollbackRow(...)`로 호출(§3.3)
- **grid 헬퍼**: `index`, `cellCount`(top-level), `fullDirty`(top-level), `clampGridSize`(pub, facade re-export — core가 `screen.clampGridSize` re-export하거나 core 잔류)

### 3.3 core.zig 잔류 (이번 범위 밖)

- **라이프사이클**: `init`, `deinit`, `fullReset`, `resetInputModes`, `clearLinkStore`
- **선택/검색/URL**(후속 `selection.zig` 후보): `selection*`, `wordBounds*`, `selectWordAt`, `selectLineAt`, `selectAll`, `findMatches`, `matchViewportSpan`, `extractSelection`, `extractBlockSelection`, `extractUrlAt`, `urlAnchorAt`, `urlSpanAtAbs`, `urlSpanInWord`, `wordIsUrl`, `cellLinkAt`, `linkBoundsAt`, `appendRowUtf8`, `foldCase`, `matchAtIgnoreCase`, `clipAbsSpanToViewport`, `normalizedSelection`, `absRowFromViewport`, `shiftSelectionForEviction`, `shiftCoordsForEviction`, `invalidateSelection`, `setPreedit`
- **prompt 마크/semantic storage**: `promptAtAbs`, `isPromptish`, `isPromptStart`, `setPromptExitAtAbs`, `stampPromptExit`, `jumpToPrompt`(선택과 얽혀 잔류, screen이 pub로 호출), `clearScreen`(`isPromptish` 결합으로 §3.2 erase 클러스터 중 유일하게 core 잔류)
- **CSI param 접근자**: `csiRawParam`, `csiParam`(pub) — param 저장소 `csi_params`/`csi_param_count` 필드와 한 묶음이라 core 잔류, parser(`dispatchCsi`·`applySgr`)·screen(`cursorPosition`·`setScrollRegion`)이 cross-file 호출
- **core 잔류 스크롤백 accessor**(§3.2 참조): `scrollbackRow`/`scrollbackRowWrapped`/`scrollbackLen`/`scrollViewport` 등 9개 — `self.sb` 직접 접근하는 trivial accessor. screen.zig의 `absRow`/`ensureScrollbackRewrapped` 등이 `self.scrollbackRow(...)`로 호출(`self` 메서드, 순환 무관). (`absRow`/`absRowWrapped`는 S1에서 screen.zig로 이동 완료 — 더 이상 core 잔류 아님)
- **kitty graphics 본체**(후속 `kitty.zig` 후보): `execKittyGraphics`, `kittyDisplay`, `kittyAdvanceRows`, `addOrReplacePlacement`, `removePlacementsForImage`, `removeOnePlacement`, `kittyDelete`, `deleteByZ`, `shiftPlacementsForEviction`, `buildPlacementViews`, `buildImageViews`, `storeKittyImage`, `evictKittyImagesFor`, `pickKittyEvictionVictim`, `kittyImageHasPlacement`, `kittyTransmit`, `kittyTransmitPng`, struct들(`KittyGraphicsCommand`/`KittyImage`/`KittyImageStorage`/`StoredPlacement`)
- **host-reply/encoding 상태·접근자**: `appendResponse`/`pendingResponse`/`clearResponse`, `reportFocus`, `reportMouse`, `encodeKey`, `encodeOptions`, `recordShellEvent`/`shellEvents`/`clearShellEvents`/`shellEventsOverflowed`, `internLink`/`linkUri`, `setWindowTitle`/`windowTitle`/`currentCwd`/`sshRemoteDest`, `setCellMetrics`/`setDefaultColors`/`setConfigPalette`, `defaultFgOverride`/`defaultBgOverride`/`paletteOverride`/`reverseScreen`, clipboard·notification·bell 접근자, `encodePaste`, `dumpUtf8`
- **enum/const**: `ParserState`(§1.5), `Charset`, `MouseTracking`, `MouseFormat`, `KittyFlags`, `KittyFlagStack`, `KittySetMode`, `SavedCursor`, `max_csi_params`, `default_max_scrollback`, kitty 상한들

> 경계 메모: selection/search·kitty graphics는 screen 연산을 많이 부른다 — `viewportRow`·`absRow`(S1 이후) 등이 screen.zig pub라 core 잔류 코드가 `screen.absRow(self, ...)`로 부른다(단방향, 순환 무관). selection 자체의 분리는 **§7에서 진행**, kitty 분리는 **이번 범위 밖**(향후 kitty.zig, §6). 

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
| **18/N** | snapshot/viewport(`snapshot`·`renderSnapshot` 위임·`drawPreeditCells`·`snapshotWithPreedit`·viewport 접근자) | 렌더 출력 계약 — 스냅샷 동작 보존 필수 | 높음 |

### Phase D — parser 상태기계 본체 (마지막, screen.zig 함수 참조)

| PR | 범위(이동) | 비고 | 위험 |
|---|---|---|---|
| **19/N** | SGR+모드 dispatch(`applySgr`·`applyExtendedColor`·`setPrivateModes`·`setAnsiModes`·`repeatLastChar`·report 3개·`kittyFlagsFromParam`) | 모드 setter가 screen·다수 필드 건드림 | 높음 |
| **20/N** | CSI dispatch(`dispatchCsi`·`beginCsi`·`csiNextParam`·`handleCsiByte`) | `csiRawParam`/`csiParam`은 param 저장소와 한 묶음이라 core 잔류(실제 결과). ~40개 `screen.x(self)` 호출(이미 이동됨) | 높음 |
| **21/N** | escape+UTF-8 intake+write 루프(`handleEscapeByte`·`completePendingUtf8`·`storePendingUtf8`·`utf8SequenceLength`·`decodeUtf8`; write 본문→`parser.feed`, core `write`는 위임) | 진입점 — 호출 대상이 전부 이동 완료된 상태 | 최고 |

> 위 21개는 선례(분할 1~4/N)의 granularity를 잇는 상한이다. 합의 시 인접 저위험 PR을 합쳐 수를 줄일 수 있다(예: 8+9, 5+6). granularity는 합의 사항.

---

## 5. 검증 프로토콜 (매 PR)

각 PR은 머지 전 다음을 모두 green으로 확인하고, green에서만 `--rebase` auto-merge(admin 금지 — `merge-only-on-green`):

1. `zig build test` — 터미널 코어 289 테스트(동작-보존 그물, §1.7) + 전체 단위.
2. `zig build macos-app-build` — macOS 앱이 바뀐 코어에 대해 **컴파일**되는지(코어는 앱 핫패스의 소비처 — `run-macos-app-before-merge`/`macos-build-sandbox-framework-cache`). addExecutable green을 컴파일 기준으로.
3. `zig build check-boundaries` — facade import 경계·중립성. parser.zig/screen.zig는 `src/terminal/` 안이라 terminal 레이어 규칙을 받으며 pty/platform/renderer를 import하면 빌드 실패(현 설계는 `core`/`types`/`osc`/`screen`/`width`만 import — 통과).
4. `mise run fmt-check` — 포맷.
5. perf 민감 PR(14/N scroll, 17/N resize, 16/N print)은 `mise run perf`로 예산 회귀 확인(reflow alloc churn 전례).

추가 게이트:

- **동작 보존 정의**: 기존 테스트가 전부 통과 = "무슨 시퀀스가 무슨 일을 하는가"가 불변. 새 동작/필드를 추가하지 않는 순수 이동 PR이 원칙.
- **PR 본문**: `pr-checklist.md` 9개 섹션 전부(`pr-template-strict`). VT 동작을 옮기는 PR은 clean-room 근거를 유지하되 "동작 변경 없음, 코드 이동만"을 명시.
- **마지막 PR(21/N) 후**: `zig build macos-app`를 실제 실행해 키 입력→화면까지 핫패스를 한 번 확인(`run-macos-app-before-merge` — write 루프가 앱 핫패스라).
- **각 PR은 단일 revert로 안전**: 순수 이동이라 회귀 시 그 커밋만 되돌리면 원복.

---

## 6. 미해결/후속 (이번 범위 밖, 기록만)

- **2단계(Screen struct fold)**: §2 — 필드를 `Screen` 하위 struct로 접는 architecture.md 종착지. 연산 추출 완료 후 별도 initiative.
- **selection.zig** ✅ **완료**: 선택/검색/URL/preedit 클러스터를 §7(S1~S5)로 분리 완결(core.zig 7228→6715줄, selection.zig 587줄(리뷰 cleanup 후)).
- **kitty.zig** ✅ **완료**: kitty graphics 본체를 §8(K1~K3)로 분리 완결(core.zig 6715→6233줄, kitty.zig 516줄). parser는 파싱(7/N) + `kitty.execKittyGraphics` 위임.
- **input/report.zig**: `reportFocus`/`reportMouse`/`encodeKey` 등 입력→host-reply 인코딩.

---

## 7. selection.zig 분리 (후속 initiative — ✅ 완료, S1~S5)

§6의 selection.zig 후속을 §1~§5와 **같은 절차·메커니즘**(방향 A, 연산 추출, facade 보존, 매 PR green auto-merge)으로 진행한다. 선택/검색/URL/IME-preedit 클러스터(현 core.zig 822~1470, 함수 ~30개)를 `selection.zig`로 떼어낸다.

### 7.1 경계 설계 (레이어 방향)

selection은 화면/스크롤백을 **읽어** 좌표·텍스트를 산출하는 **상위 레이어**다. 의존 방향은 `selection → screen → (types)` 단방향이어야 한다(`screen`이 `selection`을 import하면 하향 역전 — 금지).

- **selection.zig가 부르는 것**: `screen.ensureScrollbackRewrapped`·`screen.isBlankCell`·`screen.absRow`/`absRowWrapped`(S1 이후)·core 필드(`selection_anchor`/`head`/`block`·`sb`·`view_offset`·`size`·`link_store`)·top-level `core.fullDirty`.
- **core 잔류 seam(screen↔selection 다리)**: `invalidateSelection`(screen이 6곳서 `self.invalidateSelection()` 호출 — 옮기면 screen→selection 역전이라 core 잔류, 본문은 `self.selectionClear()` 한 줄), `shiftCoordsForEviction`(선택+kitty placement eviction 조율 — selection 부분만 `selection.shiftSelectionForEviction(self,n)`로, kitty 부분은 core).
- **core 잔류 facade delegator**(외부 dot-call이라 struct 메서드 필수, §1.2): `selectionStart`·`selectionExtend`·`selectWordAt`·`setSelectionBlock`·`selectLineAt`·`selectAll`·`selectionClear`·`selectionViewportSpan`·`extractSelection`·`extractUrlAt`·`urlAnchorAt`·`urlSpanAtAbs`·`findMatches`·`matchViewportSpan`·`setPreedit`. 본문은 selection.zig로, core엔 `pub fn X(self,...) { return selection.X(self,...); }`.
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
| **S5** ✅ | 검색 + 추출 + preedit(`findMatches`·`matchViewportSpan`·`selectionViewportSpan`·`extractSelection`·`extractBlockSelection`·`setPreedit`) | normalizedSelection/foldCase/match(S2)·clip(S2)에 의존. facade 5개(findMatches·matchViewportSpan·selectionViewportSpan·extractSelection·setPreedit), extractBlockSelection은 내부(extractSelection이 호출). preedit는 core 필드 — selection.zig가 alloc/free만. **selection.zig 분리 완결** | 중 |

> **selection.zig 분리 완결**(S1~S5 머지): core.zig 7228→6715줄, selection.zig 587줄(리뷰 cleanup 후). core 잔류 = facade 16개(점-호출 API)·seam(invalidateSelection·shiftCoordsForEviction)·필드(selection_anchor/head/block·preedit·link_store)·linkUri(pub). 후속 별도 initiative: kitty.zig(§6)·Screen struct fold(§2).

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

> **kitty.zig 분리 완결**(K1~K3 머지): core.zig 6715→6233줄, kitty.zig 516줄. core 잔류 = 별칭 3개(필드 타입 KittyGraphicsCommand·StoredPlacement·KittyImageStorage)·필드(kitty_images·kitty_placements·kitty_chunk_cmd·placement_views·image_views)·facade 2개(buildPlacementViews·buildImageViews)·seam(shiftCoordsForEviction→kitty.shiftPlacementsForEviction)·KittyFlags/KittyFlagStack(keyboard protocol). 후속 남음: input/report.zig(§6)·Screen struct fold(§2).

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

## 10. Screen struct fold (방향 B, 2단계) — 설계·합의 대기

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

> 공통: parser 상태(parser·csi_*·osc_*…)·host-reply(response·clipboard·notification·shell_events)·selection(anchor/head/preedit)·kitty(images/placements)·터미널 모드(mouse·bracketed_paste·focus_events·kitty_flags…)·config/metrics(cell_*_px·palette·default_*)·alt_active(swap 상태 자체)·reflow scratch는 화면 content가 아니라 **core 잔류**. `size`(두 화면 공유 geometry)·`dirty`(렌더 추적)는 B-min에선 core 잔류, B-full에서도 공유라 core 권장.

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
