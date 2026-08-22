/** 데모를 띄운다. 번들러 없이 `core/dist`를 그대로 읽으므로 `bun run build`가 선행되어야 한다. */
const ROOT = new URL("..", import.meta.url).pathname;
const port = Number(process.env.PORT ?? 8877);
Bun.serve({
  port,
  fetch(req) {
    const p = new URL(req.url).pathname;
    return new Response(Bun.file(ROOT + (p === "/" ? "demo/index.html" : p.slice(1))));
  },
});
console.log(`maru-term demo → http://127.0.0.1:${port}/`);
