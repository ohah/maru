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

## 4.1 워커 모드에서 무엇이 오고 무엇이 안 오나

| API | `worker: false` | `worker: "full"`(기본) |
|---|---|---|
| `onRender` | 온다 | **온다**(`FrameMeta` — 셀 없음) |
| `Terminal.frame` | 셀 포함 | **항상 `null`** |
| `snapshot()` | 셀 포함 | 셀 포함 |

**셀을 매 프레임 보내지 않는다.** 120×40 만 해도 93 KB/프레임이고 1440p 최대화면 498 KB, 4K 면 1.1 MB 다 — 60 fps 로 환산하면 각각 5.5 / 29 / 66 MB/s 라, 렌더를 워커로 옮긴 이유가 그대로 사라진다. 실시간 비디오 처리 워커도 같은 형태다: 픽셀은 워커에 두고 **탐지 결과 같은 작은 메타만** 매 프레임 올린다.

그래서 `onRender` 는 `FrameMeta`(size·cursor·selection·scroll)를 준다. 화면 내용이 필요하면 `snapshot()` 으로 그때 가져간다 — 다만 `snapshot()` 에는 `selection`·`scroll`·`modes` 가 없고 셀마다 객체를 만들므로(25,536 셀이면 객체 25,536 개) 완전한 대체는 아니다.

**`Terminal.frame` 은 워커 모드에서 살릴 수 없다.** 동기로 워커 메모리를 읽으려면 SharedArrayBuffer 가 필요한데, 그건 소비자 페이지 **전체**에 COOP/COEP 를 강제해 OAuth·결제 위젯·CDN 리소스·정적 임베드를 깨뜨린다(§4, [wasm 이식성](wasm-portability.md) §4). 코어를 wasm 으로 두는 가치의 큰 몫이 "어디에나 올릴 수 있다" 인데 SAB 는 정확히 그것을 판다. 게다가 shared memory 로 다시 빌드하면 u64 atomic 제약이 되살아난다.

## 5. 렌더 계약

폭은 wasm이 정하고 모양은 폰트가 그린다. 이 분리가 핵심이다 — 폰트를 바꿔도 격자가 흔들리지 않는다.

- **격자는 실측한 폰트 폭으로 잡는다**(`measureText`). 하드코딩하면 폰트·크기마다 어긋난다.
- **배경은 연속 구간으로 병합해 정수 좌표에 그린다.** 셀마다 `fillRect`를 하면 소수 좌표 경계에 안티앨리어싱 틈이 생겨 세로 줄무늬로 보인다.
- **글자 폭은 논리 폭(`CW × cells`)을 쓴다.** 정수 스냅한 폭을 쓰면 반올림만큼 글리프가 압축된다.
- **ASCII·폭1·같은 스타일의 연속 셀은 run으로 묶어 한 번에 그린다.** 리가처를 살리려는 규칙이지만 **성능이 더 큰 이득**이다 — 1440p 최대화(304×84)에서 셀마다 색이 달라 run 이 전부 쪼개지면 28.2 ms/frame 인데 한 색이면 2.5 ms/frame 으로 **11배** 빠르다([실측](plans/maru-term-library.md) — `bun run --cwd packages bench:render`). Canvas 2D 도 GPU 로 래스터화되므로(Skia·Metal) "WebGL 이어야 GPU" 는 오해이고, 실제 차이는 글리프 조회·래스터화 횟수다. **WebGL 은 넣지 않기로 판정했다** — run 병합이 깨지는 화면을 실제로 재보니 현실적 패턴(btop 형 팔레트 반복)은 6.2 ms 로 예산 안이고, 예산을 넘는 것은 "화면 전체가 셀마다 다른 색 + 1440p 최대화 + 매 프레임 갱신"이 동시에 성립할 때뿐이다(28.2 ms). 그 한 경우를 위해 셰이더·아틀라스·폴백을 새로 짓는 것은 이득이 비용보다 작다. 셀마다 `fillText`를 부르면 폰트에 리가처가 있어도 적용되지 않는다. 비-ASCII는 폴백 폰트가 그리므로 run을 끊고 셀 폭에 맞춰 보정한다.
- **선택은 반투명 오버레이**로 배경 위·글자 아래에 얹는다. 배경을 대체하면 256색 띠나 SGR 배경이 사라진다.
- **선택 span의 끝은 inclusive다**(실측). `sel_span`이 준 `endRow`/`endCol`이 가리키는 칸도 선택에 든다 — 렌더가 exclusive로 그리면 마지막 칸이 하이라이트에서 빠진다. 선택 **텍스트**는 셀에서 재구성하지 말고 코어의 `sel_text`를 쓴다(grapheme cluster와 soft-wrap 이음을 코어가 푼다).
- **줄 간격으로 늘어난 여백은 위아래로 나눈다**(CSS 의 half-leading). 전부 baseline 아래에 두면 글자가 셀 위쪽에 붙고 아래에 패딩이 있는 것처럼 보인다 — 선택 배경이 셀 전체를 칠하므로 그 치우침이 그대로 드러난다(14px·`lineHeight` 1.2 에서 위 1px·아래 6px → 위 3px·아래 4px. 기본값 1.22 에서도 셀 높이 22px 로 같다). 본체는 배수 대신 폰트가 정한 `line_gap` 을 쓰므로 이 문제가 없다.
- **커서는 반전**이다(block). 덮기만 하면 아래 글자가 사라지고, 폭을 1셀로 고정하면 2셀 문자에서 절반만 칠해진다. 커서가 움직이면 깜빡임 위상을 리셋한다.
- **IME 조합은 화면 버퍼를 건드리지 않는다.** 렌더러가 커서 자리에 그리고 **뒤 셀을 조합 폭만큼 밀어 그려** 밀리는 것처럼 보이게 한다. 표시는 반투명 하이라이트 + 평소 글자색 + 밑줄이다.
  - **코어에 넣으면 화면을 소유한 앱과 어긋난다.** zsh 는 프롬프트와 입력줄을 자기가 관리하므로, `ICH`/`DCH` 로 끼어들면 그 다음 앱이 그릴 때 엉뚱한 자리를 밟는다 — 실제 PTY 에서 `echo ` 뒤에 조합을 시작하자 **앞의 "ec" 가 지워졌다**(F1 탐색에서 발견). xterm.js 가 오버레이를 쓰는 이유도 같다.
  - 줄을 스스로 다시 그리는 앱(readline 류)은 `onPreedit` 를 구독해 자기 줄에 조합을 끼워 넣을 수 있다.
- **프로시저럴 글리프는 폰트보다 먼저 시도한다.** 박스·블록·파워라인·브라유·모자이크는 셀을 꽉 채워야 선이 이어지는데, 폰트가 그리면 advance 가 셀 폭과 달라 가운데 정렬되고 양옆에 틈이 생긴다(표의 가로선이 끊겨 보인다). 코어가 셀 크기를 받아 커버리지를 계산하므로 폰트가 무엇이든 이음매가 맞고, **Nerd Font 가 없는 브라우저에서도 파워라인이 나온다**.
  - **어떤 코드포인트를 덮는지는 코어가 정한다** — `renderer.isSynthesizedCodepoint` / `renderer.synthesizeGlyph` 가 합성 dispatch 의 단일 출처다. 범위를 JS 나 wasm 브리지에 복제하면 계열이 늘 때마다 어긋난다(실제로 `box_glyph` 만 부르다가 블록·파워라인·브라유를 통째로 놓쳤다).

**워커 모드에서는 캔버스를 넘기기 전에 backing store 를 잡는다.** `transferControlToOffscreen()`
뒤에는 메인이 `width`/`height` 를 못 쓰므로, 넘기기 전이 유일한 기회다. 안 잡으면 기본값
300×150 인 채로 넘어가고 워커가 resize 메시지를 받아 다시 잡을 때까지 CSS 크기로 늘어나
흐릿하다 — 실측으로 `open()` 이 resolve 된 뒤 4프레임(22 ms) 동안 그랬다.

**테마 객체는 제자리에서 고치지 않는다.** 렌더러는 **참조가 달라졌을 때만** 팔레트를 다시
만든다 — 같은 객체를 계속 넘기는 것이 흔한데(테마 목록에서 고른 것) 매 프레임 팔레트를 문자열로
이어 비교하면 256 색 테마에서 256 개를 잇는 셈이다. 색을 바꾸려면 **새 객체**를 넘긴다
(`{ ...theme, palette: [...] }`) — React props 와 같은 규약이다.

## 5.1 폰트

**기본 체인은 리가처 폰트를 앞에 둔다.** 맨 앞은 본체의 `font.family` 기본값(`JetBrains Mono`)이고, 그다음이 같은 폰트의 Nerd 패치본, 이어서 다른 리가처 폰트, 마지막이 리가처 없는 표준 고정폭이다. 리가처 구현 피처는 폰트마다 다르다 — JetBrains Mono 는 `liga` 가 아니라 `calt` 를 쓴다(GSUB 확인). Canvas 는 둘 다 적용하므로 렌더러가 따로 할 일은 없다.

**한글은 `Jetendard` 가 받는다** — 본체의 `font.fallback` 기본값이다. 한글 advance 를 라틴의 정확히 2배로 잡아 등폭 격자에 맞는다(실측: 셀 8.40px, 한글 16.80px = 2.00배). 이게 없으면 시스템 cascade 가 한글을 비례 폰트로 그려 셀마다 여백이 남는다([font-strategy.md](font-strategy.md) §번들 폰트).

**Jetendard 는 앱 번들 안의 자산이라 브라우저에서 시스템 폰트로 잡히지 않는다.** 체인에 이름만 두면 효과가 없으므로 패키지에 woff2 로 함께 싣는다(Regular 1.6 MB, OFL 1.1 · RFN "Jetendard" 전문 동봉). **기본은 받지 않는다** — `loadFont: "jetendard"` 로 켤 때만 내려받는다.

- **폰트는 격자를 재기 전에 등록돼야 한다.** 나중에 로드하면 셀 크기가 폴백 폰트 기준으로 굳는다.
- **워커에서도 따로 등록한다.** OffscreenCanvas 가 보는 폰트 집합은 워커의 것이라(`self.fonts`) 메인에서 등록한 face 가 거기 없다. 메인은 `document.fonts`, 워커는 `self.fonts` — `globalThis.fonts` 만 보면 메인에서 조용히 아무 일도 일어나지 않는다.

**조합 중에 온 `Cmd` 조합은 조합을 확정시키고 거기서 끝난다** — 키 자체는 보내지 않는다.
보내면 순서가 뒤집힌다: 확정 글자는 `key()` 로 **코어(워커일 수 있다)를 거쳐** 나오는데
바인딩은 `sendText` 로 **메인에서 곧바로** 나가므로, 커서가 먼저 움직이고 글자가 그 뒤에
들어간다(실측: "무" 확정 + "야" 조합 중 `Cmd+←` → `야무`). 한 tick 미뤄도 워커 왕복이 더 느려
소용이 없다. macOS 네이티브 앱들도 조합 중 명령키를 확정에 쓴다 — 사용자는 한 번 더 누르면 된다.

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

**실제 TUI 는 탐색 도구이지 회귀 테스트가 아니다.** `bun run demo` 가 띄우는 서버는 `/pty` 로
진짜 셸을 중계한다(`Bun.Terminal` — Bun 1.3.5+ 내장이라 node-pty 같은 네이티브 의존성이 없다).
데모의 "바이트 출처" 를 `진짜 PTY` 로 바꾸면 vim·htop·tmux 를 그대로 띄울 수 있다.

그 검증을 CI 에 넣지 않는다 — 셸(zsh/bash)·앱 버전·프로세스 목록이 환경마다 달라 화면이
재현되지 않고, htop 은 애초에 실시간 데이터라 비결정적이다. **깨졌을 때 우리 코드 문제인지
환경 문제인지 구분되지 않는 테스트는 없는 것만 못하다.**

대신 역할을 나눈다: 앱으로 **발견**하고, 발견한 것을 **결정적 시퀀스**로 옮겨 회귀를 지킨다.
예를 들어 htop 이 마우스를 켜는 것을 확인했으면 회귀 테스트는 `\x1b[?1000h` 로 쓴다 — 앱이
필요 없고 결정적이다. 대체 화면(`1049`)·스크롤 영역(DECSTBM)·커서 모양(DECSCUSR)도 같다.

**PTY 브리지는 로컬 개발 전용이다.** 127.0.0.1 에만 바인딩하고 붙는 쪽에 셸을 그대로 내주므로
외부에 노출하지 않는다.

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
| 이미지 | `buildImageViews`·`buildPlacementViews` | 렌더러가 픽셀을 다뤄야 한다 |

링크 **자동 감지**는 libc 를 요구하므로 코어에서 넣지 않는다(§8, [wasm 이식성](wasm-portability.md) §2).
OSC 8 명시 링크를 지원하고, 그 밖의 규칙은 `registerLinkProvider` 로 소비자가 넣는다 — URL 감지도
정규식 한 줄이면 된다(아래).

### 화면·스크롤 제어

| 메서드 | 동작 |
|---|---|
| `reset()` | 하드 리셋. `ESC c` 를 흘려 파서의 RIS 경로를 탄다 — 앱이 보낸 RIS 와 완전히 같다 |
| `clear()` | 화면을 지운다. 아래 계약을 따른다 |
| `scrollToTop()` / `scrollToBottom()` | 스크롤백 양 끝 |
| `scrollToLine(line)` | 절대 행(0 = 스크롤백 최상단)을 뷰포트 첫 줄에 |
| `scrollLines(n)` / `scrollPages(n)` | 상대 이동. **양수가 아래** — 휠 방향이다(`scroll()` 은 위가 양수인 코어 방향이라 반대다) |

### OSC 사건 — 정책은 소비자가 정한다

| 이벤트 | OSC | 라이브러리가 하는 일 |
|---|---|---|
| `onClipboardWrite` | 52 | **알리기만 한다.** 클립보드에 쓰지 않는다 |
| `onClipboardRejected` | 52 | 상한(16 MB) 초과로 거부됐다고 알린다 |
| `onClipboardRead` | 52 `?` | 알리기만 한다. **답하지 않는 것이 기본** |
| `onNotification` | 9·777 | 알리기만 한다. 띄우지 않는다 |
| `onCwdChange` | 7 | 셸의 현재 디렉터리 |
| `onShellEvent` | 133 | 프롬프트/입력/명령 시작·끝(종료 코드 포함) |
| `cursorAtPrompt()` | 133 | 명령이 도는 중인지. 통합이 없으면 보수적으로 `false` |

**코어가 OS 를 직접 만지지 않는 경계를 그대로 잇는다.** 본체에서는 platform 이 정책을 확인한 뒤
시스템 클립보드에 쓰는데, 브라우저에서는 그 판단이 더 중요하다 — 터미널에서 도는 아무
프로그램이나 사용자 클립보드를 덮어쓰거나 **읽어 갈** 수 있으면 안 된다. 그래서 라이브러리는
알리기만 하고, 쓸지·답할지는 소비자가 정한다.

읽기에 굳이 답한다면 소비자가 만들어 보낸다:

```ts
term.onClipboardRead((target) => {
  if (!trusted) return;                       // 기본은 답하지 않는 것
  const b64 = btoa(String.fromCharCode(...new TextEncoder().encode(text)));
  term.sendText(`\x1b]52;${target};${b64}\x07`);
});
```

- **클립보드는 최대 16 MB 라 복사하지 않는다.** wasm 선형 메모리를 그대로 읽어 문자열을 만든다.
- **wasm `i32` 는 JS 에서 부호 있는 수로 온다.** "없음" 표식으로 `0xffff_ffff` 를 쓰면 `-1` 로
  도착하므로 `>>> 0` 로 받아야 한다 — 안 그러면 알림이 없는데도 매 write 마다 빈 알림이 샌다
  (실제로 그랬다).
- **"없음"을 값으로 표현하지 않는다.** `command-end` 의 종료 코드는 유무를 **별도 칸**으로
  받는다. `0xffff_ffff` 를 "없음"으로 쓰면 그건 `@bitCast(@as(i32, -1))` 과 같은 비트라
  **종료 코드 -1 이 "없음"으로 보고된다**(실측). 값 공간과 표식 공간이 겹치면 언젠가 부딪힌다.

### 접근성

**캔버스는 보조기술이 읽을 수 없다** — 픽셀뿐이라 스크린 리더에게는 빈 요소와 같다. 그래서
캔버스를 접근성 트리에서 빼고(`aria-hidden`), **이미 포커스를 받는 textarea 를 앵커로 삼는다**
(`role="textbox"`·`aria-multiline`·`aria-label`). 사용자가 Tab 으로 도달하는 곳도, 키가 들어가는
곳도 거기다.

```ts
new Terminal({ screenReaderMode: true, ariaLabel: "빌드 로그" });
```

`screenReaderMode` 를 켜면 **바뀐 줄**이 라이브 리전(`aria-live="polite"`)에 들어간다.

- **기본은 꺼짐이다.** 프레임마다 화면을 텍스트로 뽑아 비교해야 하고(워커 모드에서는 왕복),
  쓰지 않는 사용자에게 그 비용을 물릴 이유가 없다. 앱이 사용자 설정으로 켠다.
- **화면 전체가 아니라 바뀐 줄만 읽힌다.** 전부 읽으면 출력 하나마다 24 줄을 듣게 된다.
- 라이브 리전은 최근 40 줄만 유지한다 — 무한히 자라면 DOM 이 부풀고 일부 리더가 전체를 다시 읽는다.

### 터치

**브라우저의 마우스 에뮬레이션에 기대지 않는다.** `touchend` 뒤 합성 `mousedown` 은 늦고
좌표가 어긋나며, 무엇보다 **드래그를 선택으로 오해한다** — 손가락으로 화면을 밀면 스크롤을
기대하지 텍스트가 잡히길 기대하지 않는다.

| 손짓 | 뜻 |
|---|---|
| 탭 | 입력 포커스(소프트 키보드). **커서는 옮기지 않는다** — 셸이 커서를 소유한다 |
| 세로 드래그 | 스크롤. 위로 밀면 과거로 간다 |
| 길게 누르기(500ms) | 그 자리의 단어 선택. 이어서 끌면 범위가 늘어난다 |
| 두 손가락 | 다루지 않는다 — 브라우저의 확대/스크롤에 맡긴다 |

- **10px 슬롭**을 둔다. 손가락은 완벽히 멈추지 않으므로 그 안의 움직임은 탭으로 본다.
- 앱이 마우스 추적(DECSET 1000 계열)을 켜면 터치를 가로채지 않는다 — 그때는 앱의 규약이다.

### 링크 규칙

```ts
term.registerLinkProvider({
  provideLinks(row, text) {                    // row 는 뷰포트 행, text 는 그 줄 전체
    const m = /https?:\/\/\S+/.exec(text);
    if (!m) return null;
    return [{
      startCol: m.index,
      endCol: m.index + m[0].length - 1,       // 포함
      text: m[0],
      activate: (ev) => open(m[0], "_blank"),
      hover: (ev) => {},                       // 선택 — 툴팁 등
      leave: () => {},
    }];
  },
});
```

**줄 텍스트를 함께 준다.** xterm.js 는 행 번호만 주고 provider 가 `buffer` API 로 꺼내지만,
여기서는 코어가 워커에 있을 수 있어 그 API 를 동기로 열 수 없다. 라이브러리가 한 번 뽑아
넘기므로 provider 는 정규식만 돌리면 된다.

- **OSC 8 이 먼저다.** 앱이 직접 선언한 링크를 규칙이 덮으면 안 된다 — OSC 8 이 잡히면
  provider 를 부르지도 않는다. provider 가 여럿이면 먼저 등록한 쪽이 이긴다.
- **줄 텍스트는 프레임이 바뀔 때만 다시 뽑는다.** hover 는 포인터가 움직일 때마다 오므로
  (초당 수십 번) 매번 직렬화하면 비싸다. 같은 셀에 대한 되풀이 조회도 캐시한다.
- **활성화는 소비자 몫이다.** OSC 8 은 URI 뿐이라 라이브러리가 새 탭으로 열지만, provider
  링크는 `activate` 가 무엇을 할지 정한다(에디터 열기·이슈 이동 등).
- **자동 URL 감지를 이걸로 한다.** 코어의 감지는 libc 를 요구해 wasm 에 없다 — 규칙을 넣으면
  같은 결과가 되고, 무엇을 링크로 볼지는 앱이 정하는 편이 낫다.

### 마커와 장식

```ts
const marker = term.registerMarker(absRow);   // 생략하면 커서 줄
term.registerDecoration({ marker, x, width, backgroundColor: 0xffd700, opacity: 0.35 });
```

**마커는 버려진 줄만큼 따라 내려온다.** 절대 행은 스크롤백이 가득 차 오래된 줄이 버려질 때
앞으로 밀린다 — 같은 줄이 10행이었다가 7행이 된다(실측). 코어는 selection·kitty placement 를
스스로 보정하지만 라이브러리가 든 좌표는 그럴 수 없어, 프레임이 싣는 `evicted`(버려진 행의
누적 수)로 보정한다. **가리키던 줄이 버려지면 마커는 스스로 dispose 되고**(그때 `row` 는 -1),
그 마커에 달린 장식도 함께 사라진다.

**DOM element 를 주지 않는다** — xterm.js 는 장식마다 `<div>` 를 얹어 소비자가 스타일링하게
하지만 여기서는 두 가지가 막는다: (1) 렌더가 워커에 있을 수 있어 DOM 을 만질 수 없고,
(2) 검색 하이라이트처럼 **수천 개**가 되는 용도가 주력이라 노드마다 DOM 을 만들면 감당이 안 된다.
대신 색을 받아 **렌더러가 칠한다**. 커스텀 UI 가 필요하면 `onRender` 로 자기 오버레이를 그린다.

**장식은 바뀌었을 때만 렌더 소유자에게 간다.** 매 프레임 보내면 받는 쪽이 그때마다 다시
그리고, 그 프레임이 또 장식을 실어 와 **끝나지 않는 루프**가 된다 — 장식이 하나도 없어도
빈 배열이 오갔다(실측: 아무 입력 없이 초당 1638 프레임, postMessage 4882 건에 2.8 초).
보내는 쪽과 받는 쪽 **양쪽에서** 같은 내용을 거른다 — 한 겹이 뚫려도 루프가 되지 않는다.

장식 배경은 **셀 배경 위·선택 아래**에 깔린다 — 선택이 장식을 덮어야 사용자가 지금 무엇을
잡았는지 헷갈리지 않는다. 전경색을 주면 그 셀만 글자 색이 바뀌고, run 은 색이 키라 자연히 끊긴다.

### 검색

| 메서드 | 반환 |
|---|---|
| `findMatches(needle)` | `{ matches, total }` — 좌표는 **절대 행**(0 = 스크롤백 최상단) |
| `findNext(needle)` / `findPrevious(needle)` | `boolean` — 매치를 화면에 올리고 선택한다 |

- **스크롤백까지 전부 훑는다.** 대소문자를 구분하고 정규식은 지원하지 않는다(코어가 코드포인트
  단위로 비교하므로 grapheme cluster 와 soft-wrap 이음이 자동으로 풀린다).
- **`total` 이 `matches.length` 보다 클 수 있다.** 버퍼가 4096 건까지라서다 — 그 이상은 사람이
  훑을 양이 아니지만 총량은 알아야 "1/5000" 을 보여줄 수 있다.
  - **그때 `findNext` 는 앞 4096 건 안에서만 순회한다.** 4097 번째 매치에는 갈 수 없다(실측:
    매치 5000 건에서 순회가 0·1·2 행으로 돈다). 코어 API 가 전체 검색만 지원하므로 "현재 위치
    이후만 찾기" 를 할 수 없다 — 필요해지면 코어에 범위 검색을 넣어야 한다.
- **`findNext` 는 부를 때마다 전체를 다시 훑는다.** 결과를 캐시하지 않는다 — 화면이 바뀌면
  매치도 바뀌므로 캐시하려면 무효화 규칙이 필요하다. 실측으로 5만 행 스크롤백에서 9.5 ms 라
  한 프레임 예산(16.7 ms) 안이지만, 그보다 큰 스크롤백에서 연타하면 체감될 수 있다.
- **하이라이트는 선택으로 그린다.** `findNext` 가 매치를 선택하므로 기존 선택 렌더가 그대로
  쓰인다 — 마커·장식이 없어도 동작한다. 여러 매치를 동시에 칠하려면 그때 장식이 필요하다.
- 좌표계 주의: 매치는 **절대 행**이고 선택 API 는 **뷰포트 행**이다. `findNext` 가 안에서
  변환한다(직접 `selectStart` 로 넘기면 스크롤백 깊은 매치가 엉뚱한 줄을 잡는다).

### 선택 조회·프로그래밍 선택

| 메서드 | 비고 |
|---|---|
| `hasSelection()` | **동기다.** 복사 버튼의 `disabled` 를 이벤트 핸들러 안에서 바로 정해야 한다 |
| `getSelectionPosition()` | 뷰포트 좌표. 없으면 `null` |
| `select(row, col, length)` | 한 행 안에서 |
| `selectLines(start, end)` | 행 통째로 |

**동기 조회 둘은 마지막 프레임의 값**이다(`#prevMeta`). 워커 모드에서도 왕복 없이 답하는 대신
**한 프레임 뒤처질 수 있다** — 선택 직후 같은 tick 에 물으면 이전 상태가 나온다. 정확한 값이
필요하면 `onSelectionChange` 를 구독한다. `dispose()` 뒤에는 `false`/`null` 이다.

**`select`·`selectLines` 는 좌표를 격자 안으로 clamp 하고, 겹치는 구간이 없으면 무동작이다.**
음수를 그대로 흘리면 wasm 에서 u32 로 캐스팅돼 거대한 수가 되고 코어의 clamp 를 거쳐 **엉뚱한
칸이 잡힌다**(`select(0, -3, 2)` 가 마지막 열을 선택했다).

### 키 가로채기

```ts
term.attachCustomKeyEventHandler((ev) => !(ev.metaKey && ev.key === "k")); // ⌘K 는 앱이
term.attachCustomKeyEventHandler(null);                                    // 해제
```

`false` 를 돌려주면 터미널이 그 키를 **완전히 무시한다** — 기본 바인딩(§5.1)도, 코어 인코딩도
타지 않는다. **IME 조합 정리 뒤에 불린다**: 조합 중 `Cmd` 조합이 오면 라이브러리가 먼저 조합을
취소하고(그러지 않으면 조합 글자가 화면에 남는다) 그다음 핸들러를 부른다. 조합 자체를
가로채려면 `ev.isComposing` 을 본다. 키는 언제나 메인 스레드가 잡으므로 두 워커 모드에서 같다.

### 화면 직렬화

`serialize()` 는 화면을 평문으로 뜬다. **스타일·색은 버린다** — 코어 `dumpUtf8` 이 "렌더러가
아니다"라는 계약이라 xterm.js SerializeAddon 처럼 SGR 을 복원하지 않는다. 테스트 단언이나 버그
리포트 첨부용이다.

### 상태 이벤트

> **`onRender` 안에서 `write()` 를 부르지 않는다.** 그 write 가 다음 프레임을 만들고 그 프레임이
> 다시 콜백을 부른다 — 자기 유발 루프다. 프레임이 마이크로태스크로 접혀 브라우저가 멈추지는
> 않지만 끝나지 않는다.


| 이벤트 | 인자 | 언제 |
|---|---|---|
| `onCursorMove` | `CursorState` | 커서가 **다른 칸으로** 옮겨갔을 때 |
| `onScroll` | `{ offset, length }` | 뷰포트 위치나 스크롤백 길이가 바뀔 때 |
| `onSelectionChange` | `SelectionSpan \| null` | 선택이 바뀌거나 해제될 때(해제는 `null`) |

셋 다 **프레임에서 파생한다** — 코어에 별도 알림 채널을 두지 않는다. 이미 매 프레임 커서·
선택·스크롤이 실려 오므로(`FrameMeta`), 직전 프레임과 달라진 것만 발행하면 된다. 파생을
`Terminal` 한 곳에 두어 두 워커 모드가 같은 이벤트를 받는다.

- **모양·깜빡임 변화는 `onCursorMove` 가 아니다.** 깜빡임은 매 프레임 토글되므로 위치 변화와
  섞이면 쓸 수 없다. 위치만 본다.
- **첫 프레임은 기준선일 뿐 발행하지 않는다.** 초기 상태를 "변화"로 내면 구독자가 마운트
  직후 무의미한 알림을 받는다.

`clear()` 는 xterm.js 와 시맨틱이 다르다 — **본체 ⌘K 와 같은 계약**이다:

- **셸 통합(OSC 133)이 있고 프롬프트 상태**: 화면 전체 + 스크롤백을 비우고 커서를 홈에 둔 뒤
  `\x0c`(^L)를 `onData` 로 흘린다. 호스트가 그걸 PTY 에 써야 셸이 프롬프트를 맨 위에 다시 그린다.
- **그 밖(비통합·명령 실행 중)**: 스크롤백과 커서 위 행만 비우고 커서를 옮기지 않는다. 셸의
  readline 모델과 어긋나지 않기 위해서다. ^L 도 보내지 않는다.
- **alt screen**: 무동작. 화면은 앱의 것이다(`:clear` 는 앱에 맡긴다).

**API 표면도 좁다.** xterm.js 의 `Terminal` 과 대조하면 기능 애드온 말고도 이만큼이 없다:

**xterm.js 의 `Terminal` 공개 타입과 대조해 뽑았던 격차는 이제 없다.** 남은 것은 아래 "넣지
않기로 한 것" 뿐이다.

**넣지 않기로 한 것**도 있다 — xterm.js 에 있지만 여기서는 성립하지 않거나 이미 다른 것이 덮는다.

| xterm.js | 왜 넣지 않나 |
|---|---|
| `onLineFeed` | **코어에 그 훅이 없다.** 프레임에서 파생하면 한 프레임에 접힌 여러 LF 를 구별할 수 없어 부정확해진다 — 없는 것보다 나쁘다 |
| `onWriteParsed` | `write()` 가 동기라 **호출 직후가 곧 그 시점**이다 |
| `onBinary` | `onData` 가 이미 `Uint8Array` 다 |
| `input(data)` | `sendText()` 가 같은 일을 한다 |
| `refresh(start, end)` | 렌더가 dirty 기반이라 행 범위를 받을 자리가 없다. 강제 재렌더가 필요한 경우(폰트 로드 등)는 내부에서 처리한다 |

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
- **애드온으로 나누지 않는다.** xterm.js 는 `SearchAddon` 처럼 기능을 떼어 용량을 아끼는데,
  그 전제는 **JS 라서 번들러가 청크로 뗄 수 있다**는 것이다. wasm 은 다르다 — 검색은
  스크롤백을, 이미지는 화면 셀을 직접 훑어야 하는데 별도 모듈은 linear memory 가 분리돼
  `TerminalCore` 를 볼 수 없고, 나누면 각 모듈이 파서·화면을 다시 포함해 합이 커진다.
  게다가 **Zig 가 이미 도달 불가 코드를 지운다** — 지금 135 KB(gzip 52 KB)는 export 한 것만이고,
  아직 안 낸 `findMatches`·PNG 디코더는 들어 있지 않다. 애드온의 목적("안 쓰는 걸 안 받기")이
  이미 달성돼 있다. 실측으로도 뗄 것이 없다: 프로시저럴 글리프를 통째로 빼야 18.7 KB
  (gzip 6.1 KB)가 줄고, 그건 폰트 없이 박스가 안 끊긴다는 차별점이라 뺄 수 없다.

  **무거운 기능이 들어오면 애드온이 아니라 wasm 변종으로 간다.** Kitty graphics 의 PNG
  디코더처럼 대다수가 안 쓰는 것은 export 집합만 다른 두 번째 wasm 을 내고 `wasmUrl` 로
  고르게 한다(그 옵션은 이미 있다).
- **인스턴스를 넘기는 플러그인(`loadAddon`)도 두지 않는다.** 애드온이 `Terminal` 내부를 만지는
  방식은 워커 모드와 맞지 않는다 — 애드온은 메인에, 코어는 워커에 있어 동기 접근이 불가능하다.
  확장이 필요하면 **능력을 주입하는 옵션**으로 받는다(렌더러의 `glyphSource` 가 그 형태다).
- **브라우저 이벤트 → `KeyEvent` 매핑의 완전성.** `base_codepoint`·`keypad`는 플랫폼이 채우는 값이고(`terminal/input.zig`), 레이아웃·IME 조합에서 브라우저마다 갈린다. 라이브러리는 합리적 기본 매핑과 §5.1의 기본 바인딩을 제공하되, 그 밖의 완전성은 약속하지 않는다. 사용자 정의 바인딩 설정은 아직 없다 — 앱이 `keydown`을 먼저 잡아 `sendText()`로 보내면 된다.
