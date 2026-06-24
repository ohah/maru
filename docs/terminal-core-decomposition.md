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
- **input_report.zig** ✅ **완료**: `reportFocus`/`reportMouse`/`encodeKey`/`encodeOptions`/`encodePaste` 입력→host-reply 인코딩을 §9(R1)로 분리 완결(core.zig facade 5개 + input_report.zig 112줄).
- **RIS가 DECSC 슬롯 초기화** ✅ **완료**(B4~B5 리뷰서 확인, §10.8.7): `fullReset`(ESC c)이 `screen.saved_cursor`를 안 비우던 기존 동작(평평 슬롯 시절부터 — 분해가 도입한 게 아님)을 고쳐, RIS가 슬롯도 공장 초기화한다(이후 DECRC/CSI u는 home 복원). **베이스**: VT100 RIS = power-on 상태 + Ghostty `Screen.reset()`이 `saved_cursor=null`. **결정**: RIS는 완전한 공장 리셋이므로 저장 커서도 비우는 게 정합(슬롯 생존은 사실상 버그). alt는 RIS의 leaveAltScreen으로 이미 폐기돼 활성(primary) 슬롯만 비우면 충분. 테스트 1건 추가.
- **setup-path OOM 누수**(§11 A1 OOM-sweep서 발견, 범위 밖): `FailingAllocator`로 write/resize 도중 할당을 실패시키면 일부 경로가 할당을 잃는다(스크롤백 page 저장과 무관 — 기존 코드). A1 rewrap OOM 테스트는 실패 주입을 rewrap 단계로 한정해 우회했다. 별도 후속으로 grapheme/reflow scratch·write 경로의 OOM errdefer를 감사한다(크래시 아님 — best-effort OOM 경로의 누수).

---

## 7. selection.zig 분리 (후속 initiative — ✅ 완료, S1~S5)

§6의 selection.zig 후속을 §1~§5와 **같은 절차·메커니즘**(방향 A, 연산 추출, facade 보존, 매 PR green auto-merge)으로 진행한다. 선택/검색/URL/IME-preedit 클러스터(현 core.zig 822~1470, 함수 ~30개)를 `selection.zig`로 떼어낸다.

### 7.1 경계 설계 (레이어 방향)

selection은 화면/스크롤백을 **읽어** 좌표·텍스트를 산출하는 **상위 레이어**다. 의존 방향은 `selection → screen → (types)` 단방향이어야 한다(`screen`이 `selection`을 import하면 하향 역전 — 금지).

- **selection.zig가 부르는 것**: `screen.ensureScrollbackRewrapped`·`screen.absRow`/`absRowWrapped`(S1 이후)·core 필드(`selection_anchor`/`head`/`block`·`sb`·`view_offset`·`size`·`link_store`)·top-level `core.fullDirty`. 단어/URL 경계 공백은 `screen.isBlankCell`(배경 기본값까지 요구)이 아니라 selection 내부 `isBoundarySpace`(배경 무관 — bce로 색칠한 공백도 경계)로 판정한다.
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

### 10.8.7 B4~B5 리뷰 cleanup (`/code-review max` 후속, B6)

누적 리뷰(라인별·removed-behavior·cross-file/state·Zig pitfall·cleanup/altitude/conventions 6각 + verify/sweep) 결과 **정확성 버그 0**(crash-class 0): per-screen 커서/슬롯 swap이 모든 경로(1049/1047/47·이미-alt·이미-primary·DECSC·CSI s/u·resize-during-alt)에서 의도대로 동작, flat 필드 잔존 0(전 트리 grep), 레이아웃 cycle 없음(TerminalCore→Screen→SavedCursor→primitives 종료), snapshot/serialize/render/IME 모두 활성 `self.screen.cursor`만 읽음. 유일한 실버그였던 "resize-during-alt가 보관 primary 커서 미clamp → 복귀 시 OOB"는 **B4 구현 중 발견·동PR 수정+테스트**됐다(리뷰가 재확인).

cleanup 2건만 정리(B6):

1. **resize alt 분기 중복 → `clampScreenCursorForResize(s, size)` 헬퍼**: 활성·보관 두 화면에 같은 5연산(커서·DECSC 슬롯 clamp + pending_wrap/last_print 무효화)을 손으로 복제하던 것을 swap 단위(Screen) 한 헬퍼로 묶어 drift 위험 제거(altitude — 두 블록이 어긋나면 OOB-after-leave 버그 재발).
2. **`activeSavedCursor` 인라인**: B5가 `alt_active` 분기를 없애 `&self.screen.saved_cursor` 한 줄 래퍼만 남았고 doc 주석이 사라진 분기를 재정당화 → `saveCursorState`/`restoreCursorState`에 직접 접근 + 근거를 `saveCursorState` 주석으로 이관, 함수 제거.

**후속 발견 → ✅ 해결**: RIS(`ESC c`)가 DECSC 슬롯(`screen.saved_cursor`)을 안 비우던 기존 동작(B4/B5 이전부터 — 평평 슬롯 시절에도 미초기화, 분해가 도입한 게 아님)을 별도 fix PR로 정합성 수정했다(베이스 VT100 RIS + Ghostty `Screen.reset()` saved_cursor=null, §6 참조). 사용자 합의 후 page storage 설계 전 area를 깨끗이 닫음.

---

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

### 11.7 A2 설계 — 가변폭/trailing-trim (실제 메모리 절감, 설계·합의 대기)

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

### 11.9 P4 설계 — mmap backing for 스크롤백 page arena (설계·합의 대기)

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
