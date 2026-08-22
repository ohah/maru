/**
 * maru-term 데모 — 라이브러리 공개 API만 쓴다.
 *
 * 여기서 하는 일은 실제 앱이 할 일과 같다: `onData`로 나온 바이트를 "호스트"(여기서는 가짜 셸)로
 * 보내고, 호스트가 만든 바이트를 `write`로 되돌린다. 셸이 바이트를 직접 해석하므로 키 인코딩이
 * 실제로 맞는지가 이 데모에서 그대로 드러난다.
 */
import type { Terminal as TerminalT, Theme, TerminalOptions } from "@maru/core";

// 런타임에는 서버가 `/core/dist/index.js` 를 준다. 타입은 워크스페이스 패키지에서 가져온다.
const CORE_URL = "/core/dist/index.js";
const { Terminal, themes: PRESETS } = (await import(CORE_URL)) as unknown as {
  Terminal: new (opts?: TerminalOptions) => TerminalT;
  themes: Record<string, Theme>;
};

const $ = <T extends HTMLElement = HTMLElement>(id: string): T => document.getElementById(id) as T;
const seg = new Intl.Segmenter("ko", { granularity: "grapheme" });
const graphemes = (s: string): string[] => [...seg.segment(s)].map((g) => g.segment);

let term!: TerminalT;
let allThemes: Record<string, Theme> = { ...PRESETS };

/* ── 가짜 셸 ─────────────────────────────────────────────────────────────
   readline과 같은 방식으로 편집 줄을 통째로 다시 그린다 — 커서 앞뒤 삽입·삭제가 한 경로가 된다. */
const PROMPT = "\x1b[38;5;114m➜\x1b[0m \x1b[38;5;39m~\x1b[0m ";
let line = "";
let pos = 0;
let history: string[] = [];
let preedit = ""; // IME 조합 중인 텍스트 — 이 셸이 직접 줄에 끼워 그린다
let histIdx = -1;

/**
 * 편집 줄을 통째로 다시 그린다(readline 과 같은 방식) — 커서 앞뒤 삽입·삭제가 한 경로가 된다.
 * IME 조합 중이면 marked text 를 **끼워 넣어** 코어가 뒤 텍스트를 밀게 한다. 화면에 덮어
 * 그리기만 하면 커서 뒤 글자가 가려진다.
 */
async function redraw() {
  const gs = graphemes(line);
  const before = gs.slice(0, pos).join("");
  const after = gs.slice(pos).join("");
  term.write("\r\x1b[K" + PROMPT + before + preedit + after);
  const back = after ? await term.measureCells(after) : 0;
  if (back) term.write(`\x1b[${back}D`);
}
const prompt = () => {
  line = "";
  pos = 0;
  histIdx = -1;
  term.write("\r\n" + PROMPT);
};

const COMMANDS = {
  help: () =>
    "사용 가능: \x1b[1mhelp colors box glyphs emoji width links theme clear\x1b[0m\r\n" +
    "편집: ←→ Home End Backspace Delete, Alt+←→ 단어 이동, ↑↓ 히스토리",
  colors: () => {
    let out = "";
    for (let i = 0; i < 256; i++) {
      out += `\x1b[48;5;${i}m  \x1b[0m`;
      if ((i + 1) % 32 === 0) out += "\r\n";
    }
    return out;
  },
  box: () =>
    "┌────────┬────────┐\r\n│ parser │ screen │\r\n├────────┼────────┤\r\n" +
    "│  wasm  │ canvas │\r\n└────────┴────────┘\r\n" +
    "▁▂▃▄▅▆▇█ ▏▎▍▌▋▊▉ ╭─╮ ╰─╯ ┏━┓ ┗━┛",
  glyphs: () =>
    "\x1b[1m폰트 없이 코어가 그리는 글리프\x1b[0m — Nerd Font 가 없어도 모양이 나옵니다\r\n" +
    "박스   ┌─┬─┐ ╭─╮ ┏━┓ ╔═╗ ╱╲╳\r\n" +
    "블록   ▁▂▃▄▅▆▇█ ░▒▓ ▖▗▘▝\r\n" +
    "파워라인 \ue0b0\ue0b1\ue0b2\ue0b3 \ue0b4\ue0b6\r\n" +
    "브라유 ⠁⠃⠇⡇⣇⣧⣷⣿\r\n" +
    "모자이크 🬀🬁🬂🬃🬄🬅🬆",
  emoji: () => "😀 🎉 🚀 ✅ ⚠ 🔥 💡 🖍 📦 🌍 — EAW Wide는 2셀",
  width: () => "가나다라 마바사 日本語テスト 中文測試 — 동아시아 폭은 wasm이 판정합니다",
  links: () =>
    "\x1b]8;;https://ziglang.org\x07Zig\x1b]8;;\x07 · \x1b]8;;https://github.com/ohah/maru\x07maru\x1b]8;;\x07",
  theme: () =>
    `현재 테마: ${$<HTMLSelectElement>("o-theme").value} (${Object.keys(allThemes).length}종)`,
  clear: () => "\x1b[2J\x1b[H",
};

function run(cmd: string): string {
  const [name, ...rest] = cmd.trim().split(/\s+/);
  if (!name) return "";
  if (name === "echo") return rest.join(" ");
  const fn = COMMANDS[name as keyof typeof COMMANDS];
  return fn ? fn() : `\x1b[31mmaru-term: command not found: ${name}\x1b[0m`;
}

/** onData 바이트를 셸이 해석한다. 실제 PTY가 하는 일과 같은 층이다. */
async function onBytes(bytes: Uint8Array): Promise<void> {
  const s = new TextDecoder().decode(bytes);
  $("bytes").textContent = [...bytes].map((b) => b.toString(16).padStart(2, "0")).join(" ");
  const gs = () => graphemes(line);

  // 제어 시퀀스 먼저 — 접두 매칭이라 순서가 중요하다.
  if (s === "\r") {
    const cmd = line;
    term.write("\r\n");
    if (cmd.trim()) {
      history.unshift(cmd);
      const out = run(cmd);
      if (out) term.write(out.endsWith("\n") ? out : out + "\r\n");
    }
    prompt();
    return;
  }
  if (s === "\x7f") {
    if (pos > 0) {
      const g = gs();
      line = g.slice(0, pos - 1).join("") + g.slice(pos).join("");
      pos--;
      await redraw();
    }
    return;
  }
  if (s === "\x1b[3~") {
    const g = gs();
    if (pos < g.length) {
      line = g.slice(0, pos).join("") + g.slice(pos + 1).join("");
      await redraw();
    }
    return;
  }
  if (s === "\x1b[D" || s === "\x1bOD") {
    if (pos > 0) {
      pos--;
      await redraw();
    }
    return;
  }
  if (s === "\x1b[C" || s === "\x1bOC") {
    if (pos < gs().length) {
      pos++;
      await redraw();
    }
    return;
  }
  if (s === "\x1b[H" || s === "\x1bOH" || s === "\x01") {
    pos = 0;
    await redraw();
    return;
  }
  if (s === "\x1b[F" || s === "\x1bOF" || s === "\x05") {
    pos = gs().length;
    await redraw();
    return;
  }
  // Alt/Ctrl 단어 이동 — xterm legacy 와 Alt 접두 양쪽을 받는다.
  if (s === "\x1bb" || s === "\x1b[1;5D" || s === "\x1b[1;3D") {
    const g = gs();
    while (pos > 0 && g[pos - 1] === " ") pos--;
    while (pos > 0 && g[pos - 1] !== " ") pos--;
    await redraw();
    return;
  }
  if (s === "\x1bf" || s === "\x1b[1;5C" || s === "\x1b[1;3C") {
    const g = gs();
    while (pos < g.length && g[pos] === " ") pos++;
    while (pos < g.length && g[pos] !== " ") pos++;
    await redraw();
    return;
  }
  if (s === "\x1b[A" || s === "\x1bOA") {
    if (histIdx + 1 < history.length) {
      histIdx++;
      line = history[histIdx];
      pos = graphemes(line).length;
      await redraw();
    }
    return;
  }
  if (s === "\x1b[B" || s === "\x1bOB") {
    if (histIdx > 0) {
      histIdx--;
      line = history[histIdx];
    } else {
      histIdx = -1;
      line = "";
    }
    pos = graphemes(line).length;
    await redraw();
    return;
  }
  // Ctrl+U / Ctrl+W — Cmd+Delete·Option+Delete 가 이 시퀀스로 들어온다.
  if (s === "\x15") {
    const g = gs();
    line = g.slice(pos).join("");
    pos = 0;
    await redraw();
    return;
  }
  if (s === "\x17" || s === "\x1b\x7f") {
    const g = gs();
    let i = pos;
    while (i > 0 && g[i - 1] === " ") i--;
    while (i > 0 && g[i - 1] !== " ") i--;
    line = g.slice(0, i).join("") + g.slice(pos).join("");
    pos = i;
    await redraw();
    return;
  }
  if (s === "\x03") {
    term.write("^C");
    prompt();
    return;
  }
  if (s === "\x0c") {
    term.write("\x1b[2J\x1b[H" + PROMPT + line);
    return;
  }
  if (s.startsWith("\x1b") || s < " ") return; // 미처리 제어는 무시

  const g = gs();
  line = g.slice(0, pos).join("") + s + g.slice(pos).join("");
  pos += graphemes(s).length;
  await redraw();
}

const BANNER =
  "\x1b[1;38;5;39mmaru-term\x1b[0m — Zig 터미널 코어가 브라우저에서 돕니다\r\n" +
  "\x1b[38;5;245m파싱·폭 판정·키 인코딩: wasm · 글리프: 브라우저\x1b[0m\r\n\r\n" +
  COMMANDS.box() +
  "\r\n\r\n" +
  "연산자  \x1b[38;5;213m<-- --> === !== => -> != <= >= &&\x1b[0m  (리가처는 폰트 몫)\r\n" +
  "\x1b[38;5;245m'help' 를 쳐보세요.\x1b[0m";

/* ── 마운트 ─────────────────────────────────────────────────────────── */
async function mount() {
  term?.dispose();
  $("host").innerHTML = "";
  const workerOpt = $<HTMLSelectElement>("o-worker").value === "false" ? false : "full";
  // 격자를 명시하면 그 크기를 지키고, "자동"이면 컨테이너를 따라간다(ResizeObserver).
  const g = $<HTMLSelectElement>("o-grid").value;
  const fixed = g === "auto" ? null : g.split("x").map(Number);
  term = new Terminal({
    worker: workerOpt,
    loadFont: $<HTMLInputElement>("o-jet").checked ? "jetendard" : false,
    ...(fixed ? { cols: fixed[0], rows: fixed[1] } : {}),
    ...($<HTMLSelectElement>("o-font").value
      ? { fontFamily: $<HTMLSelectElement>("o-font").value }
      : {}),
    fontSize: Number($<HTMLInputElement>("o-size").value),
    lineHeight: Number($<HTMLInputElement>("o-line").value),
    cursorShape: $<HTMLSelectElement>("o-cursor").value as TerminalOptions["cursorShape"],
    scrollback: Number($<HTMLInputElement>("o-sb").value),
    ambiguousWide: $<HTMLInputElement>("o-amb").checked,
    ligatures: $<HTMLInputElement>("o-lig").checked,
    theme: allThemes[$<HTMLSelectElement>("o-theme").value] ?? Object.values(allThemes)[0],
  });
  term.onData(onBytes);
  // 조합을 이 셸이 그린다고 알린다 — 구독하면 라이브러리는 화면에 넣지 않는다.
  term.onPreedit((text) => {
    preedit = text;
    void redraw();
  });
  term.onFallback((r) => console.warn("워커 폴백:", r));
  await term.open($("host"));
  term.write(BANNER);
  prompt();
  watchIme();
  (globalThis as { __term?: TerminalT }).__term = term; // 콘솔에서 터미널을 만져볼 수 있게 노출한다
}

/* ── 옵션 배선 ──────────────────────────────────────────────────────── */
const live = <T>(
  id: string,
  read: (el: HTMLInputElement & HTMLSelectElement) => T,
  apply: (v: T) => void,
  view?: (v: T) => void,
): void => {
  const el = $<HTMLInputElement & HTMLSelectElement>(id);
  const isRange = el.getAttribute("type") === "range";
  const fire = () => {
    const v = read(el);
    if (view) view(v);
    apply(v);
  };
  el.addEventListener(isRange ? "input" : "change", fire);
};

live(
  "o-size",
  (e) => Number(e.value),
  (v) => term.setOptions({ fontSize: v }),
  (v) => ($("v-size").textContent = String(v)),
);
live(
  "o-line",
  (e) => Number(e.value),
  (v) => term.setOptions({ lineHeight: v }),
  (v) => ($("v-line").textContent = v.toFixed(2)),
);
live(
  "o-font",
  (e) => e.value,
  (v) => v && term.setOptions({ fontFamily: v }),
);
$<HTMLSelectElement>("o-font").addEventListener("change", (e) => {
  if (!(e.target as HTMLSelectElement).value) void mount();
}); // 기본으로 되돌리려면 재마운트
live(
  "o-cursor",
  (e) => e.value as NonNullable<TerminalOptions["cursorShape"]>,
  (v) => term.setOptions({ cursorShape: v }),
);
live(
  "o-sb",
  (e) => Number(e.value),
  (v) => term.setOptions({ scrollback: v }),
  (v) => ($("v-sb").textContent = String(v)),
);
live(
  "o-amb",
  (e) => e.checked,
  (v) => term.setOptions({ ambiguousWide: v }),
);
live(
  "o-lig",
  (e) => e.checked,
  (v) => term.setOptions({ ligatures: v }),
);
live(
  "o-theme",
  (e) => e.value,
  (v) => {
    const t = allThemes[v];
    if (t) term.setTheme(t);
  },
);
$<HTMLSelectElement>("o-worker").addEventListener("change", mount); // 모드는 재마운트가 필요하다
$<HTMLSelectElement>("o-grid").addEventListener("change", mount); // 격자 고정/자동 전환도 마찬가지
$<HTMLInputElement>("o-jet").addEventListener("change", mount); // 폰트 로드는 마운트 시점에 정해진다

/* 테마 목록 — 검색으로 463종을 훑는다. */
function fillThemes(q = "") {
  const sel = $<HTMLSelectElement>("o-theme");
  const keep = sel.value;
  const names = Object.keys(allThemes).filter((n) => n.toLowerCase().includes(q.toLowerCase()));
  sel.innerHTML = names
    .map((n) => `<option${n === keep ? " selected" : ""}>${n}</option>`)
    .join("");
  $("v-theme").textContent = `${names.length}종`;
}
$<HTMLInputElement>("o-theme-q").addEventListener("input", (e) => {
  fillThemes((e.target as HTMLInputElement).value);
});

$("bench").addEventListener("click", async () => {
  const chunk = "x".repeat(4096) + "\r\n";
  const t0 = performance.now();
  for (let i = 0; i < 400; i++) term.write(chunk);
  await term.snapshot(); // 처리가 끝날 때까지 기다린다
  const ms = performance.now() - t0;
  $("stat").textContent = `${((400 * chunk.length) / ms / 1000).toFixed(1)} MB/s`;
});

/* IME 이벤트를 그대로 찍는다 — 브라우저마다 조합 취소를 다르게 알린다. */
function watchIme() {
  const ta = document.querySelector<HTMLTextAreaElement>("#host textarea");
  if (!ta) return;
  const log: string[] = [];
  const show = (s: string): void => {
    log.push(s);
    if (log.length > 12) log.shift();
    $("imelog").textContent = log.join("  ▸  ");
  };
  for (const name of ["compositionstart", "compositionupdate", "compositionend"])
    ta.addEventListener(name, (e) => {
      show(`${name.slice(11)}(${JSON.stringify((e as CompositionEvent).data ?? "")})`);
    });
  ta.addEventListener("input", (e) => {
    show(`input[${(e as InputEvent).inputType ?? "?"}]="${ta.value}"`);
  });
}

/* ── 시작 ───────────────────────────────────────────────────────────── */
try {
  const res = await fetch("/demo/assets/themes.json");
  if (res.ok) allThemes = { ...allThemes, ...(await res.json()) };
} catch {
  /* 프리셋만으로도 동작한다 */
}
fillThemes();
$<HTMLSelectElement>("o-theme").value = Object.keys(allThemes).includes("dark")
  ? "dark"
  : Object.keys(allThemes)[0];
await mount();
