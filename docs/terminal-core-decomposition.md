# TerminalCore(core.zig) 분해: Parser/Screen 분리 설계

`src/terminal/core.zig`(분해 시작 시점 9,962줄·573KB·함수 236개·테스트 289개)는 VT **파서 상태기계** + **화면/스크롤백 storage** + **host-reply/encoding**을 한 struct에 섞고 있었다. 이는 `docs/project-rules.md` "구조와 파일 분리"(한 파일이 parser·storage·encoding처럼 서로 다른 이유로 바뀌면 facade는 유지하되 구현을 목적별로 분리) 위반이었다. 이 문서는 그 분해(parser·active screen storage)의 설계·메커니즘·PR 시퀀스를 단일 출처로 둔다.

> **상태: 분해 완결**(분할 1~21/N + 리뷰 3배치 머지). core.zig는 7,228줄로 줄고 parser.zig(989줄)·screen.zig(2,001줄)·osc.zig(294줄)로 분리됐다. 이 문서는 이제 **완료된 분해의 설계 기록**이며, §0 현황표가 최종 결과를, §2가 채택한 전략(방향 A)을, §6이 후속 별도 initiative를 담는다.
>
> **줄 수 읽는 법**: 본문의 줄 수는 각 분할 **머지 시점 기록**이다(역사 보존). 이후 후속 작업(§10 Screen struct fold·§11 page storage·grapheme(HG)·link-detection·OSC 52 대용량 등)으로 파일이 커져, 2026-07 실측은 core.zig 7,648줄·parser.zig 1,049줄·screen.zig 2,219줄·osc.zig 306줄·selection.zig 810줄·kitty.zig 517줄·input_report.zig 111줄이다. "분해 완결"은 책임 분리가 끝났다는 뜻이지 줄 수가 고정된다는 뜻이 아니다.

이 문서는 `AGENTS.md` 설계 문서 인덱스에 연결된다. 분해 작업의 경계·메커니즘·PR 시퀀스를 바꿀 때는 이 문서를 먼저 갱신한다.

> 관련 전략 문서: [초기 아키텍처](architecture.md#스크롤백은-화면screen에-귀속한다) §"스크롤백은 화면에 귀속한다"(2단계 = 완전한 `Screen` 구조체), [레이어링과 이식성](layering-and-portability.md), `src/terminal/README.md`(parser·screen·cursor·scrollback·key/mouse encoding으로 분리한다는 폴더 계약).

---

## 문서 구성

이 문서는 **왜 그렇게 갈랐는가**만 소유한다 — 분리 메커니즘, 채택한 전략, 함수 단위 책임 분류,
매 PR 검증 프로토콜. 이들은 다른 분해(`app_session` 등)가 선례로 인용하는 재사용 가능한 계약이다.

무엇을 어떤 순서로 옮겼는지와, 그 뒤에 붙은 별개 이니셔티브는 계획 문서가 소유한다.

| 절 | 문서 | 소유 |
|---|---|---|
| §1~§3 · §5 | 이 문서 | 분리 메커니즘, 방향 A 채택 근거, 책임 분류, 검증 프로토콜 |
| §0 · §4 · §6~§9 | [분해 기록](plans/terminal-core-decomposition.md) | PR 시퀀스와 결과, selection·kitty·input_report 후속 |
| §10 | [Screen struct fold](plans/screen-struct-fold.md) | 방향 B — B-min 확정, B-full 설계 |
| §11 | [page-aligned storage](plans/page-aligned-storage.md) | 페이지 모델 전환, P0 측정, 진행 결정 |

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
- **snapshot/viewport**: **`snapshot`(pub)**, **`renderSnapshot`(pub)**, **`viewportRow`/`viewportHasBlink`/`viewportRowPrompt`/`viewOffset`(pub). IME 합성은 이후 `Surface.renderSnapshot`→`PreeditOverlay`로 이동해 screen/core 범위가 아니다.
- **스크롤백 행 저장·재-wrap + 절대행 accessor**(screen.zig로 이동): `pushScrollback`, `clearScrollback`, `ensureScrollbackRewrapped`, `rewrapScrollback`, `rewrapScrollbackAnchored`, `rewrapScrollbackInner`, `countRewrapRows`, `trimmedLen`, `absRow`, `absRowWrapped`(`absRow`/`absRowWrapped`는 §7 S1/11b/N에서 이동 — selection→screen 단방향 확보)
- ⚠️ **실제 결과 — core 잔류 스크롤백 accessor**: `scrollbackLen`/`maxScrollback`/`setMaxScrollback`/`scrollbackRow`/`scrollViewport`/`scrollToBottom`/`scrollToAbs`/`scrollbackRowWrapped`/`scrollbackRowPrompt`(pub)는 §3.2 계획과 달리 **core 잔류** — `self.sb` 필드를 직접 읽는 trivial accessor(scrollbackRow=`self.sb.ring[...]` 3줄 등)라 이동 이득이 작고, screen.zig가 `self.scrollbackRow(...)`로 호출(§3.3)
- **grid 헬퍼**: `index`, `cellCount`(top-level), `fullDirty`(top-level), `clampGridSize`(pub, facade re-export — core가 `screen.clampGridSize` re-export하거나 core 잔류)

### 3.3 core.zig 잔류 (이번 범위 밖)

- **라이프사이클**: `init`, `deinit`, `fullReset`, `resetInputModes`, `clearLinkStore`
- **선택/검색/URL**(후속 `selection.zig` 후보): `selection*`, `wordBounds*`, `selectWordAt`, `selectLineAt`, `selectAll`, `findMatches`, `matchViewportSpan`, `extractSelection`, `extractBlockSelection`, `extractUrlAt`, `urlAnchorAt`, `urlSpanAtAbs`, `linkSpanInWord`(구 `urlSpanInWord` — URL·파일 경로 분류로 확장, docs/link-detection.md), `wordIsUrl`, `cellLinkAt`, `linkBoundsAt`, `appendRowUtf8`, `foldCase`, `matchAtIgnoreCase`, `clipAbsSpanToViewport`, `normalizedSelection`, `absRowFromViewport`, `shiftSelectionForEviction`, `shiftCoordsForEviction`, `invalidateSelection`
- **prompt 마크/semantic storage**: `promptAtAbs`, `isPromptish`, `isPromptStart`, `setPromptExitAtAbs`, `stampPromptExit`, `jumpToPrompt`(선택과 얽혀 잔류, screen이 pub로 호출), `clearScreen`(`isPromptish` 결합으로 §3.2 erase 클러스터 중 유일하게 core 잔류)
- **CSI param 접근자**: `csiRawParam`, `csiParam`(pub) — param 저장소 `csi_params`/`csi_param_count` 필드와 한 묶음이라 core 잔류, parser(`dispatchCsi`·`applySgr`)·screen(`cursorPosition`·`setScrollRegion`)이 cross-file 호출
- **core 잔류 스크롤백 accessor**(§3.2 참조): `scrollbackRow`/`scrollbackRowWrapped`/`scrollbackLen`/`scrollViewport` 등 9개 — `self.sb` 직접 접근하는 trivial accessor. screen.zig의 `absRow`/`ensureScrollbackRewrapped` 등이 `self.scrollbackRow(...)`로 호출(`self` 메서드, 순환 무관). (`absRow`/`absRowWrapped`는 S1에서 screen.zig로 이동 완료 — 더 이상 core 잔류 아님)
- **kitty graphics 본체**(후속 `kitty.zig` 후보): `execKittyGraphics`, `kittyDisplay`, `kittyAdvanceRows`, `addOrReplacePlacement`, `removePlacementsForImage`, `removeOnePlacement`, `kittyDelete`, `deleteByZ`, `shiftPlacementsForEviction`, `buildPlacementViews`, `buildImageViews`, `storeKittyImage`, `evictKittyImagesFor`, `pickKittyEvictionVictim`, `kittyImageHasPlacement`, `kittyTransmit`, `kittyTransmitPng`, struct들(`KittyGraphicsCommand`/`KittyImage`/`KittyImageStorage`/`StoredPlacement`)
- **host-reply/encoding 상태·접근자**: `appendResponse`/`pendingResponse`/`clearResponse`, `reportFocus`, `reportMouse`, `encodeKey`, `encodeOptions`, `recordShellEvent`/`shellEvents`/`clearShellEvents`/`shellEventsOverflowed`, `internLink`/`linkUri`, `setWindowTitle`/`windowTitle`/`currentCwd`/`sshRemoteDest`, `setCellMetrics`/`setDefaultColors`/`setConfigPalette`, `defaultFgOverride`/`defaultBgOverride`/`paletteOverride`/`reverseScreen`, clipboard·notification·bell 접근자, `encodePaste`, `dumpUtf8`
- **enum/const**: `ParserState`(§1.5), `Charset`, `MouseTracking`, `MouseFormat`, `KittyFlags`, `KittyFlagStack`, `KittySetMode`, `SavedCursor`, `max_csi_params`, `default_max_scrollback`, kitty 상한들

> 경계 메모: selection/search·kitty graphics는 screen 연산을 많이 부른다 — `viewportRow`·`absRow`(S1 이후) 등이 screen.zig pub라 core 잔류 코드가 `screen.absRow(self, ...)`로 부른다(단방향, 순환 무관). selection 자체의 분리는 **§7에서 진행**, kitty 분리는 **이번 범위 밖**(향후 kitty.zig, §6). 

---

## 5. 검증 프로토콜 (매 PR)

각 PR은 머지 전 다음을 모두 green으로 확인하고, green에서만 `--rebase` auto-merge(admin 금지 — `merge-only-on-green`):

1. `zig build test` — 터미널 코어 289 테스트(동작-보존 그물, §1.7) + 전체 단위.
2. `zig build macos-app-build` — macOS 앱이 바뀐 코어에 대해 **컴파일**되는지(코어는 앱 핫패스의 소비처 — `run-macos-app-before-merge`/`macos-build-sandbox-framework-cache`). addExecutable green을 컴파일 기준으로.
3. `zig build check-boundaries` — facade import 경계·중립성. parser.zig/screen.zig는 `src/terminal/` 안이라 terminal 레이어 규칙을 받으며 pty/platform/renderer를 import하면 빌드 실패(현재 parser.zig는 `core`/`types`/`osc`/`screen`/`kitty`를, screen.zig는 `types`/`core`/`width`/`grapheme`를 import — 통과. §8 kitty 분리와 HG grapheme 모듈 추가가 반영된 목록).
4. `mise run fmt-check` — 포맷.
5. perf 민감 PR(14/N scroll, 17/N resize, 16/N print)은 `mise run perf`로 예산 회귀 확인(reflow alloc churn 전례).

추가 게이트:

- **동작 보존 정의**: 기존 테스트가 전부 통과 = "무슨 시퀀스가 무슨 일을 하는가"가 불변. 새 동작/필드를 추가하지 않는 순수 이동 PR이 원칙.
- **PR 본문**: `pr-checklist.md` 9개 섹션 전부(`pr-template-strict`). VT 동작을 옮기는 PR은 clean-room 근거를 유지하되 "동작 변경 없음, 코드 이동만"을 명시.
- **마지막 PR(21/N) 후**: `zig build macos-app`를 실제 실행해 키 입력→화면까지 핫패스를 한 번 확인(`run-macos-app-before-merge` — write 루프가 앱 핫패스라).
- **각 PR은 단일 revert로 안전**: 순수 이동이라 회귀 시 그 커밋만 되돌리면 원복.

---
