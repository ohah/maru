/**
 * 실제 브라우저에서 렌더 결과를 픽셀로 검증한다.
 *
 * bun test로는 못 하는 것만 여기서 본다 — Canvas 합성 결과(배경 run 병합, 커서 반전,
 * 선택 오버레이가 아래 색을 살리는지)는 jsdom에 캔버스가 없어 확인할 수 없다.
 */
import { chromium } from "playwright";

const ROOT = new URL("..", import.meta.url).pathname;
const PORT = 8899;

const server = Bun.serve({
  port: PORT,
  fetch(req) {
    const path = new URL(req.url).pathname;
    const file = path === "/" ? "tests/fixtures/harness.html" : path.slice(1);
    return new Response(Bun.file(ROOT + file));
  },
});

let failures = 0;
/** 두 PNG 의 차이를 센다. 압축 전 픽셀이 아니라 파일 바이트라 근사지만, 같은 인코더가
 * 만든 같은 크기 이미지라면 픽셀이 같을 때만 바이트도 같다 — 차이가 0 이면 확실히 동일하고,
 * 0 이 아니면 그 비율로 크기를 가늠한다. */
function pixelDiff(
  a: Buffer,
  b: Buffer,
): { count: number; total: number; maxDelta: number; ratio: number } {
  const n = Math.min(a.length, b.length);
  let count = Math.abs(a.length - b.length);
  let maxDelta = 0;
  for (let i = 0; i < n; i++) {
    const d = Math.abs(a[i]! - b[i]!);
    if (d) {
      count++;
      if (d > maxDelta) maxDelta = d;
    }
  }
  const total = Math.max(a.length, b.length);
  return { count, total, maxDelta, ratio: count / total };
}

function digest(buf: Buffer | Uint8Array): string {
  let h = 2166136261;
  for (const b of buf) {
    h ^= b;
    h = Math.imul(h, 16777619);
  }
  return (h >>> 0).toString(16);
}

function check(name: string, ok: boolean, detail = ""): void {
  console.log(`  ${ok ? "ok" : "FAIL"}: ${name}${detail ? ` — ${detail}` : ""}`);
  if (!ok) failures++;
}

// React 픽스처는 번들이 필요하다 — react·react-dom 은 브라우저에서 바로 부를 ESM 진입점이
// 없다(19 기준 CJS 뿐). 테스트 전용이므로 zntc 대신 Bun 번들러를 쓴다.
{
  const out = await Bun.build({
    entrypoints: [new URL("../tests/fixtures/react-entry.tsx", import.meta.url).pathname],
    target: "browser",
    format: "esm",
    define: { "process.env.NODE_ENV": '"production"' },
  });
  if (!out.success) throw new Error(`react 픽스처 번들 실패: ${out.logs.join("\n")}`);
  await Bun.write(
    new URL("../tests/fixtures/react-bundle.js", import.meta.url).pathname,
    await out.outputs[0]!.text(),
  );
}

const browser = await chromium.launch();
const page = await browser.newPage();
const errors: string[] = [];
page.on("pageerror", (e) => errors.push(e.message));
page.on("console", (m) => {
  if (m.type() === "error") errors.push(m.text());
});

await page.goto(`http://127.0.0.1:${PORT}/`);
await page.waitForFunction(() => (globalThis as { __ready?: boolean }).__ready === true, {
  timeout: 15_000,
});

check("페이지 에러 없음", errors.length === 0, errors[0] ?? "");

// ── 격자가 실측 폰트 폭으로 잡혔는가 ──
const metrics = await page.evaluate(() => {
  const c = document.querySelector("canvas")!;
  return { w: c.width, h: c.height, cssW: c.style.width, cssH: c.style.height };
});
check("canvas 크기가 잡힘", metrics.w > 0 && metrics.h > 0, `${metrics.cssW}×${metrics.cssH}`);

// ── 글자가 실제로 그려지는가 ──
await page.evaluate(() => (globalThis as any).__term.write("\x1b[1;32mhello world\x1b[0m\r\n"));
await page.waitForTimeout(120);
const painted = await page.evaluate(() => {
  const c = document.querySelector("canvas")!;
  const d = c.getContext("2d")!.getImageData(0, 0, c.width, Math.min(80, c.height)).data;
  let n = 0;
  for (let i = 0; i < d.length; i += 4) if (d[i] || d[i + 1] || d[i + 2]) n++;
  return n;
});
check("글자가 그려짐", painted > 200, `${painted}px`);

// ── 배경 run 병합: 256색 띠에 세로 줄무늬(검은 틈)가 없는가 ──
await page.evaluate(() => {
  const t = (globalThis as any).__term;
  t.write("\x1b[2J\x1b[H");
  let line = "";
  // 16번은 검정이라 "셀 경계의 틈"과 구분되지 않는다 — 밝은 색만 쓴다.
  for (let i = 0; i < 36; i++) line += `\x1b[48;5;${17 + i * 6}m  \x1b[0m`;
  t.write(line);
});
await page.waitForTimeout(120);
const stripes = await page.evaluate(() => {
  const c = document.querySelector("canvas")!;
  const dpr = c.width / parseFloat(c.style.width);
  const d = c.getContext("2d")!.getImageData(0, Math.round(8 * dpr), Math.round(500 * dpr), 1).data;
  let black = 0;
  for (let i = 0; i < d.length; i += 4) if (d[i] < 12 && d[i + 1] < 12 && d[i + 2] < 12) black++;
  return black;
});
check("배경 run 병합 — 셀 경계에 틈이 없음", stripes === 0, `검은 픽셀 ${stripes}개`);

// ── 선택 오버레이가 아래 색을 살리는가 ──
const selColors = await page.evaluate(() => {
  const t = (globalThis as any).__term;
  const c = document.querySelector("canvas")!;
  const dpr = c.width / parseFloat(c.style.width);
  const row = (y: number) => {
    const d = c.getContext("2d")!.getImageData(0, y, Math.round(500 * dpr), 1).data;
    const set = new Set<string>();
    for (let i = 0; i < d.length; i += 4) set.add(`${d[i]},${d[i + 1]},${d[i + 2]}`);
    return set.size;
  };
  const y = Math.round(8 * dpr);
  const before = row(y);
  t.selectStart(0, 0);
  t.selectExtend(0, 59);
  return new Promise<{ before: number; after: number }>((r) =>
    setTimeout(() => r({ before, after: row(y) }), 120),
  );
});
check(
  "선택이 아래 색을 덮지 않음",
  selColors.after > selColors.before * 0.5,
  `${selColors.before} → ${selColors.after}종`,
);

// ── 커서 모양이 반영되는가 ──
const cursorPx: Record<string, number> = {};
for (const shape of ["block", "underline", "bar"]) {
  cursorPx[shape] = await page.evaluate(async (s) => {
    const t = (globalThis as any).__term;
    t.write("\x1b[2J\x1b[H");
    t.selectClear();
    // DECSCUSR 의 steady 변형(2/4/6)을 쓴다 — blink 를 켠 채로 재면 꺼진 위상에서 항상 0이 나온다.
    t.write(s === "block" ? "\x1b[2 q" : s === "underline" ? "\x1b[4 q" : "\x1b[6 q");
    await new Promise((r) => setTimeout(r, 140));
    const c = document.querySelector("canvas")!;
    const dpr = c.width / parseFloat(c.style.width);
    const d = c
      .getContext("2d")!
      .getImageData(0, 0, Math.round(30 * dpr), Math.round(30 * dpr)).data;
    let n = 0;
    for (let i = 0; i < d.length; i += 4) if (d[i + 2] > 150 && d[i] < 140) n++;
    return n;
  }, shape);
}
check(
  "커서 모양이 갈림",
  cursorPx.block! > cursorPx.underline! && cursorPx.block! > cursorPx.bar!,
  `block ${cursorPx.block} / underline ${cursorPx.underline} / bar ${cursorPx.bar}`,
);

// ── 워커 모드: 같은 입력이 같은 화면을 내는가 ──
/**
 * **두 모드가 같은 답을 내는지 대조한다.** 개별 API 를 워커에서 하나씩 확인해도, 같은 입력에
 * 대해 두 모드가 **다른 결과**를 내는 회귀는 못 잡는다 — 계약 §2 가 약속하는 것이 바로 그
 * 동일성이다. 정해진 시퀀스를 넣고 모든 조회를 걷어 온다.
 */
async function apiSnapshot(p: import("playwright").Page): Promise<Record<string, unknown>> {
  return await p.evaluate(async () => {
    const t = (globalThis as unknown as { __term: Record<string, any> }).__term;
    const wait = () => new Promise((r) => setTimeout(r, 200));

    t.reset();
    await wait();
    t.setOptions({ scrollback: 500 });
    await wait();

    // 결정적 입력 — 검색 매치 3건, 셸 사건, 스크롤백이 생기도록.
    t.write("\x1b]133;A\x07$ ");
    for (let i = 0; i < 40; i++) t.write(`row ${i} hit\r\n`);
    t.write("\x1b]133;D;7\x07");
    // **프롬프트 상태로 되돌린다.** `D` 로 끝내면 `cursorAtPrompt` 가 원래 false 라, 그 조회가
    // 망가져도 두 모드가 나란히 false 를 내며 대조를 통과한다(실제로 그렇게 통과했다).
    t.write("\x1b]133;A\x07$ ");
    await wait();

    const find = await t.findMatches("hit");
    const ser = await t.serialize();
    t.selectLines(0, 1);
    await wait();
    const selText = await t.selectionText();
    const selPos = t.getSelectionPosition();
    const has = t.hasSelection();

    t.scrollToTop();
    await wait();
    const top = { off: 0, len: 0 };
    await new Promise<void>((res) => {
      const sub = t.onRender((m: any) => {
        top.off = m.scroll.offset;
        top.len = m.scroll.length;
        sub.dispose();
        res();
      });
      t.write("");
    });

    const atPrompt = await t.cursorAtPrompt();
    const cells = await t.measureCells("한글ab");

    return {
      findTotal: find.total,
      findFirst: find.matches[0] ? `${find.matches[0].startRow}:${find.matches[0].startCol}` : null,
      serLines: ser.split("\n").length,
      serHasEsc: ser.includes("\x1b"),
      selText,
      selPos: selPos ? `${selPos.startRow}-${selPos.endRow}` : null,
      has,
      scrollTop: `${top.off}/${top.len}`,
      atPrompt,
      cells,
    };
  });
}

/**
 * 커스텀 키 핸들러 검사. **두 워커 모드에서 모두 돌린다** — 키는 언제나 메인 스레드가 잡지만
 * `attachDom` 호출 경로가 모드마다 갈리므로(`#openLocal` 은 `render:true`, `#openWorker` 는
 * `render:false`) 한쪽만 보면 다른 쪽 회귀를 놓친다.
 */
async function customKeyChecks(p: import("playwright").Page, label: string): Promise<void> {
  // **커스텀 키 핸들러는 DOM 이벤트라 여기서만 볼 수 있다.** false 를 돌려주면 터미널이 그 키를
  // 완전히 무시해야 한다 — 기본 바인딩(⌘A 전체선택)도 안 타야 한다.
  const custom = await p.evaluate(async () => {
    const t = (
      globalThis as unknown as {
        __term: {
          write: (s: string) => void;
          hasSelection: () => boolean;
          selectClear: () => void;
          attachCustomKeyEventHandler: (h: ((ev: KeyboardEvent) => boolean) | null) => void;
          onData: (cb: (b: Uint8Array) => void) => { dispose(): void };
        };
      }
    ).__term;
    const wait = () => new Promise((r) => setTimeout(r, 200));
    const ime = document.querySelector("textarea") as HTMLTextAreaElement;
    const press = (init: KeyboardEventInit) =>
      ime.dispatchEvent(new KeyboardEvent("keydown", { bubbles: true, cancelable: true, ...init }));

    t.write("some text here");
    await wait();

    // 핸들러 없이는 ⌘A 가 전체 선택을 한다(기준선).
    t.selectClear();
    press({ key: "a", metaKey: true });
    await wait();
    const withoutHandler = t.hasSelection();

    // false 를 돌려주면 같은 키가 아무 일도 하면 안 된다.
    t.selectClear();
    await wait();
    t.attachCustomKeyEventHandler((ev) => !(ev.metaKey && ev.key === "a"));
    press({ key: "a", metaKey: true });
    await wait();
    const blocked = t.hasSelection();

    // 일반 키는 여전히 코어 인코딩을 타야 한다.
    const seen: number[] = [];
    const sub = t.onData((b) => seen.push(...b));
    press({ key: "x" });
    await wait();
    const passthrough = seen.length > 0;

    // null 로 해제하면 원래대로.
    t.attachCustomKeyEventHandler(null);
    t.selectClear();
    await wait();
    press({ key: "a", metaKey: true });
    await wait();
    const restored = t.hasSelection();
    sub.dispose();
    return { withoutHandler, blocked, passthrough, restored };
  });
  check(
    `${label}: 핸들러 없이는 ⌘A 가 전체 선택한다`,
    custom.withoutHandler,
    String(custom.withoutHandler),
  );
  check(
    `${label}: 커스텀 핸들러가 false 면 키가 완전히 무시된다`,
    !custom.blocked,
    String(custom.blocked),
  );
  check(
    `${label}: 막지 않은 키는 그대로 인코딩된다`,
    custom.passthrough,
    String(custom.passthrough),
  );
  check(`${label}: null 로 해제하면 원래대로`, custom.restored, String(custom.restored));
}

async function renderShot(workerMode: "full" | "false"): Promise<Buffer> {
  const p = await browser.newPage();
  const errs: string[] = [];
  p.on("pageerror", (e) => errs.push(e.message));
  await p.goto(`http://127.0.0.1:${PORT}/tests/fixtures/worker.html?worker=${workerMode}`);
  await p.waitForFunction(() => (globalThis as { __ready?: boolean }).__ready === true, {
    timeout: 15_000,
  });
  await p.evaluate(() => {
    const t = (globalThis as any).__term;
    t.write("\x1b[2J\x1b[H");
    t.write("\x1b[1;32mhello\x1b[0m world\r\n가나다 漢字\r\n");
    for (let i = 0; i < 12; i++) t.write(`\x1b[38;5;${33 + i * 6}mline ${i}\x1b[0m\r\n`);
    t.write("\x1b[2 q"); // steady block — blink 위상에 흔들리지 않게
  });
  await p.waitForTimeout(400);
  // 워커 모드에서는 메인이 캔버스를 못 읽는다(소유권이 넘어갔다). 합성된 화면을
  // 스크린샷으로 받아 비교한다 — 두 모드가 같은 픽셀을 내는지가 요점이다.
  const shot = await p.locator("canvas").screenshot();
  let h = 2166136261;
  for (const b of shot) {
    h ^= b;
    h = Math.imul(h, 16777619);
  }
  check(`worker=${workerMode} 렌더 에러 없음`, errs.length === 0, errs[0] ?? "");
  await p.close();
  return shot;
}

// 워커 모드에서 fit() 이 캔버스를 다시 잡는가. 소유권이 넘어간 캔버스를 메인에서 만지면
// "Cannot resize canvas after call to transferControlToOffscreen" 이 난다(실측 회귀).
{
  const p = await browser.newPage();
  const errs: string[] = [];
  p.on("pageerror", (e) => errs.push(e.message));
  p.on("console", (m) => {
    if (m.type() === "error") errs.push(m.text());
  });
  await p.goto(`http://127.0.0.1:${PORT}/tests/fixtures/worker.html?worker=full`);
  await p.waitForFunction(() => (globalThis as { __ready?: boolean }).__ready === true, {
    timeout: 15_000,
  });
  await p.evaluate(() => (globalThis as any).__term.fit());
  await p.waitForTimeout(300);
  await p.setViewportSize({ width: 700, height: 500 });
  await p.evaluate(() => (globalThis as any).__term.fit());
  await p.waitForTimeout(300);
  check("worker 모드에서 fit() 이 안전하다", errs.length === 0, errs[0] ?? "");

  // fit() 뒤 캔버스가 컨테이너를 실제로 채우는가. `resize()`가 `Terminal#size`를 즉시 갱신하지
  // 않으면 뒤이은 sizeCanvas()가 옛 격자로 캔버스를 잡아 오른쪽에 여백이 남는다. 워커 모드는
  // 실제 리사이즈가 비동기라 이 결함이 **여기서만** 드러난다(bun 테스트는 못 잡는다 — 메인
  // 경로에서는 백엔드가 대신 갱신해 준다).
  const fitGap = await p.evaluate(() => {
    const c = document.querySelector("canvas") as HTMLCanvasElement;
    const host = c.parentElement as HTMLElement;
    return Math.abs(Number.parseFloat(c.style.width) - host.clientWidth);
  });
  check("worker 모드에서 fit() 이 컨테이너를 채운다", fitGap < 12, `여백 ${fitGap}px`);

  // **워커에서 커서가 실제로 깜빡이는가.** 깜빡임 타이머는 메인에 있고 신호를 워커로 보내는데,
  // 그 경로가 끊기면 화면이 한 장으로 굳는다(실측: 워커 초기화가 `fonts.ready` 에서 멈춰
  // 백엔드가 null 이 되자 신호가 통째로 사라졌다). 2초 동안 화면이 최소 두 장은 나와야 한다.
  const frames = new Set<string>();
  for (let i = 0; i < 6; i++) {
    frames.add(digest(await p.locator("canvas").screenshot()));
    await p.waitForTimeout(330);
  }
  check("worker 모드에서 커서가 깜빡인다", frames.size >= 2, `2초간 화면 ${frames.size}종`);

  // **줄 간격 여백이 위아래로 나뉘는가.** 실제 `measureMetrics` 를 불러 확인한다 — 늘어난
  // 몫을 전부 baseline 아래에 두면 선택 배경이 하단 패딩처럼 보인다.
  const lead = await p.evaluate(async () => {
    // 경로를 변수로 둔다 — 브라우저 런타임 경로라 tsc 가 모듈로 해석하면 안 된다.
    const url = "/core/dist/index.js";
    const mod = (await import(url)) as {
      measureMetrics: (i: { fontFamily: string; fontSize: number; lineHeight: number }) => {
        cellHeight: number;
        ascent: number;
      };
    };
    const probe = document.createElement("canvas").getContext("2d")!;
    probe.font = "14px monospace";
    const m = probe.measureText("M");
    const asc = m.fontBoundingBoxAscent;
    const desc = m.fontBoundingBoxDescent;
    const met = mod.measureMetrics({ fontFamily: "monospace", fontSize: 14, lineHeight: 1.2 });
    return {
      above: met.ascent - asc,
      below: met.cellHeight - met.ascent - desc,
    };
  });
  // **워커 모드에서만 갈리던 결함 셋.** 전부 `worker/entry.ts` 의 `opts`/catch 경로다.
  const workerOpts = await p.evaluate(async () => {
    const t = (
      globalThis as unknown as {
        __term: {
          setOptions: (o: Record<string, unknown>) => void;
          selectionText: () => Promise<string | null>;
          snapshot: () => Promise<{ size: { cols: number; rows: number } }>;
        };
      }
    ).__term;
    const canvasW = () => (document.querySelector("canvas") as HTMLCanvasElement).width;
    const before = canvasW();
    t.setOptions({ fontSize: 22 }); // 폰트를 키우면 backing 도 커져야 한다
    await new Promise((r) => setTimeout(r, 600));
    const afterFont = canvasW();
    t.setOptions({ scrollback: 0 }); // 0 은 유효한 값이다(무시되면 안 된다)
    await new Promise((r) => setTimeout(r, 300));
    // 조회가 응답을 받는가 — 에러가 id 없이 오면 여기서 영원히 멈춘다.
    const q = await Promise.race([
      t.selectionText().then(() => "settled"),
      new Promise((r) => setTimeout(() => r("hung"), 3000)),
    ]);
    return { before, afterFont, query: q };
  });
  check(
    "worker: 폰트를 바꾸면 backing 도 따라간다",
    workerOpts.afterFont > workerOpts.before,
    `${workerOpts.before} → ${workerOpts.afterFont}`,
  );
  // `onRender` 는 두 모드에서 와야 한다 — 워커에서 죽어 있으면 같은 API 가 모드에 따라 갈린다.
  const rendered = await p.evaluate(async () => {
    const t = (
      globalThis as unknown as {
        __term: {
          onRender: (cb: (m: unknown) => void) => { dispose(): void };
          write: (s: string) => void;
        };
      }
    ).__term;
    let got: Record<string, unknown> | null = null;
    const sub = t.onRender((m) => {
      got = m as Record<string, unknown>;
    });
    t.write("render probe\r\n");
    await new Promise((r) => setTimeout(r, 800));
    sub.dispose();
    return got === null ? null : Object.keys(got).sort().join(",");
  });
  check("worker: onRender 가 온다", rendered !== null, rendered ?? "(안 옴)");

  // **제어 API 가 워커에서도 살아 있는가.** 프록시가 메시지를 안 실어 보내면 메인에서는
  // 조용히 무동작이 된다 — 같은 API 가 모드에 따라 갈리는 그 결함이다. `clear` 는 특히
  // 왕복이다: 판단은 워커 안 코어가 하고, ^L 은 `data` 이벤트로 메인까지 돌아와야 한다.
  const control = await p.evaluate(async () => {
    const t = (
      globalThis as unknown as {
        __term: {
          setOptions: (o: Record<string, unknown>) => void;
          write: (s: string) => void;
          clear: () => void;
          scrollToTop: () => void;
          scrollToBottom: () => void;
          reset: () => void;
          onData: (cb: (b: Uint8Array) => void) => { dispose(): void };
          onRender: (cb: (m: { scroll: { offset: number; length: number } }) => void) => {
            dispose(): void;
          };
        };
      }
    ).__term;
    let scroll = { offset: 0, length: 0 };
    const sub = t.onRender((m) => {
      scroll = m.scroll;
    });
    const out: number[] = [];
    const dsub = t.onData((b) => out.push(...b));
    const wait = () => new Promise((r) => setTimeout(r, 250));

    // 앞 검사가 `scrollback: 0` 으로 두고 갔다 — 되돌리지 않으면 아래가 전부 0 대 0 으로
    // 통과해 버린다(실제로 그렇게 통과하는 것을 보고 잡았다).
    t.setOptions({ scrollback: 1000 });
    await wait();

    for (let i = 0; i < 60; i++) t.write(`ctl ${i}\r\n`);
    await wait();
    const grew = scroll.length;

    t.scrollToTop();
    await wait();
    const atTop = scroll.offset;

    t.scrollToBottom();
    await wait();
    const atBottom = scroll.offset;

    t.write("\x1b]133;A\x07$ "); // 프롬프트를 선언해야 ^L 이 나간다
    await wait();
    t.clear();
    await wait();
    const afterClear = scroll.length;
    const formFeed = out.filter((b) => b === 0x0c).length;

    for (let i = 0; i < 20; i++) t.write(`more ${i}\r\n`);
    await wait();
    t.reset();
    await wait();
    const afterReset = scroll.length;

    sub.dispose();
    dsub.dispose();
    return { grew, atTop, atBottom, afterClear, formFeed, afterReset };
  });
  // 이 단언이 먼저다 — 스크롤백이 비어 있으면 아래 셋이 전부 0 대 0 으로 통과한다.
  check("worker: 스크롤백이 실제로 쌓였다", control.grew > 0, `${control.grew}행`);
  check(
    "worker: scrollToTop 이 맨 위로 간다",
    control.grew > 0 && control.atTop === control.grew,
    `${control.atTop}/${control.grew}`,
  );
  check(
    "worker: scrollToBottom 이 바닥으로 온다",
    control.atBottom === 0,
    String(control.atBottom),
  );
  check(
    "worker: clear 가 스크롤백을 비운다",
    control.grew > 0 && control.afterClear === 0,
    `${control.grew} → ${control.afterClear}`,
  );
  check(
    "worker: clear 의 ^L 이 메인까지 돌아온다",
    control.formFeed === 1,
    `${control.formFeed}개`,
  );
  // **상태 이벤트는 두 모드에서 와야 한다.** 파생을 `Terminal` 한 곳에 뒀으므로 워커에서도
  // 같은 경로를 타지만, `onRendered` 가 죽으면 조용히 안 온다 — 그 회귀를 여기서 잡는다.
  const evs = await p.evaluate(async () => {
    const t = (
      globalThis as unknown as {
        __term: {
          write: (s: string) => void;
          scroll: (d: number) => void;
          selectWord: (r: number, c: number) => void;
          selectClear: () => void;
          onCursorMove: (cb: () => void) => { dispose(): void };
          onScroll: (cb: () => void) => { dispose(): void };
          onSelectionChange: (cb: (s: unknown) => void) => { dispose(): void };
        };
      }
    ).__term;
    const wait = () => new Promise((r) => setTimeout(r, 250));
    let cursor = 0;
    let scroll = 0;
    const sel: unknown[] = [];
    const subs = [
      t.onCursorMove(() => cursor++),
      t.onScroll(() => scroll++),
      t.onSelectionChange((s) => sel.push(s)),
    ];
    t.write("evt probe");
    await wait();
    // 앞 검사가 `reset()` 으로 스크롤백을 비웠다 — 화면 행 수를 확실히 넘겨야 다시 쌓인다.
    for (let i = 0; i < 80; i++) t.write(`row ${i}\r\n`);
    await wait();
    t.scroll(2);
    await wait();
    t.selectWord(0, 1);
    await wait();
    t.selectClear();
    await wait();
    for (const x of subs) x.dispose();
    return { cursor, scroll, selCount: sel.length, lastSelNull: sel.at(-1) === null };
  });
  await customKeyChecks(p, "worker");

  // OSC 사건은 워커에서 `event` 채널로 실려 온다. 클립보드·알림은 **알리기만** 해야 한다 —
  // 라이브러리가 자동으로 쓰면 임의의 셸 스크립트가 사용자 클립보드를 덮어쓸 수 있다.
  const osc = await p.evaluate(async () => {
    const t = (
      globalThis as unknown as {
        __term: {
          write: (s: string) => void;
          cursorAtPrompt: () => Promise<boolean>;
          onClipboardWrite: (cb: (s: string) => void) => { dispose(): void };
          onNotification: (cb: (n: { title: string; body: string }) => void) => { dispose(): void };
          onCwdChange: (cb: (c: string) => void) => { dispose(): void };
          onShellEvent: (cb: (e: { kind: string }) => void) => { dispose(): void };
        };
      }
    ).__term;
    const clip: string[] = [];
    const note: string[] = [];
    const cwd: string[] = [];
    const shell: string[] = [];
    const subs = [
      t.onClipboardWrite((x) => clip.push(x)),
      t.onNotification((n) => note.push(n.title + n.body)),
      t.onCwdChange((c) => cwd.push(c)),
      t.onShellEvent((e) => shell.push(e.kind)),
    ];
    const wait = () => new Promise((r) => setTimeout(r, 250));
    // **연달아 보낸다.** 하나씩 떼어 보내면 "알림 없는 write" 경로를 안 밟아, 부호 실수로
    // 빈 알림이 새는 결함을 놓친다(실제로 그렇게 새고 있었다).
    t.write("\x1b]52;c;" + btoa("from worker") + "\x07");
    t.write("\x1b]9;done\x07");
    t.write("\x1b]7;file://h/tmp/x\x07");
    t.write("\x1b]133;A\x07$ ");
    await wait();
    const atPrompt = await t.cursorAtPrompt();
    for (const x of subs) x.dispose();
    return { clip: clip[0], note: note[0], cwd: cwd.at(-1), shell, atPrompt };
  });
  check("worker: OSC 52 쓰기가 메인까지 온다", osc.clip === "from worker", String(osc.clip));
  check("worker: OSC 9 알림이 온다", (osc.note ?? "").includes("done"), String(osc.note));
  check("worker: OSC 7 cwd 가 온다", osc.cwd === "/tmp/x", String(osc.cwd));
  check("worker: OSC 133 셸 사건이 온다", osc.shell.includes("prompt-start"), osc.shell.join(","));
  check("worker: cursorAtPrompt 조회가 답한다", osc.atPrompt === true, String(osc.atPrompt));

  // 검색은 조회라 워커 왕복이다 — 매치 배열이 구조적 복제로 제대로 건너오는지 본다.
  const found = await p.evaluate(async () => {
    const t = (
      globalThis as unknown as {
        __term: {
          write: (s: string) => void;
          findMatches: (n: string) => Promise<{ matches: unknown[]; total: number }>;
          findNext: (n: string) => Promise<boolean>;
          selectionText: () => Promise<string | null>;
        };
      }
    ).__term;
    t.write("\r\nfindme once\r\n");
    await new Promise((r) => setTimeout(r, 300));
    const r = await t.findMatches("findme");
    const hit = await t.findNext("findme");
    await new Promise((r) => setTimeout(r, 300));
    const sel = await t.selectionText();
    const none = await t.findMatches("zzzznope");
    return { total: r.total, hit, sel, none: none.total };
  });
  check("worker: findMatches 가 매치를 돌려준다", found.total >= 1, `${found.total}건`);
  check(
    "worker: findNext 가 그 글자를 선택한다",
    found.hit && found.sel === "findme",
    String(found.sel),
  );
  check("worker: 없는 것은 0 건", found.none === 0, String(found.none));

  const ser = await p.evaluate(async () => {
    const t = (globalThis as unknown as { __term: { serialize: () => Promise<string> } }).__term;
    const text = await t.serialize();
    return { has: text.includes("findme"), esc: text.includes("\x1b") };
  });
  check("worker: serialize 가 화면 평문을 돌려준다", ser.has && !ser.esc, `esc=${ser.esc}`);

  // 동기 조회가 워커에서도 값을 준다 — `#prevMeta` 가 `onRendered` 로 갱신되기 때문이다.
  const syncSel = await p.evaluate(async () => {
    const t = (
      globalThis as unknown as {
        __term: {
          selectLines: (a: number, b: number) => void;
          selectClear: () => void;
          hasSelection: () => boolean;
          getSelectionPosition: () => { startRow: number; endRow: number } | null;
        };
      }
    ).__term;
    const wait = () => new Promise((r) => setTimeout(r, 250));
    t.selectClear();
    await wait();
    const empty = t.getSelectionPosition();
    t.selectLines(0, 1);
    await wait();
    const pos = t.getSelectionPosition();
    return { empty, has: t.hasSelection(), startRow: pos?.startRow, endRow: pos?.endRow };
  });
  check(
    "worker: getSelectionPosition 이 동기로 값을 준다",
    syncSel.empty === null && syncSel.has && syncSel.startRow === 0 && syncSel.endRow === 1,
    `${syncSel.startRow}~${syncSel.endRow}`,
  );
  check("worker: onCursorMove 가 온다", evs.cursor > 0, `${evs.cursor}회`);
  check("worker: onScroll 이 온다", evs.scroll > 0, `${evs.scroll}회`);
  check(
    "worker: onSelectionChange 가 선택·해제를 알린다",
    evs.selCount >= 2 && evs.lastSelNull,
    `${evs.selCount}회 · 마지막 null=${evs.lastSelNull}`,
  );
  check(
    "worker: reset 이 스크롤백을 비운다",
    control.grew > 0 && control.afterReset === 0,
    String(control.afterReset),
  );

  check("worker: 조회가 응답한다", workerOpts.query === "settled", String(workerOpts.query));

  check(
    "줄 간격 여백이 위아래로 나뉜다",
    lead.above > 0 && Math.abs(lead.above - lead.below) <= 1.01,
    `위 ${lead.above.toFixed(1)}px · 아래 ${lead.below.toFixed(1)}px`,
  );
  await p.close();
}

// **메인 모드에서도 키 검사를 돌린다.** 위 블록은 전부 `worker=full` 이라, 이 검사가 없으면
// `worker: false` 경로의 키 처리 회귀를 아무도 못 본다(bun test 는 DOM 이 없어 못 덮는다).
{
  const p = await browser.newPage();
  const errs: string[] = [];
  p.on("pageerror", (e) => errs.push(e.message));
  await p.goto(`http://127.0.0.1:${PORT}/tests/fixtures/worker.html?worker=false`);
  await p.waitForFunction(() => (globalThis as { __ready?: boolean }).__ready === true, {
    timeout: 15_000,
  });
  await p.waitForTimeout(300);
  await customKeyChecks(p, "main");
  check("main: 키 검사 중 에러 없음", errs.length === 0, errs[0] ?? "");
  await p.close();
}

// **두 모드 API 동일성.** 위 검사들이 각 모드를 따로 봤다면, 이건 같은 입력에 대해 두 모드가
// 같은 답을 내는지 본다 — 계약 §2 가 약속하는 것이 그 동일성이다.
{
  const snaps: Record<string, unknown>[] = [];
  for (const mode of ["full", "false"] as const) {
    const p = await browser.newPage();
    await p.goto(`http://127.0.0.1:${PORT}/tests/fixtures/worker.html?worker=${mode}`);
    await p.waitForFunction(() => (globalThis as { __ready?: boolean }).__ready === true, {
      timeout: 15_000,
    });
    await p.waitForTimeout(300);
    snaps.push(await apiSnapshot(p));
    await p.close();
  }
  const [a, b] = snaps;
  const diff = Object.keys(a).filter((k) => JSON.stringify(a[k]) !== JSON.stringify(b[k]));
  check(
    "두 모드가 같은 API 결과를 낸다",
    diff.length === 0,
    diff.length === 0
      ? `${Object.keys(a).length}개 항목 일치`
      : diff.map((k) => `${k}: ${JSON.stringify(a[k])} vs ${JSON.stringify(b[k])}`).join(" · "),
  );
  // 값이 비어 있으면 "둘 다 빈 값"으로도 통과한다 — 실제로 무언가 나왔는지 못 박는다.
  check(
    "두 모드 대조가 실제 값을 봤다",
    // "둘 다 빈 값"이나 "둘 다 false" 로도 일치는 통과한다 — 의미 있는 값을 봤는지 못 박는다.
    (a.findTotal as number) > 0 &&
      a.selText !== null &&
      a.atPrompt === true &&
      (a.cells as number) === 6,
    JSON.stringify(a),
  );
}

// **장식이 실제로 픽셀에 나타나는가.** 모델(마커 좌표)은 bun test 가 덮지만, 렌더러가 그걸
// 그리는지는 캔버스를 봐야 안다. 두 모드에서 모두 본다 — 워커는 프로토콜로 실어 보내므로
// 경로가 다르다.
for (const mode of ["full", "false"] as const) {
  const p = await browser.newPage();
  const errs: string[] = [];
  p.on("pageerror", (e) => errs.push(e.message));
  await p.goto(`http://127.0.0.1:${PORT}/tests/fixtures/worker.html?worker=${mode}`);
  await p.waitForFunction(() => (globalThis as { __ready?: boolean }).__ready === true, {
    timeout: 15_000,
  });
  const r = await p.evaluate(async () => {
    const t = (globalThis as unknown as { __term: Record<string, any> }).__term;
    const wait = () => new Promise((res) => setTimeout(res, 300));
    t.reset();
    await wait();
    t.write("row0\r\nrow1\r\nrow2\r\n");
    await wait();
    const shot = () => {
      const cv = document.querySelector("canvas") as HTMLCanvasElement;
      // 워커 모드에서는 메인이 2d 컨텍스트를 못 얻는다 — 화면을 다시 그려 픽셀을 읽는다.
      const tmp = document.createElement("canvas");
      tmp.width = cv.width;
      tmp.height = cv.height;
      const c = tmp.getContext("2d")!;
      c.drawImage(cv, 0, 0);
      return c.getImageData(0, 0, cv.width, Math.min(60, cv.height)).data;
    };
    const countRed = (d: Uint8ClampedArray) => {
      let n = 0;
      for (let i = 0; i < d.length; i += 4) if (d[i] > 200 && d[i + 1] < 60 && d[i + 2] < 60) n++;
      return n;
    };
    const before = shot();
    const marker = t.registerMarker(1); // 두 번째 줄
    const deco = t.registerDecoration({ marker, backgroundColor: 0xff0000, opacity: 1 });
    await wait();
    const after = shot();
    let diff = 0;
    for (let i = 0; i < before.length; i += 4) {
      if (before[i] !== after[i] || before[i + 1] !== after[i + 1]) diff++;
    }
    // 지우면 화면에서도 걷혀야 한다 — 남으면 dispose 한 하이라이트가 계속 보인다.
    deco.dispose();
    await wait();
    const gone = countRed(shot());
    return { diff, red: countRed(after), gone };
  });
  check(`장식(${mode}): 화면이 바뀐다`, r.diff > 0, `${r.diff}px`);
  check(`장식(${mode}): 지정한 색이 실제로 칠해진다`, r.red > 100, `빨강 ${r.red}px`);
  check(`장식(${mode}): dispose 하면 화면에서 걷힌다`, r.gone === 0, `남은 빨강 ${r.gone}px`);
  check(`장식(${mode}): 에러 없음`, errs.length === 0, errs[0] ?? "");
  await p.close();
}

// **능력 감지와 폴백.** 구형 브라우저를 받아 오는 대신 전역을 지워 같은 분기를 밟는다 —
// 폴백은 `typeof Worker`·`typeof OffscreenCanvas` 하나로 결정되므로 이 편이 싸고 **결정적**이다
// (실제 Safari 는 버전이 오르면 그 경로를 더는 밟지 못한다).
for (const [kill, want] of [
  [null, null],
  ["OffscreenCanvas", "no-offscreen-canvas"],
  ["Worker", "no-worker"],
] as const) {
  const p = await browser.newPage();
  const errs: string[] = [];
  p.on("pageerror", (e) => errs.push(e.message));
  if (kill) await p.addInitScript(`delete globalThis.${kill};`);
  await p.goto(`http://127.0.0.1:${PORT}/tests/fixtures/auto-worker.html`);
  await p.waitForFunction(() => (globalThis as { __ready?: boolean }).__ready === true, {
    timeout: 15_000,
  });
  const r = await p.evaluate(() => {
    const at = (globalThis as { __atOpen?: { backing: string; css: string } }).__atOpen;
    return {
      fallback: (globalThis as { __fallback?: string | null }).__fallback ?? null,
      err: (globalThis as { __err?: string }).__err ?? null,
      // **픽스처가 `open()` 직후 굳혀 둔 값**이다. 여기서 캔버스를 다시 읽으면 그 사이 워커가
      // 크기를 잡아 버려 결함이 숨는다(훼손 테스트로 확인했다).
      backing: at?.backing ?? "없음",
      css: at?.css ?? "없음",
    };
  });
  const label = kill ? `${kill} 없음` : "정상";
  check(
    `폴백: ${label} → ${want ?? "워커 유지"}`,
    r.fallback === want && !r.err,
    `${r.fallback} ${r.err ?? ""}`,
  );
  // **`open()` 이 resolve 된 시점에 backing 이 CSS 와 맞아야 한다.** 워커 모드에서는 캔버스를
  // 넘기기 전에 잡지 않으면 기본값 300×150 인 채로 넘어가 몇 프레임 흐릿하다(실측 22ms).
  check(
    `폴백: ${label} → open 직후 backing==css`,
    r.backing !== "없음" && r.backing === r.css, // "없음 vs 없음"도 일치라 값 유무를 먼저 본다
    `${r.backing} vs ${r.css}`,
  );
  check(`폴백: ${label} → 에러 없음`, errs.length === 0, errs[0] ?? "");
  await p.close();
}

const shotFull = await renderShot("full");
const shotMain = await renderShot("false");
// **정확한 해시가 아니라 지각적 동일성으로 본다.** 웹폰트가 걸리면 메인 canvas 와
// OffscreenCanvas 의 서브픽셀 반올림이 갈려 1채널짜리 차이가 몇 픽셀 생긴다(실측: 51만 중 2개,
// 최대 채널차 1). 해시로 묶으면 그 무해한 차이에 테스트가 깨진다.
// 웹폰트가 걸리면 메인 canvas 와 OffscreenCanvas 의 서브픽셀 반올림이 갈려 1채널짜리 차이가
// 몇 픽셀 생긴다(실측: 51만 중 2개, 최대 채널차 1). 그래서 **해시가 아니라 픽셀 차이 비율**로
// 본다 — 의미 있는 회귀는 잡고 무해한 반올림은 통과시킨다.
const diff = pixelDiff(shotFull, shotMain);
check(
  "worker 모드와 메인 모드가 같은 화면을 낸다",
  diff.ratio < 0.0005,
  `다른 픽셀 ${diff.count}/${diff.total} · 최대 채널차 ${diff.maxDelta}`,
);

// ── Vue·Svelte 래퍼가 실제로 마운트되는가 ──
// 번들이 나오는 것만으로는 부족하다. 프레임워크 훅(onMounted·액션)이 코어를 실제로 띄우고
// `onReady` 가 오는지까지 봐야 래퍼가 동작한다고 말할 수 있다.
for (const [name, file] of [
  ["react", "react.html"],
  ["vue", "vue.html"],
  ["svelte", "svelte.html"],
] as const) {
  const p = await browser.newPage();
  const errs: string[] = [];
  p.on("pageerror", (e) => errs.push(e.message));
  p.on("console", (m) => {
    if (m.type() === "error") errs.push(m.text());
  });
  await p.goto(`http://127.0.0.1:${PORT}/tests/fixtures/${file}`);
  try {
    await p.waitForFunction(() => (globalThis as { __ready?: boolean }).__ready === true, {
      timeout: 15_000,
    });
  } catch {
    errs.push("__ready 가 오지 않았다");
  }
  const painted = await p.evaluate(() => {
    const c = document.querySelector("canvas");
    if (!c) return -1;
    return c.width;
  });
  check(
    `${name} 래퍼 마운트 + 렌더`,
    errs.length === 0 && painted > 0,
    errs[0] ?? `canvas ${painted}px`,
  );
  await p.close();
}

// ── Lit 커스텀 엘리먼트가 실제로 마운트되는가 ──
{
  const p = await browser.newPage();
  const errs: string[] = [];
  p.on("pageerror", (e) => errs.push(e.message));
  p.on("console", (m) => {
    if (m.type() === "error") errs.push(m.text());
  });
  await p.goto(`http://127.0.0.1:${PORT}/tests/fixtures/lit.html`);
  let ok = true;
  try {
    await p.waitForFunction(() => (globalThis as { __ready?: boolean }).__ready === true, {
      timeout: 15_000,
    });
  } catch {
    ok = false;
  }
  const painted = ok
    ? await p.evaluate(() => {
        const c = document.querySelector("maru-terminal")!.shadowRoot!.querySelector("canvas")!;
        const d = c.getContext("2d")!.getImageData(0, 0, c.width, 40).data;
        let n = 0;
        for (let i = 0; i < d.length; i += 4) if (d[i] || d[i + 1] || d[i + 2]) n++;
        return n;
      })
    : 0;
  check("<maru-terminal> 마운트 + 렌더", ok && painted > 100, errs[0] ?? `${painted}px`);
  const gotEvent = ok
    ? await p.evaluate(() => (globalThis as { __readyEvent?: boolean }).__readyEvent === true)
    : false;
  check("<maru-terminal> ready 이벤트", gotEvent);
  await p.close();
}

await browser.close();
server.stop();

console.log(failures === 0 ? "test-browser: 전부 통과" : `test-browser: ${failures}건 실패`);
process.exit(failures === 0 ? 0 : 1);
