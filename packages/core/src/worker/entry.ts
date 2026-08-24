/**
 * 워커 엔트리(`worker: "full"`). **wasm과 렌더러를 모두 여기서** 소유한다 — 메인 스레드는
 * 이벤트만 주고받으므로 대량 출력이 쌓여도 UI가 막히지 않는다.
 *
 * DOM 이벤트는 워커가 받을 수 없다. 키·마우스는 메인이 잡아 `postMessage`로 넘긴다.
 */
import { loadBundledFont } from "../font";
import { LocalBackend } from "../backend/local";
import { CanvasRenderer } from "../render/canvas";
import { measureMetrics } from "../render/metrics";
import type { FromWorker, ToWorker, WorkerRenderOptions } from "./protocol";

let backend: LocalBackend | null = null;
const renderer = new CanvasRenderer();
/** 워커도 같은 규칙으로 박스 드로잉을 그린다 — 모드 간 화면이 같아야 한다. */
let opts: WorkerRenderOptions | null = null;
let decorations: import("../decoration").DecorationSpan[] = [];
let preedit = "";
let blinkOn = true;
/** 마지막으로 잡은 격자. 폰트가 바뀌면 이 크기로 backing 을 다시 잡는다. */
let lastSize: { cols: number; rows: number } | null = null;

/** 캔버스 backing store 를 다시 잡고 렌더러를 붙인다. 메인은 이걸 못 한다(소유권 이전). */
function sizeCanvas(cols: number, rows: number): void {
  if (!canvas || !metrics || !opts) return;
  lastSize = { cols, rows };
  const dpr = opts.devicePixelRatio;
  canvas.width = Math.ceil(cols * metrics.cellWidth * dpr);
  canvas.height = rows * metrics.cellHeight * dpr;
  const ctx = canvas.getContext("2d");
  ctx?.setTransform(1, 0, 0, 1, 0, 0);
  ctx?.scale(dpr, dpr);
  renderer.attach(canvas, metrics);
}

const post = (msg: FromWorker, transfer?: Transferable[]) =>
  (globalThis as unknown as Worker).postMessage(msg, transfer ?? []);

let lastFrame: import("../backend/types").FrameData | null = null;
let canvas: OffscreenCanvas | null = null;
let metrics: import("../render/types").Metrics | null = null;

function redraw(): void {
  if (lastFrame && opts) {
    renderer.draw(lastFrame, {
      theme: opts.theme,
      ligatures: opts.ligatures,
      preedit,
      blinkOn,
      decorations,
    });
    // 셀은 빼고 요약만 올린다 — 앱의 `onRender` 가 워커 모드에서도 살아 있어야 한다.
    post({
      t: "rendered",
      meta: {
        size: lastFrame.size,
        cursor: lastFrame.cursor,
        selection: lastFrame.selection,
        scroll: lastFrame.scroll,
        evicted: lastFrame.evicted,
        pushed: lastFrame.pushed,
      },
    });
  }
}

self.onmessage = async (ev: MessageEvent<ToWorker>) => {
  const msg = ev.data;
  try {
    switch (msg.t) {
      case "init": {
        opts = msg.opts;
        // wasmUrl 은 메인이 절대 URL 로 확정해 준다(워커에는 신뢰할 base 가 없다).
        // **워커에서도 폰트를 등록한다.** OffscreenCanvas 가 보는 폰트 집합은 워커의 것이라
        // 메인에서 등록한 face 는 여기 없다 — 안 하면 워커 모드만 폴백 폰트로 그려진다.
        // 커스텀 URL 이면 그것만, 아니면 기본 번들(Regular+Bold)을 여기서 직접 받는다 —
        // 메인이 URL 하나만 넘기면 Bold 가 빠져 굵은 한글이 합성으로 뭉개진다.
        if (msg.fontUrl) await loadBundledFont(msg.fontUrl);
        else if (msg.loadFont) await loadBundledFont();
        backend = await LocalBackend.create(msg.size, msg.wasmUrl);
        // 워커도 같은 규칙으로 박스 드로잉을 그린다 — 모드 간 화면이 같아야 한다.
        renderer.setGlyphSource(backend.glyphSource());
        backend.on((e) => {
          if (e.type === "render") {
            lastFrame = e.frame;
            redraw();
            return;
          }
          post({ t: "event", event: e });
        });
        metrics = measureMetrics({
          fontFamily: opts.fontFamily,
          fontSize: opts.fontSize,
          lineHeight: opts.lineHeight,
          devicePixelRatio: opts.devicePixelRatio,
        });
        canvas = msg.canvas;
        sizeCanvas(msg.size.cols, msg.size.rows);
        if (opts.theme) backend.setTheme(opts.theme);
        if (opts.cursorShape) backend.setCursorShape(opts.cursorShape);
        if (opts.ambiguousWide !== undefined) backend.setAmbiguousWide(opts.ambiguousWide);
        // `0`(스크롤백 없음)도 유효한 값이라 `!== undefined` 로 본다.
        if (opts.scrollback !== undefined) backend.setScrollback(opts.scrollback);
        post({ t: "ready" });
        return;
      }
      case "write":
        backend?.write(msg.bytes);
        return;
      case "key":
        backend?.key(msg.input);
        return;
      case "paste":
        backend?.paste(msg.text);
        return;
      case "mouse":
        backend?.mouse(msg.ev);
        return;
      case "focus":
        backend?.focus(msg.gained);
        return;
      case "resize":
        backend?.resize(msg.cols, msg.rows);
        // **backing store 도 같이 잡는다.** 소유권이 워커에 있으므로 메인은 CSS 크기만 바꿀 수
        // 있다. 여기서 안 잡으면 CSS 는 늘고 backing 은 옛 격자로 남아 화면이 늘어져 보인다
        // — `worker: false` 와 레이아웃이 갈리는 원인이었다.
        sizeCanvas(msg.cols, msg.rows);
        return;
      case "scroll":
        backend?.scroll(msg.deltaUp);
        return;
      case "scrollBottom":
        backend?.scrollToBottom();
        return;
      case "scrollTop":
        backend?.scrollToTop();
        return;
      case "scrollToLine":
        backend?.scrollToLine(msg.line);
        return;
      case "clear":
        backend?.clear();
        return;
      case "decorations": {
        // **받는 쪽에서도 막는다.** 보내는 쪽(`Terminal#pushDecorations`)이 이미 바뀔 때만
        // 보내지만, 거기가 뚫리면 곧바로 무한 루프가 된다 — 다시 그리면 `rendered` 가 나가고
        // 그 프레임이 또 장식을 실어 온다(실측: 초당 1638 프레임). 한 겹으로 두지 않는다.
        const next = msg.spans;
        const same =
          next.length === decorations.length &&
          next.every((s, i) => {
            const o = decorations[i]!;
            return (
              s.row === o.row &&
              s.x === o.x &&
              s.width === o.width &&
              s.backgroundColor === o.backgroundColor &&
              s.foregroundColor === o.foregroundColor &&
              s.opacity === o.opacity
            );
          });
        if (same) return;
        decorations = next;
        redraw();
        return;
      }
      case "sel": {
        const b = backend;
        if (!b) return;
        if (msg.op === "start") b.selectStart(msg.row!, msg.col!, msg.block ?? false);
        else if (msg.op === "extend") b.selectExtend(msg.row!, msg.col!);
        else if (msg.op === "word") b.selectWord(msg.row!, msg.col!);
        else if (msg.op === "line") b.selectLine(msg.row!);
        else if (msg.op === "all") b.selectAll();
        else b.selectClear();
        return;
      }
      case "opts": {
        if (!opts) return;
        opts = { ...opts, ...msg.opts };
        if (msg.opts.theme) backend?.setTheme(msg.opts.theme);
        if (msg.opts.cursorShape) backend?.setCursorShape(msg.opts.cursorShape);
        if (msg.opts.ambiguousWide !== undefined) backend?.setAmbiguousWide(msg.opts.ambiguousWide);
        if (msg.opts.scrollback !== undefined) backend?.setScrollback(msg.opts.scrollback);
        if (msg.opts.fontFamily || msg.opts.fontSize || msg.opts.lineHeight) {
          // **모듈 변수 `metrics` 도 함께 갱신한다.** `sizeCanvas()` 가 이 값으로 backing 을
          // 잡고 `renderer.attach()` 로 렌더러 metrics 까지 덮어쓰므로, 여기서 안 바꾸면
          // 다음 resize 가 방금의 setMetrics 를 되돌린다(폰트 줌이 워커에서만 깨졌다).
          metrics = measureMetrics({
            fontFamily: opts.fontFamily,
            fontSize: opts.fontSize,
            lineHeight: opts.lineHeight,
            devicePixelRatio: opts.devicePixelRatio,
          });
          renderer.setMetrics(metrics);
          if (lastSize) sizeCanvas(lastSize.cols, lastSize.rows);
        }
        redraw();
        return;
      }
      case "blink":
        blinkOn = msg.on;
        redraw();
        return;
      case "preedit":
        // 오버레이(하이라이트·밑줄)는 항상 그린다. 코어 삽입은 앱이 조합을 직접 그리지
        // 않을 때만 한다 — 앱이 줄을 다시 그리는데 라이브러리도 화면을 건드리면 어긋난다.
        preedit = msg.text;
        if (msg.insert) backend?.setPreedit(msg.text);
        redraw();
        return;
      case "query": {
        const b = backend;
        if (!b) {
          post({ t: "error", id: msg.id, message: "backend 없음" });
          return;
        }
        const value =
          msg.kind === "measureCells"
            ? await b.measureCells(msg.arg as string)
            : msg.kind === "snapshot"
              ? await b.snapshot()
              : msg.kind === "selectionText"
                ? await b.selectionText()
                : msg.kind === "find"
                  ? await b.find(msg.arg as string)
                  : msg.kind === "cursorAtPrompt"
                    ? await b.cursorAtPrompt()
                    : msg.kind === "serialize"
                      ? await b.serialize()
                      : await b.linkAt(...(msg.arg as [number, number]));
        post({ t: "reply", id: msg.id, value });
        return;
      }
      case "dispose":
        backend?.dispose();
        backend = null;
        renderer.dispose();
        return;
    }
  } catch (e) {
    // **`id` 를 함께 싣는다.** 조회(`query`)도 이 try 안에서 await 하는데 id 없이 보내면
    // 프록시가 짝지을 대상을 못 찾아(`#pending` 에 그대로 남는다) 그 promise 가 영원히
    // 안 풀린다 — Cmd+C 가 아무 말 없이 안 되고, hover 마다 거는 `linkAt` 이 쌓여 샌다.
    const id = (msg as { id?: number }).id;
    post({ t: "error", id, message: e instanceof Error ? e.message : String(e) });
  }
};
