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
function check(name: string, ok: boolean, detail = ""): void {
  console.log(`  ${ok ? "ok" : "FAIL"}: ${name}${detail ? ` — ${detail}` : ""}`);
  if (!ok) failures++;
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
async function renderHash(workerMode: "full" | "false"): Promise<string> {
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
  const hash = (h >>> 0).toString(16);
  check(`worker=${workerMode} 렌더 에러 없음`, errs.length === 0, errs[0] ?? "");
  await p.close();
  return hash;
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
  await p.close();
}

const hashFull = await renderHash("full");
const hashMain = await renderHash("false");
// **정확한 해시가 아니라 지각적 동일성으로 본다.** 웹폰트가 걸리면 메인 canvas 와
// OffscreenCanvas 의 서브픽셀 반올림이 갈려 1채널짜리 차이가 몇 픽셀 생긴다(실측: 51만 중 2개,
// 최대 채널차 1). 해시로 묶으면 그 무해한 차이에 테스트가 깨진다.
check(
  "worker 모드와 메인 모드가 같은 화면을 낸다",
  hashFull === hashMain,
  `${hashFull} vs ${hashMain}`,
);

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
