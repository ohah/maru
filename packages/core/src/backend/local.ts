import { wasmGlyphSource } from "../render/glyphs";
import type { GlyphSource } from "../render/types";
import { CELL_STRIDE, type WasmExports } from "../wasm/exports";
import { instantiate } from "../wasm/loader";
import type { Cell, CursorShape, CursorState, KeyInput, Size, Snapshot, Theme } from "../types";
import {
  type Backend,
  type BackendEvent,
  type FindResult,
  type FrameData,
  KeyKind,
  type Match,
  type MouseReport,
  modsOf,
  type SelectionSpan,
  type ShellEvent,
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
  /** 스냅샷 셀 상한. 격자가 넘으면 아래쪽이 잘린다. */
  readonly #cellsCap: number;
  /** `measure_cells` 의 '셀 수 없음' 신호. */
  readonly #measureOverflow: number;
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
    this.#cellsCap = w.cells_cap();
    this.#measureOverflow = w.measure_overflow_value() >>> 0;
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
  /** 스냅샷이 담을 수 있는 셀 수. `fit()` 이 격자를 여기에 맞춘다. */
  cellsCap(): number {
    return this.#cellsCap;
  }

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
      // 실패(1)를 흘리면 PTY 출력 한 덩어리가 조용히 사라지고 TUI 화면이 반쯤 그려진다.
      if (this.#w.vt_write(this.#h, n) !== 0) {
        console.warn("maru-term: 코어가 write 를 거절했다 — 출력 일부가 유실됐다");
        return;
      }
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
    // **반환값을 본다.** 0=성공·1=실패다. 실패했는데 `#size` 를 바꾸면 프레임이 새 격자
    // 크기를 알리면서 셀은 옛 격자 것을 실어, 렌더러가 새 stride 로 인덱싱해 첫 줄은 어긋나고
    // 나머지는 통째로 빈다.
    if (this.#w.vt_resize(this.#h, cols, rows) !== 0) {
      console.warn(`maru-term: 코어가 ${cols}×${rows} 리사이즈를 거절했다 — 격자를 유지한다`);
      // **실제 크기를 다시 알린다.** 호출자는 캔버스를 먼저 잡으려고 낙관적으로 갱신하므로,
      // 거절을 알리지 않으면 그 값이 잘못된 채 남아 프레임 크기와 셀이 어긋난다.
      this.#cb?.({ type: "resize", size: { ...this.#size } });
      return;
    }
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

  scrollToTop(): void {
    if (this.#disposed) return;
    // 코어에는 상대 스크롤만 있다 — 남은 만큼 위로 민다(코어가 [0, sb.count] 로 clamp).
    this.#w.vt_scroll(this.#h, this.#w.vt_scrollback_len(this.#h));
    this.#markDirty();
  }

  scrollToLine(line: number): void {
    if (this.#disposed) return;
    // `line` 은 스크롤백 최상단이 0 인 절대 행. offset 은 바닥 기준이라 방향이 반대다.
    const want = this.#w.vt_scrollback_len(this.#h) - Math.max(0, Math.trunc(line));
    this.#w.vt_scroll(this.#h, want - this.#w.vt_view_offset(this.#h));
    this.#markDirty();
  }

  clear(): void {
    if (this.#disposed) return;
    // 반환 1 = 프롬프트 상태라 전체를 비우고 커서를 홈에 뒀다. 셸이 ^L 로 프롬프트를 다시
    // 그려야 화면이 완성된다 — 우리는 PTY 를 모르므로 호스트에게 바이트로 넘긴다.
    if (this.#w.vt_clear(this.#h) === 1) {
      this.#cb?.({ type: "data", bytes: new Uint8Array([0x0c]) });
    }
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
   * IME 조합 텍스트. **화면 버퍼는 건드리지 않는다** — 렌더러가 커서 자리에 그리고 뒤 셀을
   * 밀어 그린다(`render/canvas.ts`).
   *
   * 예전에는 `ICH`/`DCH` 로 코어에 넣었는데, 화면을 소유한 앱과 어긋난다: zsh 는 프롬프트와
   * 입력줄을 자기가 관리하므로 우리가 끼어들면 그 다음 앱이 그릴 때 엉뚱한 자리를 밟는다
   * (실측: `echo ` 뒤에 조합을 시작하자 "ec" 가 지워졌다). 줄을 스스로 다시 그리는 앱은
   * `onPreedit` 를 구독해 자기 줄에 넣으면 된다.
   */
  setPreedit(_text: string, _insert = true): void {
    this.#markDirty();
  }

  #writeText(s: string): void {
    this.write(encoder.encode(s));
  }

  #measureSync(text: string): number {
    const n = this.#w.measure_cells(this.#stage(encoder.encode(text))) >>> 0;
    // probe 를 넘겼다 — 폭을 셀 수 없다. 0 으로 접어 호출자가 커서 이동을 시도하지 않게 한다
    // (틀린 수를 돌려주면 CUB 가 어긋나 커서가 프롬프트 한가운데로 떨어진다).
    if (n === this.#measureOverflow) {
      console.warn("maru-term: 측정 한계를 넘는 텍스트 — 폭을 셀 수 없다");
      return 0;
    }
    return n;
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

  find(needle: string): Promise<FindResult> {
    if (this.#disposed || needle.length === 0) return Promise.resolve({ matches: [], total: 0 });
    const n = this.#stage(encoder.encode(needle));
    const total = this.#w.vt_find(this.#h, n);
    const kept = Math.min(total, this.#w.matches_cap());
    // u32 뷰로 읽는다 — 한 건이 넷이다. 버퍼는 다음 호출에서 덮이므로 여기서 복사한다.
    const raw = new Uint32Array(this.#w.memory.buffer, this.#w.match_ptr(), kept * 4);
    const matches: Match[] = [];
    for (let i = 0; i < kept; i++) {
      matches.push({
        startRow: raw[i * 4],
        startCol: raw[i * 4 + 1],
        endRow: raw[i * 4 + 2],
        endCol: raw[i * 4 + 3],
      });
    }
    return Promise.resolve({ matches, total });
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
    this.#drainOsc();
  }

  /**
   * OSC 로 들어온 요청을 알리고 비운다. **라이브러리는 클립보드도 알림도 직접 만지지 않는다** —
   * 브라우저에서 임의의 셸 스크립트가 사용자 클립보드를 읽거나 덮어쓸 수 있으면 안 되므로,
   * 정책은 소비자가 정한다(계약 §7).
   */
  #drainOsc(): void {
    const clipLen = this.#w.vt_clipboard_write_len(this.#h);
    if (clipLen > 0) {
      // 최대 16 MB 라 코어 버퍼를 그대로 읽는다 — 복사는 소비자가 문자열을 만들 때 한 번만.
      const text = decoder.decode(
        new Uint8Array(this.#w.memory.buffer, this.#w.vt_clipboard_write_ptr(this.#h), clipLen),
      );
      this.#w.vt_clear_clipboard_write(this.#h);
      this.#cb?.({ type: "clipboard-write", text });
    }
    if (this.#w.vt_take_clipboard_rejected(this.#h) === 1) {
      this.#cb?.({ type: "clipboard-rejected" });
    }
    if (this.#w.vt_clipboard_read_pending(this.#h) === 1) {
      const n = this.#w.vt_clipboard_read_target(this.#h);
      const target = decoder.decode(this.#read(this.#w.link_ptr(), n));
      this.#w.vt_clear_clipboard_read(this.#h); // 알린 뒤 비운다 — 다음 tick 에 또 트리거되면 안 된다
      this.#cb?.({ type: "clipboard-read", target });
    }
    // **부호에 주의한다.** wasm `i32` 는 JS 에서 부호 있는 수로 온다 — `0xffff_ffff` 는 `-1` 로
    // 도착하므로 그냥 비교하면 "알림 없음"이 늘 통과해 버린다. 그러면 titleLen 이 65535 가 돼
    // `link_buf`(2048) 를 넘어 읽고 빈 문자열 알림이 매 write 마다 나간다(실제로 그랬다).
    const note = this.#w.vt_notification(this.#h) >>> 0;
    if (note !== 0xffffffff) {
      const titleLen = note >>> 16;
      const bodyLen = note & 0xffff;
      const buf = this.#read(this.#w.link_ptr(), titleLen + bodyLen);
      const title = decoder.decode(buf.subarray(0, titleLen));
      const body = decoder.decode(buf.subarray(titleLen));
      this.#w.vt_clear_notification(this.#h);
      this.#cb?.({ type: "notification", title, body });
    }
    const evCount = this.#w.vt_take_shell_events(this.#h);
    if (evCount > 0) {
      const raw = new Uint32Array(this.#w.memory.buffer, this.#w.match_ptr(), evCount * 4);
      for (let i = 0; i < evCount; i++) {
        const kind = raw[i * 4];
        const row = raw[i * 4 + 1];
        const rawExit = raw[i * 4 + 2];
        const hasExit = raw[i * 4 + 3] === 1;
        const ev: ShellEvent =
          kind === 0
            ? { kind: "prompt-start", row }
            : kind === 1
              ? { kind: "input-start", row }
              : kind === 2
                ? { kind: "command-start", row }
                : kind === 3
                  ? // 유무를 별도 칸으로 받는다 — 값으로 가르면 종료 코드 -1 이 "없음"과 겹친다.
                    { kind: "command-end", row, exit: hasExit ? rawExit | 0 : null }
                  : { kind: "cwd-changed" };
        this.#cb?.({ type: "shell", event: ev });
        // cwd 는 사건이 아니라 상태다 — 값은 `currentCwd()` 가 권위이므로 그때 읽는다.
        if (ev.kind === "cwd-changed") {
          const n = this.#w.vt_cwd(this.#h);
          this.#cb?.({ type: "cwd", cwd: decoder.decode(this.#read(this.#w.link_ptr(), n)) });
        }
      }
    }
  }

  serialize(): Promise<string> {
    if (this.#disposed) return Promise.resolve("");
    const n = this.#w.vt_serialize(this.#h);
    return Promise.resolve(decoder.decode(this.#read(this.#w.cells_ptr(), n)));
  }

  cursorAtPrompt(): Promise<boolean> {
    if (this.#disposed) return Promise.resolve(false);
    return Promise.resolve(this.#w.vt_cursor_at_prompt(this.#h) === 1);
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
    return {
      size: { ...this.#size },
      cursor: this.#cursor(),
      cells: this.#read(this.#w.cells_ptr(), count * CELL_STRIDE),
      cellCount: count,
      selection: this.#selection(),
      scroll: {
        offset: this.#w.vt_view_offset(this.#h),
        length: this.#w.vt_scrollback_len(this.#h),
      },
      modes: this.#w.vt_modes(this.#h),
    };
  }
}
