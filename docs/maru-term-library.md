# maru-term — 터미널 코어 npm 라이브러리

이 문서는 maru의 `TerminalCore`를 **웹 라이브러리로 배포하는 계약**의 단일 출처다. 코어를 wasm으로 만들 수 있는 조건과 그 제약은 [터미널 코어의 wasm 이식성](wasm-portability.md)이 소유하고, 이 문서는 그 위에서 **패키지 경계·공개 API·렌더/워커 계약·빌드 파이프라인**만 다룬다. 단계별 진행 상태는 [구현 계획](plans/maru-term-library.md)이 소유한다.

## 1. 범위

`@maru/*`는 브라우저에서 도는 터미널 에뮬레이터 컴포넌트다. VT 파싱·화면 상태·키 인코딩·폭 판정은 wasm(maru 코어)이 하고, 글리프 모양·폰트 폴백·DOM 통합은 웹이 한다.

**이 계약 밖**: PTY, 셸 프로세스, control plane. 바이트를 어디서 가져오는지는 소비자가 정한다(WebSocket, SSH-over-WS, 정적 trace 재생 등). maru 앱 자체를 브라우저로 옮기는 것도 범위 밖이다([렌더러 전략](renderer-strategy.md)의 비목표가 유효하다).

## 2. 패키지 경계

| 패키지 | 내용 | 의존 |
|---|---|---|
| `@maru/core` | wasm 바이너리, 바닐라 TS 코어, Canvas 렌더러, 워커, 테마 | 없음 |
| `@maru/react` | JSX 컴포넌트 | peer: `react`, `@maru/core` |
| `@maru/vue` | `defineComponent` + `h()` | peer: `vue`, `@maru/core` |
| `@maru/svelte` | 액션 `use:terminal` | peer: `svelte`, `@maru/core` |
| `@maru/lit` | `<maru-terminal>` 커스텀 엘리먼트 | peer: `lit`, `@maru/core` |

**코어는 프레임워크 패키지의 `peerDependency`다.** `dependency`로 두면 버전이 어긋날 때 wasm이 두 벌 로드돼 메모리를 두 배로 쓴다. 추가 방어로 코어는 같은 URL의 wasm에 대해 `WebAssembly.Module`을 모듈 스코프에 캐시한다.

**프레임워크 래퍼는 순수 TS(+JSX)로 쓴다.** 번들러(zntc)가 `.vue`·`.svelte`를 다루지 않기 때문이다(§6). 그래서 Svelte만 컴포넌트가 아니라 액션이다 — 마운트·업데이트·파괴 훅이 전부 있어 기능은 동등하다.

## 3. 공개 API 계약

**명령은 단방향이고 동기, 조회는 항상 `Promise`다.** 워커를 쓰든 안 쓰든 시그니처가 같아야 모드를 바꿔도 앱 코드가 안 바뀐다.

```ts
class Terminal {
  constructor(opts?: TerminalOptions)
  open(el: HTMLElement): Promise<void>
  write(data: string | Uint8Array): void
  resize(cols: number, rows: number): void
  dispose(): void

  fit(): void                                            // 컨테이너 크기에 격자를 맞춘다
  sendText(text: string | Uint8Array): void              // 코어 인코딩 없이 호스트로 그대로
  setPreedit(text: string): void                         // IME 조합(빈 문자열이면 물린다)

  onData(cb: (bytes: Uint8Array) => void): Disposable    // 키 입력 → 호스트로 보낼 바이트
  onPreedit(cb: (text: string) => void): Disposable      // 구독하면 조합을 앱이 그린다(§5)
  onTitle(cb: (title: string) => void): Disposable
  onBell(cb: () => void): Disposable
  onResize(cb: (size: Size) => void): Disposable
  onFallback(cb: (reason: FallbackReason) => void): Disposable

  measureCells(text: string): Promise<number>
  snapshot(): Promise<Snapshot>
  selectionText(): Promise<string | null>

  setTheme(theme: Theme): void
  setOptions(opts: Partial<TerminalOptions>): void
}
```

**격자는 기본이 컨테이너다.** `cols`/`rows`를 주지 않으면 `open(el)`이 요소 크기로 격자를 잡고 `ResizeObserver`로 따라간다 — 요소를 받는 API 이므로 그 크기를 따르는 것이 기본이어야 한다. 명시하면 그 격자를 그대로 지킨다. `fit()`은 **크기가 그대로면 아무것도 하지 않는다**: 리사이즈는 soft-wrap 을 재배치하고 커서를 옮기므로, 같은 값으로 다시 부르면 화면이 흐트러진다(`ResizeObserver`는 `observe()` 직후 한 번 발화한다).

### 옵션

| 옵션 | 기본 | 뜻 |
|---|---|---|
| `cols`·`rows` | 컨테이너에 맞춤 | 주면 그 격자를 지킨다 |
| `worker` | `"full"` | `false` 면 메인에서 돈다(§4) |
| `fontFamily` | 리가처 폰트 우선 체인(§5.1) | |
| `fontSize`·`lineHeight` | 14 · 1.22 | 늘어난 여백은 위아래로 나뉜다(§5) |
| `theme` | 어두운 기본값 | |
| `cursorShape` | 코어 판정 | `block`·`bar`·`underline` |
| `scrollback` | 1000 | 줄 수 |
| `ambiguousWide` | `false` | EAW Ambiguous 를 2셀로. **레이아웃이 통째로 갈린다** |
| `ligatures` | `true` | ASCII run 병합. 끄면 셀 단위로 그린다 |
| `loadFont` | 받지 않음 | `"jetendard"` 면 번들 한글 폰트를 받는다(§5.1) |
| `wasmUrl`·`fontUrl` | 패키지 동봉본 | 자산 위치를 직접 지정한다 |

`onData`가 이 라이브러리의 출력이다 — 소비자는 그 바이트를 자기 전송로로 호스트에 보내고, 호스트가 준 바이트를 `write`로 되돌린다.

**호스트 응답을 흘리지 않는다**: 터미널이 DA·CPR·OSC 색상 질의에 답할 바이트도 `onData`로 나간다. 이걸 전달하지 않으면 TUI가 응답을 기다리다 멈춘다([I/O–렌더 스레딩 분리](io-render-threading.md) §1의 결함과 같은 축).

### 내부 경계

```ts
interface Backend  { /* wasm 소유 */ write, resize, key, mouse, query, on }
interface Renderer { /* 픽셀 소유 */ attach, draw }
```

`Terminal`은 이 둘을 조합만 한다. 모드가 바뀌어도 `Terminal`의 코드는 바뀌지 않고 어떤 구현을 꽂는지만 달라진다.

## 4. 워커 계약

기본값은 `'full'`이다 — 코어와 렌더를 모두 워커에 둬서, 대량 출력이 쌓여도 메인 스레드가 막히지 않는 것이 기본 동작이다.

| 모드 | 메인 | 워커 |
|---|---|---|
| `'full'`(기본) | 이벤트 프록시 | wasm + OffscreenCanvas |
| `false` | wasm + Canvas | — |

**렌더만 워커에 두는 중간 모드는 두지 않는다.** 그 모드의 명분은 "조회를 동기로 유지"였는데 조회가 전부 `Promise`가 되면서 사라졌고, wasm 은 번들이 아니라 별도 파일이라(`new URL` 참조) 워커 번들도 줄지 않는다. 남는 것은 매 프레임 셀 버퍼 왕복과 이중 버퍼 관리, 테스트 경계 하나뿐이다.

- **SharedArrayBuffer를 쓰지 않는다.** COOP/COEP가 서드파티 인증·결제 플로우를 깨고 정적 임베드를 막는데, VT 파싱은 순차적이라 병렬 이득이 없다([wasm 이식성](wasm-portability.md) §4).
- **입력 이벤트는 항상 메인이 잡는다.** 워커는 DOM 이벤트를 못 받으므로 `postMessage`로 넘긴다.
- **능력 감지로 하향 폴백한다.** `worker`를 명시하지 않았을 때만 적용하며, `Worker`나 `OffscreenCanvas`가 없으면 `false`로 내려가고 `onFallback`으로 알린다. 명시했는데 지원이 없으면 `open()`이 reject한다 — 조용한 성능 저하보다 명시적 실패가 낫다.
- **SSR 안전**: 워커·wasm 생성은 전부 `open()` 안에서 한다. 모듈 로드 시점에 `Worker`·`document`를 건드리지 않아야 서버 렌더가 통과한다.

## 5. 렌더 계약

폭은 wasm이 정하고 모양은 폰트가 그린다. 이 분리가 핵심이다 — 폰트를 바꿔도 격자가 흔들리지 않는다.

- **격자는 실측한 폰트 폭으로 잡는다**(`measureText`). 하드코딩하면 폰트·크기마다 어긋난다.
- **배경은 연속 구간으로 병합해 정수 좌표에 그린다.** 셀마다 `fillRect`를 하면 소수 좌표 경계에 안티앨리어싱 틈이 생겨 세로 줄무늬로 보인다.
- **글자 폭은 논리 폭(`CW × cells`)을 쓴다.** 정수 스냅한 폭을 쓰면 반올림만큼 글리프가 압축된다.
- **ASCII·폭1·같은 스타일의 연속 셀은 run으로 묶어 한 번에 그린다.** 셀마다 `fillText`를 부르면 폰트에 리가처가 있어도 적용되지 않는다. 비-ASCII는 폴백 폰트가 그리므로 run을 끊고 셀 폭에 맞춰 보정한다.
- **선택은 반투명 오버레이**로 배경 위·글자 아래에 얹는다. 배경을 대체하면 256색 띠나 SGR 배경이 사라진다.
- **선택 span의 끝은 inclusive다**(실측). `sel_span`이 준 `endRow`/`endCol`이 가리키는 칸도 선택에 든다 — 렌더가 exclusive로 그리면 마지막 칸이 하이라이트에서 빠진다. 선택 **텍스트**는 셀에서 재구성하지 말고 코어의 `sel_text`를 쓴다(grapheme cluster와 soft-wrap 이음을 코어가 푼다).
- **줄 간격으로 늘어난 여백은 위아래로 나눈다**(CSS 의 half-leading). 전부 baseline 아래에 두면 글자가 셀 위쪽에 붙고 아래에 패딩이 있는 것처럼 보인다 — 선택 배경이 셀 전체를 칠하므로 그 치우침이 그대로 드러난다(14px·`lineHeight` 1.2 에서 위 1px·아래 6px → 위 3px·아래 4px. 기본값 1.22 에서도 셀 높이 22px 로 같다). 본체는 배수 대신 폰트가 정한 `line_gap` 을 쓰므로 이 문제가 없다.
- **커서는 반전**이다(block). 덮기만 하면 아래 글자가 사라지고, 폭을 1셀로 고정하면 2셀 문자에서 절반만 칠해진다. 커서가 움직이면 깜빡임 위상을 리셋한다.
- **IME marked text는 화면에 실제로 들어간다.** 덮어 그리기만 하면 커서 뒤 글자가 가려질 뿐 밀리지 않는다. 표시는 반투명 하이라이트 + 평소 글자색 + 밑줄이다.
  - **누가 넣는지는 `onPreedit` 구독 여부로 갈린다.** 구독자가 없으면 라이브러리가 `ICH`/`DCH`로 직접 넣는다(단순한 소비자를 위한 기본 동작). 구독하면 앱이 넣는다 — 줄을 다시 그리는 앱(readline 류)은 자기 줄에 조합을 끼워 그려야 하는데, 라이브러리가 화면을 따로 건드리면 그 재그리기와 어긋나기 때문이다. 한글은 확정 직후 다음 자모 조합이 이어지므로 이 어긋남이 매 글자마다 생긴다.
  - **하이라이트·밑줄 오버레이는 어느 쪽이든 라이브러리가 그린다.** 삽입만 갈린다.
- **프로시저럴 글리프는 폰트보다 먼저 시도한다.** 박스·블록·파워라인·브라유·모자이크는 셀을 꽉 채워야 선이 이어지는데, 폰트가 그리면 advance 가 셀 폭과 달라 가운데 정렬되고 양옆에 틈이 생긴다(표의 가로선이 끊겨 보인다). 코어가 셀 크기를 받아 커버리지를 계산하므로 폰트가 무엇이든 이음매가 맞고, **Nerd Font 가 없는 브라우저에서도 파워라인이 나온다**.
  - **어떤 코드포인트를 덮는지는 코어가 정한다** — `renderer.isSynthesizedCodepoint` / `renderer.synthesizeGlyph` 가 합성 dispatch 의 단일 출처다. 범위를 JS 나 wasm 브리지에 복제하면 계열이 늘 때마다 어긋난다(실제로 `box_glyph` 만 부르다가 블록·파워라인·브라유를 통째로 놓쳤다).

## 5.1 폰트

**기본 체인은 리가처 폰트를 앞에 둔다.** 맨 앞은 본체의 `font.family` 기본값(`JetBrains Mono`)이고, 그다음이 같은 폰트의 Nerd 패치본, 이어서 다른 리가처 폰트, 마지막이 리가처 없는 표준 고정폭이다. 리가처 구현 피처는 폰트마다 다르다 — JetBrains Mono 는 `liga` 가 아니라 `calt` 를 쓴다(GSUB 확인). Canvas 는 둘 다 적용하므로 렌더러가 따로 할 일은 없다.

**한글은 `Jetendard` 가 받는다** — 본체의 `font.fallback` 기본값이다. 한글 advance 를 라틴의 정확히 2배로 잡아 등폭 격자에 맞는다(실측: 셀 8.40px, 한글 16.80px = 2.00배). 이게 없으면 시스템 cascade 가 한글을 비례 폰트로 그려 셀마다 여백이 남는다([font-strategy.md](font-strategy.md) §번들 폰트).

**Jetendard 는 앱 번들 안의 자산이라 브라우저에서 시스템 폰트로 잡히지 않는다.** 체인에 이름만 두면 효과가 없으므로 패키지에 woff2 로 함께 싣는다(Regular 1.6 MB, OFL 1.1 · RFN "Jetendard" 전문 동봉). **기본은 받지 않는다** — `loadFont: "jetendard"` 로 켤 때만 내려받는다.

- **폰트는 격자를 재기 전에 등록돼야 한다.** 나중에 로드하면 셀 크기가 폴백 폰트 기준으로 굳는다.
- **워커에서도 따로 등록한다.** OffscreenCanvas 가 보는 폰트 집합은 워커의 것이라(`self.fonts`) 메인에서 등록한 face 가 거기 없다. 메인은 `document.fonts`, 워커는 `self.fonts` — `globalThis.fonts` 만 보면 메인에서 조용히 아무 일도 일어나지 않는다.

## 5.2 기본 키바인딩

코어의 키 인코딩은 `Cmd+Backspace`를 평범한 `Backspace`와 구분하지 않는다(둘 다 `\x7f`). macOS 줄 편집 관례를 셸 시퀀스로 옮기는 층이 따로 필요하고, 그 표는 **maru 본체와 같아야 한다** — `src/config/keybinding.zig`의 `default_terminal_bindings`가 단일 출처이고 Ghostty 기본 keybind 와도 동작이 같다.

| 조합 | 보내는 것 | 뜻 |
|---|---|---|
| `Cmd+Backspace` | `\x15` | 줄 시작까지 삭제(Ctrl+U) |
| `Cmd+←` / `Cmd+→` | `\x01` / `\x05` | 줄 시작 / 줄 끝 |
| `Option+←` / `Option+→` | `\x1bb` / `\x1bf` | 단어 왼쪽 / 오른쪽 |
| `Cmd+=` / `Cmd+-` / `Cmd+0` | — | 폰트 확대·축소·되돌리기(본체 `*_font_size`) |
| `Cmd+A` | — | 전체 선택 |

`Option+Backspace`(단어 삭제 `\x1b\x7f`)는 코어의 meta-ESC 인코딩이 이미 처리하므로 이 표에 없다. 바인딩은 **코어 인코딩보다 먼저** 본다. 조합 중에도 `Cmd` 조합은 IME 가 아니라 앱의 것이다 — 그대로 흘리면 `Cmd+Delete` 로 줄을 지워도 조합 텍스트가 화면에 남는다.

## 6. 빌드 파이프라인

번들러는 zntc(`@zntc/core`의 NAPI `build()`)를 쓴다. `web/scripts/zntc-bundle.ts`의 fail-closed 패턴(`write: false` → 진단 확인 → 파일명 검증)을 따른다.

**타입 선언은 zntc가 만들지 않는다.** 두 갈래로 나눈다:

```
JS  : zntc build()  — esm, external: peer deps, loader { ".wasm": "file" }
타입: tsc -p tsconfig.build.json  — declaration + emitDeclarationOnly
```

**wasm 로딩**은 기본이 `new URL('./maru-vt.wasm', import.meta.url)`이고(Vite·webpack5·SvelteKit 공통), `wasmUrl` 옵션으로 덮을 수 있다.

**wasm 바이너리는 저장소에 커밋한다.** npm에 실려 나가는 배포 산출물이고 받는 쪽에 Zig 툴체인이 없다. 소스와 바이너리가 어긋나지 않도록 빌드 재현 후 해시를 비교하는 게이트를 둔다.

## 6.1 검증

| 층 | 도구 | 무엇을 |
|---|---|---|
| 코어 | `bun test` | 키 인코딩·폭 판정·선택 span·IME 삽입·합성 글리프 범위 |
| 렌더·래퍼 | playwright | 실제 브라우저에서 픽셀과 마운트 |
| wasm | `zig build wasm-lib` + `check-wasm-sync` | 컴파일과 소스-바이너리 동기 |

**네 래퍼 모두 실제로 마운트되는지 본다.** 번들이 나오는 것만으로는 부족하고, 프레임워크 훅
(`useEffect`·`onMounted`·액션·`firstUpdated`)이 코어를 띄우고 `onReady` 가 오는지까지 확인한다.
React 픽스처만 번들이 필요한데(react·react-dom 은 브라우저에서 바로 부를 ESM 진입점이 없다)
테스트 전용이므로 zntc 대신 Bun 번들러를 쓴다.

브라우저 검사는 playwright 브라우저 바이너리를 요구한다(`bunx playwright install chromium`).
CI 의 `packages:check` 는 이 검사를 돌리지 않으므로 로컬에서만 필요하다.

## 7. 현재 범위 — 무엇이 있고 무엇이 없나

**파싱·화면·입력의 정확도는 본체와 같다.** wasm 은 `TerminalCore` 를 그대로 쓰므로 libvterm·
Alacritty 대조 오라클(`external oracles` CI)이 검증한 그 파서다. EAW·grapheme cluster 폭 판정과
키 인코딩도 같은 코드다. 합성 글리프는 xterm.js 에 없는 것으로, Nerd Font 없이도 파워라인·박스가
셀 경계에서 끊기지 않는다.

**그 위의 편의 기능은 아직 없다.** 코어에 구현이 있어도 wasm export 로 내지 않은 것들이다:

| 기능 | 코어의 구현 | 비고 |
|---|---|---|
| 검색 | `findMatches`·`matchViewportSpan` | xterm.js 의 SearchAddon 에 해당 |
| 클립보드(OSC 52) | `clipboardReadPending`·`pendingClipboardWrite` | 이벤트 채널 설계가 필요하다 |
| 화면 직렬화 | `dumpUtf`·`dumpRecentTextUtf` | SerializeAddon 에 해당 |
| 리셋 | `clearScreen`·`fullReset`·`resetInputModes` | `reset` 이 먹지 않는다 |
| 셸 통합(OSC 7·133) | `currentCwd`·`shellEvents`·`cursorIsAtPrompt` | 프롬프트 인식·cwd 추적 |
| 알림(OSC 9·777) | `pendingNotification` | |
| 이미지 | `buildImageViews`·`buildPlacementViews` | 렌더러가 픽셀을 다뤄야 한다 |

링크 **자동 감지**는 libc 를 요구하므로 넣지 않는다(§8, [wasm 이식성](wasm-portability.md) §2). OSC 8
명시 링크만 지원한다.

**API 표면도 좁다.** xterm.js 의 `Terminal` 과 대조하면 기능 애드온 말고도 이만큼이 없다:

| 없는 것 | 쓰임 |
|---|---|
| `reset`·`clear` | `reset` 명령, 화면 비우기 |
| `scrollToTop`·`scrollToLine`·`scrollPages` | 스크롤 제어(맨 아래로만 있다) |
| `onCursorMove`·`onScroll`·`onSelectionChange` | 앱이 상태를 따라가야 할 때(복사 버튼·미니맵 등) |
| `onKey`·`onBinary`·`onLineFeed`·`onWriteParsed` | 입력·출력 훅 |
| `attachCustomKeyEventHandler` | 앱 단축키가 터미널보다 먼저 키를 잡아야 할 때 |
| `registerMarker`·`registerDecoration` | 검색 하이라이트·주석 같은 확장의 기반 |
| `hasSelection`·`getSelectionPosition`·`select`·`selectLines` | 선택 조회·프로그래밍 선택 |
| `registerLinkProvider` | 커스텀 링크 규칙 |
| `input`·`writeln`·`refresh` | 편의 |

`blur` 는 `focus(false)` 로 덮는다. `registerCharacterJoiner`(리가처 커스텀)와 `loadAddon` 은
설계가 달라 그대로 옮길 것이 아니다 — 리가처는 코어가 판정하고, 애드온 개념을 둘지는 미정이다.

**성능과 메모리**(실측, [wasm 이식성](wasm-portability.md) §5): 처리량은 45 B 청크에서 7 MB/s, 4 KB 청크에서
10 MB/s 다 — 호출당 오버헤드가 지배적이라 덩어리가 클수록 유리하다. 메모리는 인스턴스당 초기 4 MB(정적 버퍼
2.3 MB 포함), 기본 스크롤백(1,000)에서 고수위 12 MB 대다. `scrollback` 을 10만으로 올리면 64 MB 상한에 닿으니
터미널을 여럿 여는 앱은 그 값을 낮추는 것이 가장 큰 지렛대다.

**검증되지 않은 것** — 지금까지의 확인은 계약 테스트와 데모(가짜 셸)까지다:

- **실제 TUI 로 돌려본 적이 없다.** vim·tmux·htop 은 대체 화면·스크롤 영역·mouse tracking 을 섞어
  쓰는데 그 조합을 밟아 본 적이 없다. **기능을 더 넣기 전에 이것부터 해야 한다** — PTY 를
  WebSocket 으로 물려 실제 앱을 띄우면 지금 안 보이는 문제 대부분이 한 번에 드러난다.
- **브라우저는 headless Chromium 만** 봤다. Safari(특히 iOS)·Firefox 미검증.
- **접근성 없음.** xterm.js 는 스크린 리더용 버퍼를 따로 둔다.
- **모바일·터치** 에서 선택·스크롤이 어떻게 되는지 모른다.
- **실사용 0.** 대량 출력은 벤치만 했고 실전 로그를 흘려본 적 없다.

## 8. 이 문서가 정하지 않는 것

- **바이트 전송로.** WebSocket·SSH-over-WS·trace 재생 중 무엇을 쓸지는 소비자가 정한다.
- **링크 자동 감지.** `openableLinkAt`는 libc를 요구하므로 wasm에 넣지 않는다. OSC 8 명시 링크만 지원한다([wasm 이식성](wasm-portability.md) §2·§6).
- **`.svelte` 컴포넌트.** 액션으로 제공한다(§2). 컴포넌트를 원하면 `svelte/compiler`를 별도 빌드 스텝으로 넣어야 하는데, 그건 zntc 단일 번들러 결정을 바꾸는 일이라 별도 논의가 필요하다.
- **브라우저 이벤트 → `KeyEvent` 매핑의 완전성.** `base_codepoint`·`keypad`는 플랫폼이 채우는 값이고(`terminal/input.zig`), 레이아웃·IME 조합에서 브라우저마다 갈린다. 라이브러리는 합리적 기본 매핑과 §5.1의 기본 바인딩을 제공하되, 그 밖의 완전성은 약속하지 않는다. 사용자 정의 바인딩 설정은 아직 없다 — 앱이 `keydown`을 먼저 잡아 `sendText()`로 보내면 된다.
