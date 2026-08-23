import type { Backend, BackendEvent, FindResult, FrameData, MouseReport } from "../backend/types";
import type { FrameMeta } from "../types";
import type { CursorShape, KeyInput, Size, Snapshot, Theme } from "../types";
import type { FromWorker, ToWorker, WorkerRenderOptions } from "./protocol";
import { defaultWasmUrl } from "../wasm/loader";

/**
 * 워커에 있는 코어의 **메인 쪽 대리인**(`worker: "full"`). 명령은 그대로 넘기고, 조회는
 * `id`로 응답을 짝짓는다. `Terminal`은 이게 프록시인지 로컬인지 모른다 — 같은 `Backend`다.
 *
 * 프레임은 여기로 오지 않는다. 워커가 OffscreenCanvas에 직접 그리므로 셀 버퍼를 되돌릴
 * 이유가 없다(그게 `"full"` 모드의 요점이다).
 */
export class WorkerBackend implements Backend {
  #worker: Worker;
  #cb: ((e: BackendEvent) => void) | null = null;
  /** 프레임 요약 수신자(셀은 오지 않는다). */
  #onRendered: ((m: FrameMeta) => void) | null = null;
  onRendered(cb: (m: FrameMeta) => void): void {
    this.#onRendered = cb;
  }

  #pending = new Map<number, { resolve: (v: unknown) => void; reject: (e: Error) => void }>();
  #nextId = 1;
  #ready: Promise<void>;

  private constructor(worker: Worker, ready: Promise<void>) {
    this.#worker = worker;
    this.#ready = ready;
  }

  static async create(
    canvas: OffscreenCanvas,
    size: Size,
    opts: WorkerRenderOptions,
    wasmUrl?: string | URL,
    fontUrl?: string,
    loadFont?: boolean,
  ): Promise<WorkerBackend> {
    const worker = new Worker(new URL("./entry.js", import.meta.url), { type: "module" });
    let resolveReady!: () => void;
    let rejectReady!: (e: Error) => void;
    const ready = new Promise<void>((res, rej) => {
      resolveReady = res;
      rejectReady = rej;
    });
    const self = new WorkerBackend(worker, ready);

    worker.onmessage = (ev: MessageEvent<FromWorker>) => {
      const msg = ev.data;
      if (msg.t === "ready") {
        resolveReady();
        return;
      }
      if (msg.t === "rendered") {
        self.#onRendered?.(msg.meta);
        return;
      }
      if (msg.t === "event") {
        self.#cb?.(msg.event);
        return;
      }
      if (msg.t === "reply") {
        self.#pending.get(msg.id)?.resolve(msg.value);
        self.#pending.delete(msg.id);
        return;
      }
      const err = new Error(`maru-term(worker): ${msg.message}`);
      if (msg.id !== undefined) {
        self.#pending.get(msg.id)?.reject(err);
        self.#pending.delete(msg.id);
      } else {
        rejectReady(err);
      }
    };
    worker.onerror = (e) => rejectReady(new Error(`maru-term(worker): ${e.message}`));

    // canvas 소유권을 워커로 **이전**한다 — 이 시점부터 메인은 그 캔버스에 못 그린다.
    worker.postMessage(
      {
        t: "init",
        canvas,
        size,
        // **메인이 절대 URL 로 확정해 넘긴다.** 번들러가 워커 청크의 `import.meta.url` 을
        // 빈 문자열로 치환하는 경우가 있어(실측: zntc), 워커가 스스로 기본 경로를 만들면
        // `new URL("../wasm/…", "")` 가 되어 통째로 실패한다.
        wasmUrl: String(wasmUrl ?? defaultWasmUrl()),
        fontUrl,
        loadFont,
        opts,
      } satisfies ToWorker,
      [canvas],
    );
    await ready;
    return self;
  }

  #send(msg: ToWorker, transfer?: Transferable[]): void {
    this.#worker.postMessage(msg, transfer ?? []);
  }

  #query<T>(kind: Extract<ToWorker, { t: "query" }>["kind"], arg?: unknown): Promise<T> {
    const id = this.#nextId++;
    return new Promise<T>((resolve, reject) => {
      this.#pending.set(id, { resolve: resolve as (v: unknown) => void, reject });
      this.#send({ t: "query", id, kind, arg });
    });
  }

  on(cb: (e: BackendEvent) => void): void {
    this.#cb = cb;
  }

  write(bytes: Uint8Array): void {
    // 복사본을 만들어 소유권을 넘긴다 — 호출자의 버퍼를 detach 하면 재사용이 깨진다.
    const copy = bytes.slice();
    this.#send({ t: "write", bytes: copy }, [copy.buffer]);
  }
  resize(cols: number, rows: number): void {
    this.#send({ t: "resize", cols, rows });
  }
  key(input: KeyInput): void {
    this.#send({ t: "key", input });
  }
  paste(text: string): void {
    this.#send({ t: "paste", text });
  }
  mouse(ev: MouseReport): void {
    this.#send({ t: "mouse", ev });
  }
  focus(gained: boolean): void {
    this.#send({ t: "focus", gained });
  }
  scroll(deltaUp: number): void {
    this.#send({ t: "scroll", deltaUp });
  }
  scrollToBottom(): void {
    this.#send({ t: "scrollBottom" });
  }

  scrollToTop(): void {
    this.#send({ t: "scrollTop" });
  }

  scrollToLine(line: number): void {
    this.#send({ t: "scrollToLine", line });
  }

  clear(): void {
    // ^L 이 필요한지는 워커 안 코어만 안다 — 판단도 거기서 하고, 필요하면 `data` 이벤트로
    // 돌아온다(이미 프록시되는 채널이다).
    this.#send({ t: "clear" });
  }

  selectStart(row: number, col: number, block: boolean): void {
    this.#send({ t: "sel", op: "start", row, col, block });
  }
  selectExtend(row: number, col: number): void {
    this.#send({ t: "sel", op: "extend", row, col });
  }
  selectWord(row: number, col: number): void {
    this.#send({ t: "sel", op: "word", row, col });
  }
  selectLine(row: number): void {
    this.#send({ t: "sel", op: "line", row });
  }
  selectAll(): void {
    this.#send({ t: "sel", op: "all" });
  }
  selectClear(): void {
    this.#send({ t: "sel", op: "clear" });
  }

  setTheme(theme: Theme): void {
    this.#send({ t: "opts", opts: { theme } });
  }
  setCursorShape(shape: CursorShape): void {
    this.#send({ t: "opts", opts: { cursorShape: shape } });
  }
  setScrollback(lines: number): void {
    this.#send({ t: "opts", opts: { scrollback: lines } });
  }
  setAmbiguousWide(on: boolean): void {
    this.#send({ t: "opts", opts: { ambiguousWide: on } });
  }
  setRenderOptions(opts: Partial<WorkerRenderOptions>): void {
    this.#send({ t: "opts", opts });
  }
  setBlink(on: boolean): void {
    this.#send({ t: "blink", on });
  }
  setPreedit(text: string, insert = true): void {
    this.#send({ t: "preedit", text, insert });
  }

  measureCells(text: string): Promise<number> {
    return this.#query("measureCells", text);
  }
  snapshot(): Promise<Snapshot> {
    return this.#query("snapshot");
  }
  selectionText(): Promise<string | null> {
    return this.#query("selectionText");
  }
  cursorAtPrompt(): Promise<boolean> {
    return this.#query("cursorAtPrompt");
  }
  find(needle: string): Promise<FindResult> {
    // 매치 배열은 구조적 복제로 온다 — 검색은 사용자 행동당 한 번이라 프레임과 달리 왕복이 싸다.
    return this.#query("find", needle);
  }
  linkAt(row: number, col: number): Promise<string | null> {
    return this.#query("linkAt", [row, col]);
  }

  dispose(): void {
    this.#send({ t: "dispose" });
    this.#worker.terminate();
    this.#cb = null;
    for (const p of this.#pending.values()) p.reject(new Error("maru-term: 터미널이 dispose됐다"));
    this.#pending.clear();
  }

  /** 워커 모드에서는 프레임이 메인으로 오지 않는다. */
  get frame(): FrameData | null {
    return null;
  }
  get ready(): Promise<void> {
    return this.#ready;
  }
}

/** 이 환경에서 `"full"` 모드가 가능한가. */
export function canUseWorker(): boolean {
  return typeof Worker !== "undefined" && typeof OffscreenCanvas !== "undefined";
}
