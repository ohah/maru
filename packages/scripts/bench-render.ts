/**
 * **렌더 비용을 재는 하네스.** run 병합이 깨지는 화면에서 Canvas 2D 가 프레임 예산 안에
 * 있는지 보고, WebGL 렌더러가 필요한지 판단한다(`docs/plans/maru-term-library.md` F7.5).
 *
 * **CI 에 넣지 않는다** — 성능은 하드웨어·GPU·폰트 캐시에 좌우돼 환경마다 다르다. 깨졌을 때
 * 우리 코드 문제인지 기계 문제인지 구분되지 않는다(F1 에서 TUI 를 CI 밖에 둔 것과 같은 이유).
 *
 * ```sh
 * bun run --cwd packages bench:render                 # 304×84 (1440p 최대화)
 * bun run --cwd packages bench:render "?cols=120&rows=40"
 * ```
 */
import { chromium } from "playwright";
const PORT = 8901;
const ROOT = new URL("..", import.meta.url).pathname;
const server = Bun.serve({
  port: PORT,
  async fetch(req) {
    const url = new URL(req.url);
    const path =
      ROOT + (url.pathname === "/" ? "tests/fixtures/bench-render.html" : url.pathname.slice(1));
    if (path.endsWith(".ts") || path.endsWith(".tsx")) {
      const src = await Bun.file(path).text();
      const js = new Bun.Transpiler({ loader: "ts", target: "browser" }).transformSync(src);
      return new Response(js, { headers: { "content-type": "text/javascript" } });
    }
    return new Response(Bun.file(path));
  },
});
const browser = await chromium.launch();
const p = await browser.newPage();
const errs: string[] = [];
p.on("pageerror", (e) => errs.push(e.message));
p.on("console", (m) => {
  if (m.type() === "error") errs.push(m.text());
});
const q = process.argv[2] ?? "";
await p.goto(`http://127.0.0.1:${PORT}/${q}`);
try {
  await p.waitForFunction(() => (globalThis as any).__done === true, { timeout: 90_000 });
  console.log(JSON.stringify(await p.evaluate(() => (globalThis as any).__bench), null, 2));
} catch (e) {
  console.log("실패:", errs.slice(0, 3).join(" | ") || String(e).slice(0, 200));
}
await browser.close();
server.stop(true);
