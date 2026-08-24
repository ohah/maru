# maru-term

[maru](https://github.com/ohah/maru)의 터미널 코어를 WebAssembly로 컴파일한 브라우저 터미널.

VT 파싱·화면 상태·키 인코딩·문자 폭 판정은 **wasm(Zig)**이 하고, 글리프 모양·폰트 폴백·DOM 통합은 **웹**이 한다.

- **폭을 코어가 정한다** — 동아시아 폭(EAW)과 grapheme cluster(ZWJ·VS16·국기)를 터미널 본체와 같은 코드로 판정한다.
- **폰트 없이 그리는 글리프** — 박스 드로잉·블록·파워라인·브라유·모자이크는 코어가 셀 크기에 맞춰 직접 그린다. **Nerd Font 가 없어도** 모양이 나오고, 표의 선이 셀 경계에서 끊기지 않는다.
- **기본이 워커** — 코어와 렌더가 모두 워커에서 돌아 대량 출력에도 메인 스레드가 막히지 않는다. `SharedArrayBuffer`를 쓰지 않으므로 COOP/COEP 없이 어디에나 임베드된다.
- **컨테이너를 채운다** — `cols`/`rows`를 주지 않으면 요소 크기에 맞춰 격자를 잡고 리사이즈를 따라간다.
- **줄 편집 키가 본체와 같다** — `Cmd+Delete`(줄 삭제), `Cmd+←/→`(줄 시작·끝), `Option+←/→`(단어 이동)를 macOS 관례대로 셸 시퀀스로 보낸다.
- **IME 조합이 뒤 텍스트를 민다** — 조합 글자가 화면에 실제로 들어간다. 줄을 다시 그리는 앱은 `onPreedit`를 구독해 직접 그릴 수 있다.

| 패키지 | 내용 |
|---|---|
| `@maru/core` | wasm, 바닐라 TS API, Canvas 렌더러, 워커 |
| `@maru/react` | `<MaruTerminal />` |
| `@maru/vue` | `<MaruTerminal />` |
| `@maru/svelte` | `use:terminal` 액션 |
| `@maru/lit` | `<maru-terminal>` |

## 쓰기

### 바닐라 (프레임워크 없이)

```bash
npm i @maru/core
```

```ts
import { Terminal } from "@maru/core";

const term = new Terminal({ fontSize: 14 });   // cols/rows 를 주지 않으면 컨테이너에 맞춘다
await term.open(document.getElementById("host")!);

const socket = new WebSocket("wss://example.com/pty");
socket.binaryType = "arraybuffer";

term.onData((bytes) => socket.send(bytes));                 // 키 입력 → 호스트
socket.onmessage = (e) => term.write(new Uint8Array(e.data)); // 호스트 → 화면

term.onTitle((t) => (document.title = t));
term.onResize(({ cols, rows }) => socket.send(JSON.stringify({ resize: [cols, rows] })));
```

`open()` 은 wasm 과 워커를 만들므로 **반드시 `await`** 한다. 끝낼 때는 `term.dispose()` 로
워커·옵저버·이벤트를 정리한다.

### React

```bash
npm i @maru/core @maru/react
```

```tsx
import { MaruTerminal } from "@maru/react";

<MaruTerminal
  options={{ fontSize: 14 }}   /* cols/rows 를 주지 않으면 컨테이너에 맞춘다 */
  onData={(bytes) => socket.send(bytes)}   // 호스트로 보낼 바이트
  onTitle={(t) => (document.title = t)}
/>
```

바이트를 어디서 가져올지는 여러분이 정한다(WebSocket·SSH-over-WS·정적 trace 재생). 호스트가 준 바이트는 `write`로 되돌린다.

```ts
socket.onmessage = (e) => term.write(new Uint8Array(e.data));
```

> **`onData`를 반드시 호스트로 보내야 한다.** 키 입력뿐 아니라 터미널이 DA·CPR·OSC 질의에 답하는 바이트도 같은 경로로 나간다. 안 보내면 TUI가 응답을 기다리며 멈춘다.

## 프레임워크별

### Vue

```vue
<script setup>
import { MaruTerminal } from "@maru/vue";
</script>
<template><MaruTerminal :options="{ fontSize: 14 }" @data="onData" /></template>
```

### Svelte

```svelte
<script>
  import { terminal } from "@maru/svelte";
</script>
<div use:terminal={{ options: { fontSize: 14 }, onData }} style="width:100%;height:400px" />
```

### Lit

```html
<script type="module">import "@maru/lit";</script>
<maru-terminal style="width:100%;height:400px"></maru-terminal>
```

Svelte만 컴포넌트가 아니라 **액션**이다 — 마운트·갱신·파괴 훅이 모두 있어 기능은 같다.

## 워커

기본값은 **코어와 렌더를 모두 워커에 두는 것**이다. 대량 출력이 쌓여도 메인 스레드가 막히지 않는다.

```ts
new Terminal({ worker: "full" });  // 기본
new Terminal({ worker: false });   // 메인 스레드
```

`Worker`나 `OffscreenCanvas`가 없으면(구형 Safari 등) 자동으로 내려가고 `onFallback`으로 알린다. 옵션을 **명시**했는데 지원이 없으면 `open()`이 실패한다.

`SharedArrayBuffer`는 쓰지 않는다 — COOP/COEP가 서드파티 인증·결제 플로우를 깨뜨리는데, VT 파싱은 순차적이라 병렬 이득이 없다.

## 테마

```ts
import { themes, parseGhosttyTheme } from "@maru/core";

term.setTheme(themes.dracula);
term.setTheme(parseGhosttyTheme(await (await fetch("/themes/Nord")).text())!);
```

[Ghostty가 배포하는 테마 파일](https://github.com/ghostty-org/ghostty)을 그대로 읽는다(iTerm2-Color-Schemes 계열, 수백 종).

## 지금 상태

**파싱·화면·입력의 정확도는 본체와 같다** — libvterm·Alacritty 대조 오라클을 통과한 코어를
그대로 쓴다. 다만 그 위의 편의 기능과 API 표면은 아직 좁다.

- **없는 것**: 이미지(Kitty graphics)
- **검증 안 된 것**: 실기기 터치(합성 이벤트로 경로는 덮었다), 실제 스크린 리더
- **검증한 것**: 실제 TUI — nvim·htop·tmux·less 를 진짜 PTY 로 띄워 대체 화면·mouse
  tracking·스크롤 영역·리사이즈를 확인했다(`bun run demo` 의 "진짜 PTY" 모드)

### 화면·스크롤 제어

```ts
term.reset();              // 하드 리셋(RIS)
term.clear();              // 화면 비우기 — 아래 계약
term.scrollToTop();
term.scrollToBottom();
term.scrollToLine(120);    // 절대 행(0 = 스크롤백 최상단)을 첫 줄에
term.scrollLines(3);       // 양수가 아래 — 휠 방향
term.scrollPages(-1);
```

### 선택·키 가로채기·직렬화

```ts
copyBtn.disabled = !term.hasSelection();       // 동기 — 핸들러 안에서 바로
term.select(0, 2, 3);                          // 0행 2열부터 3칸
term.selectLines(0, 5);

term.attachCustomKeyEventHandler((ev) => !(ev.metaKey && ev.key === "k")); // ⌘K 는 앱이
await term.serialize();                        // 화면을 평문으로(스타일은 버린다)
```

### 접근성과 터치

```ts
new Terminal({ screenReaderMode: true, ariaLabel: "빌드 로그" });
```

캔버스는 보조기술이 읽을 수 없어 접근성 트리에서 빼고, 포커스를 받는 textarea 를 앵커로
씁니다. `screenReaderMode` 를 켜면 **바뀐 줄**이 라이브 리전으로 읽힙니다(기본은 꺼짐 — 프레임
마다 텍스트를 비교하는 비용이 있습니다).

터치는 **탭**(입력 포커스) · **세로 드래그**(스크롤) · **길게 누르기**(단어 선택)로 해석합니다.
브라우저의 마우스 에뮬레이션은 드래그를 선택으로 오해하므로 쓰지 않습니다.

### 링크 규칙

```ts
term.registerLinkProvider({
  provideLinks(row, text) {                      // text 는 그 줄 전체
    const m = /https?:\/\/\S+/.exec(text);
    return m ? [{
      startCol: m.index, endCol: m.index + m[0].length - 1, text: m[0],
      activate: () => open(m[0], "_blank"),
    }] : null;
  },
});
```

스택 트레이스의 `파일:줄` 을 에디터로 보내거나 `#1234` 를 이슈로 여는 데 씁니다. **URL 자동
감지도 이걸로 합니다** — 코어의 감지는 libc 를 요구해 wasm 에 없지만, 정규식 한 줄이면 같은
결과입니다. OSC 8 로 앱이 직접 선언한 링크가 규칙보다 우선합니다.

### 마커와 장식

```ts
const { matches } = await term.findMatches("error");
for (const m of matches) {
  const marker = term.registerMarker(m.startRow);           // 줄을 가리키는 안정적 참조
  term.registerDecoration({
    marker, x: m.startCol, width: m.endCol - m.startCol + 1,
    backgroundColor: 0xffd700, opacity: 0.35,
  });
}
```

스크롤백이 가득 차 그 줄이 버려지면 **마커와 장식이 함께 사라집니다**. 절대 행이 밀리는 것도
알아서 따라갑니다.

### OSC 사건 — 정책은 앱이 정한다

```ts
term.onClipboardWrite((text) => {          // OSC 52 — 라이브러리는 쓰지 않는다
  if (trusted) void navigator.clipboard.writeText(text);
});
term.onClipboardRead(() => {});            // 답하지 않는 것이 기본
term.onNotification(({ title, body }) => new Notification(title, { body }));
term.onCwdChange((cwd) => (tabLabel.textContent = cwd));
term.onShellEvent((e) => {
  if (e.kind === "command-end") console.log("exit", e.exit);
});
await term.cursorAtPrompt();               // 명령이 도는 중인지 — 닫기 확인용
```

**라이브러리는 클립보드에 쓰지도, 알림을 띄우지도 않는다.** 터미널에서 도는 아무 프로그램이나
사용자 클립보드를 덮어쓰거나 읽어 갈 수 있으면 안 되므로, 그 판단은 앱이 한다.

### 검색

```ts
const { matches, total } = await term.findMatches("error");  // 절대 행 좌표
await term.findNext("error");      // 화면에 올리고 선택 — Enter 로 순회
await term.findPrevious("error");  // Shift+Enter
```

스크롤백까지 훑고 대소문자를 구분한다(정규식은 없다). 매치가 4096 건을 넘으면 `total` 만
정확하고 배열은 앞의 4096 건이다 — "1/5000" 같은 표시를 위해서다.

### 상태 이벤트

```ts
term.onCursorMove((c) => console.log(c.row, c.col)); // 다른 칸으로 옮겨갔을 때만
term.onScroll(({ offset, length }) => drawScrollbar(offset, length));
term.onSelectionChange((sel) => (copyButton.disabled = sel === null));
```

프레임에서 파생하므로 워커 모드에서도 똑같이 온다. 커서 **모양·깜빡임**은
`onCursorMove` 로 오지 않는다 — 깜빡임이 매 프레임 토글돼 위치 변화와 섞이면 쓸 수 없다.

`clear()` 는 xterm.js 와 다르다. **셸 통합(OSC 133)이 있고 프롬프트 상태일 때만** 전체를 비우고
커서를 홈에 둔 뒤 `\x0c`(^L)를 `onData` 로 흘린다 — 그걸 PTY 에 써야 셸이 프롬프트를 다시
그린다. 그 밖에는 커서를 옮기지 않고 스크롤백과 커서 위 행만 비운다(셸의 readline 모델과
어긋나지 않기 위해서다). alt screen 에서는 무동작이다.

무엇이 어떤 순서로 올지는 [구현 계획](https://github.com/ohah/maru/blob/main/docs/plans/maru-term-library.md)에
있다. 지금 쓰기 좋은 곳은 **정확한 VT 파싱과 폭 판정이 필요한 곳**이고, xterm.js 를 그대로
대체하려면 아직 멀다.

## 무엇이 다른가

- **정확한 키 인코딩** — DECCKM, DECKPAM, 수식자 붙은 특수 키의 xterm legacy 형식, kitty CSI u
- **문자 폭** — East Asian Width와 grapheme cluster를 코어가 판정한다. 폰트가 아니라 유니코드가 정한다
- **폰트 없는 박스 드로잉** — 박스·파워라인·브라유를 계산으로 그려 폰트마다 선이 어긋나지 않는다
- **리가처** — 같은 스타일의 ASCII 연속 구간을 한 번에 그려 `<--` `===` 같은 리가처가 산다

## 만들기

```bash
zig build wasm-lib     # wasm (저장소 루트에서)
bun install
bun run build          # zntc 번들 + tsc 타입 선언
bun run check          # 전체 게이트
bun run test:browser   # 실제 브라우저 렌더 검증
```

## 라이선스

MIT
