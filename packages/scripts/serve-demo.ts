/** 데모를 띄운다. 번들러 없이 `core/dist`를 그대로 읽으므로 `bun run build`가 선행되어야 한다. */
const ROOT = new URL("..", import.meta.url).pathname;
const port = Number(process.env.PORT ?? 8877);
Bun.serve({
  port,
  async fetch(req) {
    const p = new URL(req.url).pathname;
    const path = ROOT + (p === "/" ? "demo/index.html" : p.slice(1));
    // 데모는 TypeScript 로 둔다 — 라이브러리 API 의 첫 소비자라 타입 검사를 받아야 한다.
    // 빌드 스텝을 두는 대신 여기서 옮겨 준다(고치면 새로고침만 하면 된다).
    if (path.endsWith(".ts")) {
      const src = await Bun.file(path).text();
      const js = new Bun.Transpiler({ loader: "ts", target: "browser" }).transformSync(src);
      return new Response(js, { headers: { "content-type": "text/javascript; charset=utf-8" } });
    }
    return new Response(Bun.file(path));
  },
});
console.log(`maru-term demo → http://127.0.0.1:${port}/`);
