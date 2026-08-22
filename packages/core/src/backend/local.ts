import { wasmGlyphSource } from "../render/glyphs";
import type { GlyphSource } from "../render/types";
import { CELL_STRIDE, type WasmExports } from "../wasm/exports";
import { instantiate } from "../wasm/loader";
import type { Cell, CursorShape, CursorState, KeyInput, Size, Snapshot, Theme } from "../types";
import {
  type Backend,
  type BackendEvent,
  type FrameData,
  KeyKind,
  type MouseReport,
  modsOf,
  type SelectionSpan,
} from "./types";

const CURSOR_SHAPES: CursorShape[] = ["block", "underline", "bar"];
const encoder = new TextEncoder();
const decoder = new TextDecoder();

/**
 * wasm을 **같은 스레드에서** 소유하는 백엔드. `worker: false`가 이걸 메인에서 쓰고,
 * `worker: "full"`은 워커 안에서 같은 클래스를 쓴다 — 두 모드가 코드를 공유한다.
 */
export class LocalBackend implements Backend {
  #w: WasmExports;
  /** 입력 버퍼 용량. wasm 이 정한다 — TS 에 상수로 복제하면 어긋난다. */
  readonly #inputCap: number;
  /** 마지막으로 알린 모드. 바뀔 때만 이벤트를 낸다. */
  #lastModes = -1;
  /** 화면에 들어가 있는 조합 텍스트의 셀 폭. 되돌릴 때 이만큼만 지운다. */
  #preeditCells = 0;
  #h: number;
  #cb: ((e: BackendEvent) => void) | null = null;
  #size: Size;
  #title = "";
  #flushQueued = false;
  #disposed = false;

  private constructor(w: WasmExports, h: number, size: Size) {
    this.#w = w;
    this.#inputCap = w.input_cap();
    this.#h = h;
    this.#size = size;
  }

  static async create(size: Size, wasmUrl?: string | URL): Promise<LocalBackend> {
    const w = await instantiate(wasmUrl);
    const h = w.vt_new(size.cols, size.rows);
    if (h === 0) throw new Error("maru-term: TerminalCore를 만들지 못했다 (메모리 부족)");
    return new LocalBackend(w, h, { ...size });
  }

  on(cb: (e: BackendEvent) => void): void {
    this.#cb = cb;
  }

  // ── 입력 ─────────────────────────────────────────────────
  /** 박스 드로잉 등을 폰트 없이 그리기 위한 커버리지 공급자. */
  glyphSource(): GlyphSource {
    return wasmGlyphSource(this.#w);
  }

  write(bytes: Uint8Array): void {
    if (this.#disposed) return;
    this.#writeRaw(bytes);
    this.#drainResponse();
    this.#markDirty();
  }

  /**
   * 입력 버퍼에 바이트를 놓는 **유일한 통로**. 넘치는 만큼 잘라 낸 길이를 돌려준다.
   *
   * 이 검사가 없으면 `new Uint8Array(memory, ptr, len).set(bytes)` 가 예외 없이 인접 정적
   * 버퍼(`cell_buf` 등)를 덮어쓴다 — 선형 메모리는 넉넉하고 wasm 은 ReleaseSmall 이라 트랩도
   * 없다. 200 KB 붙여넣기가 스냅샷 버퍼를 밟는 경로가 실제로 있었다.
   */
  #stage(bytes: Uint8Array): number {
    const cap = this.#inputCap;
    const n = Math.min(bytes.length, cap);
    new Uint8Array(this.#w.memory.buffer, this.#w.input_ptr(), n).set(bytes.subarray(0, n));
    return n;
  }

  #writeRaw(bytes: Uint8Array): void {
    // 버퍼보다 크면 나눠 넣는다 — write 는 순수 바이트 스트림이라 나눠도 결과가 같다.
    const cap = this.#inputCap;
    for (let off = 0; off < bytes.length; off += cap) {
      const n = this.#stage(bytes.subarray(off, Math.min(off + cap, bytes.length)));
      this.#w.vt_write(this.#h, n);
    }
  }

  key(input: KeyInput): void {
    if (this.#disposed) return;
    const cp = input.key === "f" ? (input.fn ?? 1) : (input.codepoint ?? 0);
    const n = this.#w.vt_key(this.#h, KeyKind[input.key], cp, modsOf(input));
    if (n > 0) this.#emitData(this.#read(this.#w.key_ptr(), n));
    this.#w.vt_scroll_bottom(this.#h); // 타이핑하면 바닥으로 — 실제 터미널 동작
    this.#markDirty();
  }

  paste(text: string): void {
    if (this.#disposed) return;
    const bytes = encoder.encode(text);
    // **붙여넣기는 나눌 수 없다** — `vt_paste` 가 bracketed 마커로 한 번 감싸므로 청킹하면
    // 마커가 여러 번 붙는다. 버퍼를 넘으면 잘라 넣고 알린다(조용히 흘리지 않는다).
    if (bytes.length > this.#inputCap) {
      console.warn(
        `maru-term: 붙여넣기가 입력 버퍼를 넘어 잘렸다 — ${bytes.length} → ${this.#inputCap} 바이트`,
      );
    }
    const n = this.#w.vt_paste(this.#h, this.#stage(bytes));
    if (n > 0) this.#emitData(this.#read(this.#w.paste_ptr(), n));
  }

  mouse(ev: MouseReport): void {
    if (this.#disposed) return;
    this.#w.vt_report_mouse(
      this.#h,
      ev.button,
      ev.col,
      ev.row,
      ev.pressed ? 1 : 0,
      ev.motion ? 1 : 0,
      ev.mods,
    );
    this.#drainResponse();
  }

  focus(gained: boolean): void {
    if (this.#disposed) return;
    this.#w.vt_report_focus(this.#h, gained ? 1 : 0);
    this.#drainResponse();
  }

  // ── 그리드 ───────────────────────────────────────────────
  resize(cols: number, rows: number): void {
    if (this.#disposed || (cols === this.#size.cols && rows === this.#size.rows)) return;
    this.#w.vt_resize(this.#h, cols, rows);
    this.#size = { cols, rows };
    this.#cb?.({ type: "resize", size: { cols, rows } });
    this.#markDirty();
  }

  scroll(deltaUp: number): void {
    if (this.#disposed) return;
    this.#w.vt_scroll(this.#h, deltaUp);
    this.#markDirty();
  }

  scrollToBottom(): void {
    if (this.#disposed) return;
    this.#w.vt_scroll_bottom(this.#h);
    this.#markDirty();
  }

  // ── 선택 ─────────────────────────────────────────────────
  selectStart(row: number, col: number, block: boolean): void {
    // **순서가 중요하다**: start가 block 플래그를 false로 리셋하므로 block은 그 뒤여야 한다.
    this.#w.sel_start(this.#h, row, col);
    if (block) this.#w.sel_block(this.#h, 1);
    this.#markDirty();
  }
  selectExtend(row: number, col: number): void {
    this.#w.sel_extend(this.#h, row, col);
    this.#markDirty();
  }
  selectWord(row: number, col: number): void {
    this.#w.sel_word(this.#h, row, col);
    this.#markDirty();
  }
  selectLine(row: number): void {
    this.#w.sel_line(this.#h, row);
    this.#markDirty();
  }
  selectAll(): void {
    this.#w.sel_all(this.#h);
    this.#markDirty();
  }
  selectClear(): void {
    this.#w.sel_clear(this.#h);
    this.#markDirty();
  }

  // ── 설정 ─────────────────────────────────────────────────
  setTheme(theme: Theme): void {
    this.#w.vt_set_default_colors(this.#h, theme.foreground, theme.background);
    for (let i = 0; i < 16; i++) {
      const c = theme.palette?.[i];
      this.#w.vt_palette_slot(i, c ?? 0, c === undefined ? 0 : 1);
    }
    this.#w.vt_apply_palette(this.#h);
    this.#markDirty();
  }

  setCursorShape(shape: CursorShape): void {
    this.#w.vt_set_cursor_shape(this.#h, Math.max(0, CURSOR_SHAPES.indexOf(shape)));
    this.#markDirty();
  }

  setScrollback(lines: number): void {
    this.#w.vt_set_max_scrollback(this.#h, lines);
  }

  setAmbiguousWide(on: boolean): void {
    this.#w.vt_set_ambiguous_wide(this.#h, on ? 1 : 0);
    this.#markDirty();
  }

  /**
   * IME 조합 텍스트를 **화면에 실제로 넣는다**. 오버레이로 덮어 그리기만 하면 커서 뒤 글자가
   * 가려질 뿐 밀리지 않아, 조합 중에 뒤 텍스트가 사라진 것처럼 보인다.
   *
   * ICH(`CSI n @`)로 자리를 밀어내고 쓰고, 다음 갱신 때 커서를 되돌린 뒤 DCH(`CSI n P`)로
   * 지운다 — 삽입한 만큼만 정확히 되돌리므로 원래 줄이 그대로 남는다.
   */
  setPreedit(text: string, insert = true): void {
    if (!insert) {
      // 앱이 직접 그린다 — 화면은 건드리지 않고, 남아 있던 삽입만 물린다.
      if (this.#preeditCells > 0) {
        this.#writeText(`\x1b[${this.#preeditCells}D\x1b[${this.#preeditCells}P`);
        this.#preeditCells = 0;
      }
      this.#markDirty();
      return;
    }
    if (this.#preeditCells > 0) {
      this.#writeText(`\x1b[${this.#preeditCells}D\x1b[${this.#preeditCells}P`);
      this.#preeditCells = 0;
    }
    if (text) {
      const cells = this.#measureSync(text);
      if (cells > 0) {
        this.#writeText(`\x1b[${cells}@${text}`);
        this.#preeditCells = cells;
      }
    }
    this.#markDirty();
  }

  #writeText(s: string): void {
    this.write(encoder.encode(s));
  }

  #measureSync(text: string): number {
    return this.#w.measure_cells(this.#stage(encoder.encode(text)));
  }

  // ── 조회 ─────────────────────────────────────────────────
  measureCells(text: string): Promise<number> {
    return Promise.resolve(this.#measureSync(text));
  }

  snapshot(): Promise<Snapshot> {
    const frame = this.#frame();
    const cells: Cell[] = [];
    const dv = new DataView(frame.cells.buffer, frame.cells.byteOffset, frame.cells.byteLength);
    for (let i = 0; i < frame.cellCount; i++) {
      const o = i * CELL_STRIDE;
      cells.push({
        codepoint: dv.getUint32(o, true),
        fg: dv.getUint32(o + 4, true),
        bg: dv.getUint32(o + 8, true),
        flags: dv.getUint32(o + 12, true),
        link: dv.getUint32(o + 16, true),
      });
    }
    return Promise.resolve({ size: frame.size, cursor: frame.cursor, cells });
  }

  selectionText(): Promise<string | null> {
    // 셀에서 재구성하지 않는다 — 코어가 grapheme cluster 와 soft-wrap 이음을 풀어 주고,
    // 선택 span 의 경계 규약(inclusive)도 코어 쪽이 단일 출처다.
    const n = this.#w.sel_text(this.#h);
    if (n === 0) return Promise.resolve(null);
    return Promise.resolve(decoder.decode(this.#read(this.#w.paste_ptr(), n)));
  }

  linkAt(row: number, col: number): Promise<string | null> {
    const frame = this.#frame();
    const i = row * frame.size.cols + col;
    if (i < 0 || i >= frame.cellCount) return Promise.resolve(null);
    const dv = new DataView(frame.cells.buffer, frame.cells.byteOffset, frame.cells.byteLength);
    const id = dv.getUint32(i * CELL_STRIDE + 16, true);
    if (id === 0) return Promise.resolve(null);
    const n = this.#w.link_uri(this.#h, id);
    return Promise.resolve(n === 0 ? null : decoder.decode(this.#read(this.#w.link_ptr(), n)));
  }

  dispose(): void {
    if (this.#disposed) return;
    this.#disposed = true;
    this.#w.vt_free(this.#h);
    this.#cb = null;
  }

  // ── 내부 ─────────────────────────────────────────────────
  /** wasm 메모리를 **복사해서** 돌려준다 — 다음 호출이 같은 버퍼를 덮으므로 빌려주면 안 된다. */
  #read(ptr: number, len: number): Uint8Array {
    return new Uint8Array(this.#w.memory.buffer, ptr, len).slice();
  }

  #emitData(bytes: Uint8Array): void {
    if (bytes.length > 0) this.#cb?.({ type: "data", bytes });
  }

  /**
   * 호스트로 보낼 응답을 비운다. **이걸 안 하면 TUI가 멈춘다** — DA·CPR·OSC 색상 질의에
   * 답이 안 가면 앱이 응답을 기다리며 진행하지 않는다.
   */
  #drainResponse(): void {
    const n = this.#w.vt_response(this.#h);
    if (n > 0) {
      this.#emitData(this.#read(this.#w.resp_ptr(), n));
      this.#w.vt_clear_response(this.#h);
    }
    const t = this.#w.vt_title(this.#h);
    if (t > 0) {
      const title = decoder.decode(this.#read(this.#w.link_ptr(), t));
      if (title !== this.#title) {
        this.#title = title;
        this.#cb?.({ type: "title", title });
      }
    }
    if (this.#w.vt_take_bell(this.#h) === 1) this.#cb?.({ type: "bell" });
  }

  /** 프레임 발행을 마이크로태스크로 접는다 — 한 tick에 write가 여러 번 와도 한 번만 그린다. */
  #markDirty(): void {
    // 모드가 바뀌면 알린다 — DOM 층이 마우스 추적 여부를 동기로 판단해야 한다.
    const modes = this.#w.vt_modes(this.#h);
    if (modes !== this.#lastModes) {
      this.#lastModes = modes;
      this.#cb?.({ type: "modes", value: modes });
    }
    if (this.#flushQueued || this.#disposed) return;
    this.#flushQueued = true;
    queueMicrotask(() => {
      this.#flushQueued = false;
      if (!this.#disposed) this.#cb?.({ type: "render", frame: this.#frame() });
    });
  }

  #selection(): SelectionSpan | null {
    if (this.#w.sel_span(this.#h) === 0) return null;
    const a = new Uint32Array(this.#w.memory.buffer, this.#w.sel_ptr(), 5);
    return { startRow: a[0]!, startCol: a[1]!, endRow: a[2]!, endCol: a[3]!, block: a[4] === 1 };
  }

  #cursor(): CursorState {
    const pos = this.#w.vt_cursor(this.#h);
    const style = this.#w.vt_cursor_style(this.#h);
    return {
      row: pos >>> 16,
      col: pos & 0xffff,
      shape: CURSOR_SHAPES[style & 0xff] ?? "block",
      blink: ((style >> 8) & 1) === 1,
      visible: ((style >> 9) & 1) === 1,
    };
  }

  #frame(): FrameData {
    const count = this.#w.vt_snapshot(this.#h);
    const scroll = this.#w.vt_scroll_state(this.#h);
    return {
      size: { ...this.#size },
      cursor: this.#cursor(),
      cells: this.#read(this.#w.cells_ptr(), count * CELL_STRIDE),
      cellCount: count,
      selection: this.#selection(),
      scroll: { offset: scroll >>> 16, length: scroll & 0xffff },
      modes: this.#w.vt_modes(this.#h),
    };
  }
}
