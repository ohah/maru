# maru-term 라이브러리 구현 계획

[maru-term 라이브러리](../maru-term-library.md)의 단계별 진행 상태를 소유한다. 계약 자체는 그 문서가 단일 출처이고, 여기서는 **무엇이 끝났고 무엇이 남았는지**만 추적한다.

## 단계

| 단계 | 내용 | 게이트 | 상태 |
|---|---|---|---|
| **P0** | 이 계획과 [계약 문서](../maru-term-library.md)(doc-first), AGENTS.md 인덱스 등록 | `check-doc-links` | 완료 |
| **P1** | `src/platform/wasm/wasm_bridge.zig` + build.zig `wasm-lib` step + `.mise.toml` 태스크 + 해시 동기 게이트 | `mise run check` | 완료 |
| **P2** | `packages/` 골격, `tools/ci/changed-areas.sh` 분류, `docs/project-structure.md` 갱신 | `ci:changed-areas-check` | 완료 |
| **P3** | `@maru/core` — `Backend`/`Renderer` 추상화와 `worker: false` 경로 | `bun test` | 완료 |
| **P4** | Canvas 렌더러 — run 병합·픽셀 스냅·글리프 보정·IME·선택·스크롤백 | playwright | 완료 |
| **P5** | 워커 `'full'` — 중간 모드는 판정 결과 제외 | playwright 모드 대조 | 완료 |
| **P6** | 테마 — Ghostty 계열 파서와 런타임 적용 | `bun test` | 완료 |
| **P7** | `@maru/react` | 스모크 | 완료 |
| **P8** | `@maru/vue` | 스모크 | 완료 |
| **P9** | `@maru/svelte` (액션) | 스모크 | 완료 |
| **P10** | `@maru/lit` | 스모크 | 완료 |
| **P11** | 데모 페이지, README, `bun publish` 배포 준비 | 전체 | 완료 |

## 판정 기록

- ~~`'render'` 모드 존치~~ → **제외로 판정**(P5). 명분이던 "동기 조회"는 조회가 전부 `Promise`가 되며 사라졌고, 남은 이득으로 꼽았던 "워커 번들에서 wasm 제외"도 성립하지 않았다 — wasm 은 번들에 들어가지 않고 `new URL` 로 참조되는 별도 파일이다(워커 번들 21 KB, wasm 127 KB 별도). 2모드(`'full'`/`false`)로 줄였다.
- ~~Lit `static properties` 빌드 통과~~ → **확인**(P10). 데코레이터 없이 zntc 를 통과하고, 브라우저에서 `<maru-terminal>` 마운트·렌더·`ready` 이벤트까지 검증했다.

- ~~프로시저럴 글리프를 `box_glyph` 로 구현~~ → **`renderer.synthesizeGlyph` 로 정정**. 박스만 덮고 블록·파워라인·브라유·모자이크는 폰트로 흘렸다. 본체가 이미 10개 계열을 한 자리에서 디스패치하므로 wasm 브리지도 그걸 부른다(wasm 127 KB → 220 KB).
- **컨테이너 자동 맞춤이 기본이 됐다**. `open(el)` 로 요소를 받는 API 인데 `fit()` 을 아무도 부르지 않아 80×24 고정으로 떠 컨테이너에 여백이 남았다. `cols`/`rows` 를 명시하지 않으면 `ResizeObserver` 로 따라간다.
- **번들러가 워커 청크의 `import.meta.url` 을 빈 문자열로 접는다**(zntc 실측). `new URL(rel, "")` 은 "Invalid base URL" 로 죽어 `worker: 'full'` 이 통째로 실패했다. 로더가 `location.href` 로 물러서고, 메인이 절대 URL 을 넘기고, 빌드가 그 패턴을 fail-closed 로 막는다.

- **IME 는 `onPreedit` 구독으로 책임이 갈린다**(계약 §5). 처음엔 라이브러리가 오버레이만 그려 조합 글자가 화면에 없었고, 코어 삽입을 넣었더니 이번엔 줄을 다시 그리는 앱과 어긋났다 — 프로토타입은 셸이 `before + preedit + after` 로 함께 그려서 그 문제가 없었다. 구독 여부로 삽입 주체를 정하고, 오버레이는 항상 라이브러리가 그린다.
- **워커의 `resize` 가 backing store 를 안 잡고 있었다**. CSS 만 늘고 backing 은 옛 격자로 남아 `worker: false` 와 레이아웃이 갈렸다(966×528 CSS 에 672×528 backing). 캔버스 소유권이 워커에 있으므로 메인은 CSS 만 바꿀 수 있다 — 두 곳을 함께 고쳐야 한다.
- **기본 키바인딩 표를 본체와 맞췄다**(계약 §5.1). 코어 인코딩은 `Cmd+Backspace` 를 `Backspace` 와 구분하지 않아 줄 삭제가 한 글자 삭제로 나갔다.

- **추측으로 넣은 방어 코드가 워커를 멈춰 세웠다.** 폰트 등록 직후 격자를 재면 폴백 값이 나올까 봐 `fonts.ready` 를 기다리게 했는데, **워커의 `fonts.ready` 는 resolve 되지 않는다**(문서가 없다). `WorkerBackend.create` 가 끝나지 않아 백엔드가 끝내 null 이었고, 깜빡임 신호가 워커에 닿지 않아 커서가 멈춘 화면이 나왔다. `FontFace.load()` 가 이미 로드를 보장하므로 그 대기는 애초에 불필요했다 — 근거 없이 방어를 더하지 않는다.
- **`onBlink` 가 `this.#backend` 를 직접 읽어 항상 null 이었다.** 그 콜백은 `attachDom` 안의 타이머에서 불리는데 워커 백엔드는 그 뒤에 대입된다. 지역 변수로 잡아 고쳤다.
- **줄 간격 여백을 위아래로 나눈다**(계약 §5). 기본 `lineHeight` 는 1.22 다. 전부 아래에 두면 선택 배경이 하단 패딩처럼 보인다.

## 후속 (이 PR 범위 밖)

순서는 **실전 검증이 먼저**다. 기능을 더 넣기 전에 실제 TUI 를 붙여 봐야 지금 안 보이는 문제가
드러난다.

| 단계 | 내용 | 왜 이 순서인가 |
|---|---|---|
| **F1** | PTY 를 WebSocket 으로 물려 vim·tmux·htop 을 띄운다 | 대체 화면·스크롤 영역·mouse tracking 조합을 한 번도 안 밟았다. 여기서 나오는 결함이 아래 어느 기능보다 크다 |
| **F2** | `reset`·`clear`·스크롤 제어(`scrollToTop`/`scrollToLine`) | 구현이 코어에 있고 export + 얇은 래핑이면 된다 |
| **F3** | 상태 이벤트 — `onCursorMove`·`onScroll`·`onSelectionChange` | 앱이 터미널을 따라가려면 필요하다. 워커 모드에서 이벤트 채널을 태워야 한다 |
| **F4** | 검색(`findMatches`) + `registerMarker`/`registerDecoration` | 검색 하이라이트를 그리려면 마커/장식이 함께 있어야 한다 |
| **F5** | 클립보드(OSC 52)·알림(OSC 9/777)·셸 통합(OSC 7/133) | 각각 이벤트 채널 설계가 필요하다 |
| **F6** | 화면 직렬화(`dumpUtf`)·`attachCustomKeyEventHandler` | |
| **F7** | 이미지(Kitty graphics) | 렌더러가 픽셀을 다뤄야 해 가장 무겁다 |
| **F8** | 접근성(스크린 리더 버퍼)·모바일 터치·Safari/Firefox 검증 | |

**목록의 근거**: xterm.js 의 `Terminal` 공개 타입(`typings/xterm.d.ts`)과 1:1 대조해 뽑았다.
처음 세었던 "빠진 기능 7가지"는 **애드온급 기능만 본 것**이라 API 표면 격차(이벤트 6종, 메서드
10여 개)를 놓쳤다. 계약 §7 의 표가 그 대조 결과다.

## 선행 조건

P1은 [터미널 코어의 wasm 이식성](../wasm-portability.md)이 규정한 제약 위에서만 성립한다 — 특히 `addLibrary`가 아니라 `addExecutable` + `entry = .disabled` + `rdynamic`을 써야 하고(§5 재현법), `max_memory`를 명시해야 한다(§5.2).

프로토타입은 저장소 밖(세션 scratchpad)에 있으므로 P1·P3·P4는 그 코드를 **이식**하는 작업이지 새로 쓰는 작업이 아니다. 이식 대상은 wasm export 47개, Canvas 렌더러, IME·선택·스크롤백·readline 편집, 테마 파서다.
