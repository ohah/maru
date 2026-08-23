/**
 * 데모를 띄우고, **진짜 PTY 를 WebSocket 으로 중계한다**.
 *
 * PTY 는 라이브러리 계약 밖이다(`docs/maru-term-library.md` §1) — 여기 있는 이유는 검증
 * 하네스라서다. vim·tmux·htop 은 대체 화면·스크롤 영역·mouse tracking·DECSCUSR 을 **동시에**
 * 쓰는데, 가짜 셸로는 그 조합을 밟을 수 없다.
 *
 * PTY 는 `Bun.Terminal`(Bun 1.3.5+)을 쓴다. node-pty 같은 네이티브 의존성이 필요 없어
 * "런타임 의존성 0" 원칙을 지킨다.
 *
 * **로컬 개발 전용이다.** 127.0.0.1 에만 바인딩하고, 붙는 쪽에 셸을 그대로 내주므로 절대
 * 외부에 노출하지 않는다.
 */
const ROOT = new URL("..", import.meta.url).pathname;
const port = Number(process.env.PORT ?? 8877);

interface Session {
  proc: Bun.Subprocess;
}

const sessions = new WeakMap<Bun.ServerWebSocket<unknown>, Session>();

const server = Bun.serve({
  hostname: "127.0.0.1",
  port,
  async fetch(req, srv) {
    const url = new URL(req.url);
    if (url.pathname === "/pty") {
      return srv.upgrade(req) ? undefined : new Response("upgrade failed", { status: 400 });
    }
    const path = ROOT + (url.pathname === "/" ? "demo/index.html" : url.pathname.slice(1));
    // 데모는 TypeScript 로 둔다 — 라이브러리 API 의 첫 소비자라 타입 검사를 받아야 한다.
    // 빌드 스텝을 두는 대신 여기서 옮겨 준다(고치면 새로고침만 하면 된다).
    if (path.endsWith(".ts")) {
      const src = await Bun.file(path).text();
      const js = new Bun.Transpiler({ loader: "ts", target: "browser" }).transformSync(src);
      return new Response(js, { headers: { "content-type": "text/javascript; charset=utf-8" } });
    }
    return new Response(Bun.file(path));
  },
  websocket: {
    open(ws) {
      const shell = process.env.SHELL ?? "/bin/bash";
      const proc = Bun.spawn([shell, "-i"], {
        cwd: process.env.HOME,
        env: {
          ...process.env,
          TERM: "xterm-256color",
          // 색을 강제해 SGR 경로가 실제로 도는지 보이게 한다.
          COLORTERM: "truecolor",
        },
        terminal: {
          cols: 80,
          rows: 24,
          data(_t, chunk) {
            // 바이트 그대로 보낸다 — 라이브러리가 `write()` 로 받는 것이 곧 PTY 출력이다.
            ws.send(chunk);
          },
          exit() {
            ws.close();
          },
        },
      });
      sessions.set(ws, { proc });
    },
    message(ws, msg) {
      // 텍스트 프레임은 제어(리사이즈), 바이너리는 키 입력이다.
      const s = sessions.get(ws);
      const term = (s?.proc as { terminal?: Bun.Terminal } | undefined)?.terminal;
      if (!term) return;
      if (typeof msg === "string") {
        try {
          const m = JSON.parse(msg) as { resize?: [number, number] };
          if (m.resize) term.resize(m.resize[0], m.resize[1]);
        } catch {
          // 제어가 아니면 그대로 흘려 보낸다.
          term.write(msg);
        }
        return;
      }
      term.write(msg);
    },
    close(ws) {
      const s = sessions.get(ws);
      s?.proc.kill();
      (s?.proc as { terminal?: Bun.Terminal } | undefined)?.terminal?.close();
    },
  },
});

console.log(`maru-term demo → http://127.0.0.1:${server.port}/`);
console.log(
  `             PTY → ws://127.0.0.1:${server.port}/pty  (${process.env.SHELL ?? "/bin/bash"})`,
);
