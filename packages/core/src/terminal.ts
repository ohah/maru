import { LocalBackend } from "./backend/local";
import type { FindResult, ShellEvent } from "./backend/types";
import type { GlyphSource } from "./render/types";
import { loadBundledFont } from "./font";
import { attachDom, type DomHost } from "./dom/attach";
import { canUseWorker, WorkerBackend } from "./worker/proxy";
import { DEFAULT_FONT } from "./render/metrics";
import type { Backend, BackendEvent, FrameData, MouseReport } from "./backend/types";
import type {
  CursorShape,
  CursorState,
  Disposable,
  FallbackReason,
  FrameMeta,
  KeyInput,
  Size,
  Snapshot,
  TerminalOptions,
  Theme,
} from "./types";

const DEFAULTS = { cols: 80, rows: 24, scrollback: 1000 } as const;

/** 선택 영역 동일성. 둘 다 없으면 같고, 한쪽만 없으면 다르다. */
function sameSelection(a: FrameMeta["selection"], b: FrameMeta["selection"]): boolean {
  if (a === null || b === null) return a === b;
  return (
    a.startRow === b.startRow &&
    a.startCol === b.startCol &&
    a.endRow === b.endRow &&
    a.endCol === b.endCol
  );
}
const DEFAULT_THEME: Theme = { foreground: 0xc9d1d9, background: 0x000000, cursor: 0x58a6ff };

type Listener<T> = (value: T) => void;

class Emitter<T> {
  #listeners = new Set<Listener<T>>();
  get size(): number {
    return this.#listeners.size;
  }
  on(cb: Listener<T>): Disposable {
    this.#listeners.add(cb);
    return { dispose: () => this.#listeners.delete(cb) };
  }
  emit(value: T): void {
    for (const cb of this.#listeners) cb(value);
  }
  clear(): void {
    this.#listeners.clear();
  }
}

/**
 * 터미널 하나. **명령은 단방향(동기), 조회는 항상 Promise**다 — 코어가 메인에 있든 워커에
 * 있든 시그니처가 같아야 모드를 바꿔도 앱 코드가 안 바뀐다.
 *
 * `onData`가 이 클래스의 출력이다. 키 입력뿐 아니라 **DA·CPR·OSC 질의 응답도 같은 경로**로
 * 나가므로, 소비자는 그 바이트를 반드시 호스트로 보내야 한다(안 보내면 TUI가 멈춘다).
 */
export class Terminal {
  #opts: TerminalOptions;
  #backend: Backend | null = null;
  #size: Size;
  #frame: FrameData | null = null;
  #dom: DomHost | null = null;
  /** cols/rows 를 명시하지 않았을 때만 컨테이너 크기를 따라간다. */
  #resizeObserver: ResizeObserver | null = null;
  /** 코어가 알려 준 `vt_modes`. DOM 층이 마우스 추적을 동기로 판단한다. */
  #modes = 0;
  /** Cmd+0 으로 되돌아갈 크기. */
  readonly #baseFontSize: number;
  #disposed = false;

  readonly #data = new Emitter<Uint8Array>();
  readonly #title = new Emitter<string>();
  readonly #bell = new Emitter<void>();
  readonly #preedit = new Emitter<string>();
  readonly #resize = new Emitter<Size>();
  readonly #fallback = new Emitter<FallbackReason>();
  readonly #render = new Emitter<FrameMeta>();
  readonly #cursorMove = new Emitter<CursorState>();
  readonly #clipboardWrite = new Emitter<string>();
  readonly #clipboardRead = new Emitter<string>();
  readonly #clipboardRejected = new Emitter<void>();
  readonly #notification = new Emitter<{ title: string; body: string }>();
  readonly #cwd = new Emitter<string>();
  readonly #shell = new Emitter<ShellEvent>();
  readonly #scrollEv = new Emitter<FrameMeta["scroll"]>();
  readonly #selectionChange = new Emitter<FrameMeta["selection"]>();
  /** 직전 프레임 — 상태 이벤트는 여기서 파생한다(셀은 없으므로 들고 있어도 가볍다). */
  #prevMeta: FrameMeta | null = null;

  constructor(opts: TerminalOptions = {}) {
    this.#opts = { ...opts };
    this.#size = { cols: opts.cols ?? DEFAULTS.cols, rows: opts.rows ?? DEFAULTS.rows };
    this.#baseFontSize = opts.fontSize ?? 14;
  }

  /** 코어의 현재 모드 비트(`vt_modes`). 마우스 추적 판단에 쓴다. */
  get modes(): number {
    return this.#modes;
  }

  get size(): Size {
    return { ...this.#size };
  }

  /** 마지막으로 발행된 프레임. 렌더러가 붙기 전에도 읽을 수 있다. */
  /**
   * 마지막 프레임(셀 포함). **`worker: false` 에서만 유효하다** — 워커 모드에서는 셀이 워커
   * 메모리에 있고 동기로 읽을 방법이 없어(SharedArrayBuffer 를 쓰지 않는다) 항상 `null` 이다.
   * 화면 내용이 필요하면 `snapshot()` 을, 갱신 알림만 필요하면 `onRender` 를 쓴다.
   */
  get frame(): FrameData | null {
    return this.#frame;
  }

  /**
   * 코어를 띄운다. **워커·wasm 생성은 전부 여기서** 한다 — 모듈 로드 시점에 `Worker`나
   * `document`를 건드리면 SSR이 깨진다.
   */
  async open(el?: HTMLElement): Promise<void> {
    if (this.#backend && (!el || this.#dom)) return;

    // **워커 여부는 여기서 정한다.** 기본은 "full"이고, 명시하지 않았을 때만 능력 감지로
    // 조용히 내린다 — 명시했는데 지원이 없으면 실패시키는 편이 조용한 성능 저하보다 낫다.
    const wanted = this.#opts.worker ?? "full";
    const explicit = this.#opts.worker !== undefined;
    let mode: "full" | false = wanted;
    if (wanted !== false && !canUseWorker()) {
      if (explicit) {
        throw new Error(
          "maru-term: 이 환경에는 Worker나 OffscreenCanvas가 없다 (worker 옵션을 빼면 자동으로 내려간다)",
        );
      }
      mode = false;
      queueMicrotask(() =>
        this.#fallback.emit(typeof Worker === "undefined" ? "no-worker" : "no-offscreen-canvas"),
      );
    }
    // 폰트를 **먼저** 받는다 — 격자를 재기 전에 등록돼 있어야 셀 크기가 그 폰트 기준으로 잡힌다.
    // **await 마다 `#disposed` 를 다시 본다.** open 은 폰트 fetch·Worker 생성·wasm
    // instantiate 로 여러 번 양보하는데, 그 사이 dispose 가 오면 그때는 아직 `#dom`·
    // `#backend` 가 null 이라 아무것도 못 푼다. 그대로 두면 이미 버려진 인스턴스에 Worker·
    // 타이머·DOM 이 붙는다(React StrictMode 는 mount→unmount→mount 라 매번 샌다).
    if (this.#disposed) return;
    if (this.#opts.loadFont === "jetendard") await loadBundledFont(this.#opts.fontUrl);
    if (this.#disposed) return;
    if (el && mode === "full") {
      await this.#openWorker(el);
      this.#startAutoFit(el);
      return;
    }

    if (!this.#backend) {
      const backend = await LocalBackend.create(this.#size, this.#opts.wasmUrl);
      if (this.#disposed) {
        backend.dispose();
        return;
      }
      backend.on((e) => this.#onBackendEvent(e));
      this.#backend = backend;
      this.#applyOptions();
    }
    if (el && !this.#dom) {
      const local = this.#backend as { glyphSource?: () => GlyphSource } | null;
      this.#dom = attachDom(el, this, {
        ...this.#attachOptions(),
        glyphs: local?.glyphSource?.() ?? null,
        onFontZoom: (d) => this.#fontZoom(d),
        // 워커 경로에만 있던 배선이다. 없으면 조합 텍스트가 화면에 들어가지 않는다.
        onPreedit: (text) => this.#emitPreedit(text),
      });
    }
    if (el) this.#startAutoFit(el);
  }

  /**
   * `cols`/`rows`를 명시하지 않았으면 컨테이너를 채운다. 컨테이너를 받는 API 이므로 그 크기를
   * 따르는 것이 기본이어야 한다 — 명시했으면 사용자가 정한 격자를 그대로 지킨다.
   */
  #startAutoFit(el: HTMLElement): void {
    if (this.#opts.autoFit === false) return;
    if (this.#opts.cols !== undefined && this.#opts.rows !== undefined) return;
    if (typeof ResizeObserver === "undefined") {
      this.fit();
      return;
    }
    this.#resizeObserver = new ResizeObserver(() => this.fit());
    this.#resizeObserver.observe(el);
    this.fit();
  }

  /** 폰트 확대·축소·되돌리기. 되돌리기는 생성 당시 크기(없으면 기본 14)로 간다. */
  #fontZoom(delta: number): void {
    const base = this.#baseFontSize;
    const cur = this.#opts.fontSize ?? base;
    const next = delta === 0 ? base : Math.max(6, Math.min(72, cur + delta));
    if (next !== cur) this.setOptions({ fontSize: next });
  }

  #attachOptions(render = true) {
    return {
      fontFamily: this.#opts.fontFamily ?? DEFAULT_FONT,
      cellsCap: (this.#backend as { cellsCap?: () => number } | null)?.cellsCap?.(),
      fontSize: this.#opts.fontSize ?? 14,
      lineHeight: this.#opts.lineHeight ?? 1.22,
      ligatures: this.#opts.ligatures ?? true,
      theme: this.#opts.theme ?? DEFAULT_THEME,
      render,
    };
  }

  /** 코어와 렌더를 모두 워커에 두고, 메인은 입력만 잡는다. */
  async #openWorker(el: HTMLElement): Promise<void> {
    let worker: WorkerBackend | null = null;
    // 캔버스를 먼저 만들어야 소유권을 넘길 수 있다. DOM 계층은 렌더를 하지 않는다.
    const dom = attachDom(el, this, {
      ...this.#attachOptions(false),
      onPreedit: (text) => this.#emitPreedit(text),
      onFontZoom: (d) => this.#fontZoom(d),
      // **지역 변수로 잡는다.** 이 콜백은 `attachDom` 안의 타이머에서 불리는데, 거기서
      // `this.#backend` 를 읽으면 항상 null 이었다(실측) — 워커 백엔드가 아래에서 나중에
      // 대입되기 때문이다. 깜빡임 신호가 통째로 워커에 닿지 않아 커서가 멈춰 있었다.
      onBlink: (on) => worker?.setBlink(on),
      onResizeCanvas: (cols, rows) => this.#backend?.resize(cols, rows),
    });
    this.#dom = dom;
    const offscreen = dom.canvas.transferControlToOffscreen();
    const backend = await WorkerBackend.create(
      offscreen,
      this.#size,
      {
        theme: this.#opts.theme ?? DEFAULT_THEME,
        ligatures: this.#opts.ligatures ?? true,
        fontFamily: this.#opts.fontFamily ?? DEFAULT_FONT,
        fontSize: this.#opts.fontSize ?? 14,
        lineHeight: this.#opts.lineHeight ?? 1.22,
        devicePixelRatio: Math.min(globalThis.devicePixelRatio || 1, 2),
        cursorShape: this.#opts.cursorShape,
        scrollback: this.#opts.scrollback ?? DEFAULTS.scrollback,
        ambiguousWide: this.#opts.ambiguousWide,
      },
      this.#opts.wasmUrl,
      // 커스텀 URL 이면 그대로 넘기고, 기본이면 워커가 스스로 Regular+Bold 를 받게 한다 —
      // 여기서 URL 하나만 넘기면 Bold 가 빠진다.
      this.#opts.fontUrl ? String(this.#opts.fontUrl) : undefined,
      this.#opts.loadFont === "jetendard" && !this.#opts.fontUrl,
    );
    backend.on((e) => this.#onBackendEvent(e));
    if (this.#disposed) {
      // 만드는 동안 버려졌다 — 붙이지 않고 바로 되돌린다.
      backend.dispose();
      dom.dispose();
      this.#dom = null;
      return;
    }
    worker = backend;
    backend.onRendered?.((meta) => this.#publishFrame(meta));
    this.#backend = backend;
  }

  /** 요소 크기에 맞춰 그리드를 다시 잡는다. `open(el)`로 붙였을 때만 유효하다. */
  fit(): void {
    this.#dom?.fit();
  }

  /** 붙은 canvas. 없으면 null. */
  get canvas(): HTMLCanvasElement | null {
    return this.#dom?.canvas ?? null;
  }

  /** 이미 만든 백엔드를 꽂는다. 워커 모드와 테스트가 쓴다. */
  attachBackend(backend: Backend): void {
    this.#backend?.dispose();
    backend.on((e) => this.#onBackendEvent(e));
    this.#backend = backend;
    this.#applyOptions();
  }

  #applyOptions(): void {
    const b = this.#backend;
    if (!b) return;
    if (this.#opts.theme) b.setTheme(this.#opts.theme);
    if (this.#opts.cursorShape) b.setCursorShape(this.#opts.cursorShape);
    if (this.#opts.ambiguousWide !== undefined) b.setAmbiguousWide(this.#opts.ambiguousWide);
    b.setScrollback(this.#opts.scrollback ?? DEFAULTS.scrollback);
  }

  #onBackendEvent(e: BackendEvent): void {
    // 백엔드가 알린 크기가 정답이다 — 낙관적으로 잡아 둔 값과 다르면 되돌린다.
    if (e.type === "resize") this.#size = { ...e.size };
    if (e.type === "modes") {
      this.#modes = e.value;
      return;
    }
    switch (e.type) {
      case "data":
        this.#data.emit(e.bytes);
        break;
      case "title":
        this.#title.emit(e.title);
        break;
      case "bell":
        this.#bell.emit();
        break;
      case "resize":
        this.#size = e.size;
        this.#resize.emit(e.size);
        break;
      case "clipboard-write":
        this.#clipboardWrite.emit(e.text);
        break;
      case "clipboard-read":
        this.#clipboardRead.emit(e.target);
        break;
      case "clipboard-rejected":
        this.#clipboardRejected.emit();
        break;
      case "notification":
        this.#notification.emit({ title: e.title, body: e.body });
        break;
      case "cwd":
        this.#cwd.emit(e.cwd);
        break;
      case "shell":
        this.#shell.emit(e.event);
        break;
      case "render":
        this.#frame = e.frame;
        this.#publishFrame({
          size: e.frame.size,
          cursor: e.frame.cursor,
          selection: e.frame.selection,
          scroll: e.frame.scroll,
        });
        break;
    }
  }

  /**
   * 프레임을 발행하고, **직전 프레임과 달라진 것만** 상태 이벤트로 낸다.
   *
   * 두 워커 모드가 여기로 수렴한다(로컬은 `render` 이벤트, 워커는 `onRendered`) — 파생을
   * 여기 한 곳에 두면 모드에 따라 이벤트가 갈리지 않는다.
   *
   * 첫 프레임은 기준선일 뿐 발행하지 않는다. 초기 상태를 "변화"로 내면 구독자가 마운트
   * 직후 무의미한 알림을 받는다.
   */
  #publishFrame(meta: FrameMeta): void {
    const prev = this.#prevMeta;
    this.#prevMeta = meta;
    if (prev) {
      // **위치만 본다.** shape·visible 은 깜빡임으로 매 프레임 토글되므로 이동으로 오해하면 안 된다.
      if (prev.cursor.row !== meta.cursor.row || prev.cursor.col !== meta.cursor.col) {
        this.#cursorMove.emit(meta.cursor);
      }
      if (prev.scroll.offset !== meta.scroll.offset || prev.scroll.length !== meta.scroll.length) {
        this.#scrollEv.emit(meta.scroll);
      }
      if (!sameSelection(prev.selection, meta.selection)) {
        this.#selectionChange.emit(meta.selection);
      }
    }
    this.#render.emit(meta);
  }

  #need(): Backend {
    if (this.#disposed) throw new Error("maru-term: 이미 dispose된 터미널이다");
    if (!this.#backend) throw new Error("maru-term: open()을 먼저 불러라");
    return this.#backend;
  }

  // ── 명령 ─────────────────────────────────────────────────
  write(data: string | Uint8Array): void {
    const bytes = typeof data === "string" ? new TextEncoder().encode(data) : data;
    this.#need().write(bytes);
  }
  resize(cols: number, rows: number): void {
    // **여기서 `#size`를 갱신해야 한다.** 워커 모드에서는 실제 리사이즈가 비동기라, 이 값을
    // 안 고치면 뒤이어 도는 `sizeCanvas()`가 옛 격자로 캔버스를 잡아 컨테이너에 여백이 남는다.
    this.#size = { cols, rows };
    this.#need().resize(cols, rows);
  }
  key(input: KeyInput): void {
    // 타이핑하면 선택이 풀린다(터미널 표준). 남겨 두면 방금 친 글자 위에 하이라이트가 얹힌다.
    const b = this.#need();
    b.selectClear();
    b.key(input);
  }
  /**
   * IME 조합 텍스트를 화면에 넣는다(빈 문자열이면 물린다). 브라우저 IME 는 `open()`이 붙인
   * 입력기가 자동으로 호출하므로 보통 직접 부를 일이 없다 — 커스텀 입력기나 모바일 조합을
   * 직접 다룰 때 쓴다. 조합 텍스트는 **호스트로 나가지 않는다**(확정된 글자만 `onData`).
   */
  setPreedit(text: string): void {
    this.#need().setPreedit(text);
  }

  /** 조합을 앱에 넘기거나(구독자 있음) 라이브러리가 직접 넣는다(구독자 없음). */
  #emitPreedit(text: string): void {
    const appDraws = this.#preedit.size > 0;
    // 오버레이는 어느 쪽이든 라이브러리가 그린다(하이라이트·밑줄). 삽입만 갈린다.
    const b = this.#backend as { setPreedit?: (t: string, insert?: boolean) => void } | null;
    b?.setPreedit?.(text, !appDraws);
    if (appDraws) this.#preedit.emit(text);
  }
  /**
   * 바이트를 그대로 호스트로 보낸다(`onData`). 키바인드처럼 **코어 인코딩을 거치지 않고**
   * 정해진 시퀀스를 보내야 할 때 쓴다. 화면에는 아무 영향이 없다 — 에코는 호스트 몫이다.
   */
  sendText(text: string | Uint8Array): void {
    this.#data.emit(typeof text === "string" ? new TextEncoder().encode(text) : text);
  }
  paste(text: string): void {
    this.#need().paste(text);
  }
  mouse(ev: MouseReport): void {
    this.#need().mouse(ev);
  }
  focus(gained: boolean): void {
    this.#need().focus(gained);
  }
  scroll(deltaUp: number): void {
    this.#need().scroll(deltaUp);
  }
  scrollToBottom(): void {
    this.#need().scrollToBottom();
  }
  /** 스크롤백 맨 위로. */
  scrollToTop(): void {
    this.#need().scrollToTop();
  }
  /** 절대 행 `line`(0 = 스크롤백 최상단)을 뷰포트 첫 줄에 둔다. */
  scrollToLine(line: number): void {
    this.#need().scrollToLine(line);
  }
  /** 양수면 아래로 — 휠 방향과 같다(`scroll()` 은 위가 양수인 코어 방향이다). */
  scrollLines(amount: number): void {
    this.#need().scroll(-amount);
  }
  /** 한 페이지 = 현재 행 수. */
  scrollPages(pages: number): void {
    this.scrollLines(pages * this.#size.rows);
  }

  /**
   * 화면을 지운다. 셸 통합(OSC 133)이 있고 프롬프트 상태이면 전체를 비우고 커서를 홈에 둔 뒤
   * `\x0c`(^L)를 `onData` 로 흘려 셸이 프롬프트를 다시 그리게 한다. 그 밖에는 커서 모델을
   * 건드리지 않도록 스크롤백과 커서 위 행만 비운다.
   */
  clear(): void {
    this.#need().clear();
  }

  /**
   * 하드 리셋(RIS). 화면·스크롤백·선택·모드·색을 초기 상태로 되돌린다.
   *
   * 전용 export 가 아니라 `ESC c` 를 흘려 보낸다 — 파서가 이미 RIS 를 `fullReset` 으로
   * 처리하므로 경로가 하나로 유지된다(앱이 보낸 RIS 와 완전히 같은 동작이다).
   */
  reset(): void {
    this.write("\x1bc");
  }

  /**
   * 스크롤백을 포함해 전부 훑는다. 좌표는 **절대 행**(0 = 스크롤백 최상단)이라 스크롤해도
   * 유효하다. 대소문자를 구분하고 정규식은 지원하지 않는다.
   *
   * `total` 이 `matches.length` 보다 클 수 있다 — 버퍼 상한(4096)을 넘긴 경우다. UI 는 그때
   * "1/2371" 처럼 총량을 보여주면 된다.
   */
  findMatches(needle: string): Promise<FindResult> {
    return this.#need().find(needle);
  }

  /**
   * 다음 매치로 이동해 선택한다. 매치가 없으면 `false`.
   *
   * 커서가 아니라 **현재 선택**을 기준으로 다음을 찾는다 — 연달아 부르면 순회한다. 끝에서는
   * 처음으로 돈다(xterm.js `findNext` 와 같다).
   */
  async findNext(needle: string): Promise<boolean> {
    return this.#findStep(needle, 1);
  }
  /** 이전 매치로. 처음에서는 끝으로 돈다. */
  async findPrevious(needle: string): Promise<boolean> {
    return this.#findStep(needle, -1);
  }

  async #findStep(needle: string, dir: 1 | -1): Promise<boolean> {
    const { matches } = await this.findMatches(needle);
    if (matches.length === 0) return false;
    const cur = this.#frame?.selection ?? null;
    let i: number;
    if (!cur) {
      i = dir === 1 ? 0 : matches.length - 1;
    } else {
      // 현재 선택과 같은 매치를 찾아 거기서 한 칸 움직인다. 선택이 매치가 아니면(사용자가
      // 드래그로 잡은 것) 그 위치를 기준으로 가장 가까운 다음/이전을 고른다.
      const at = matches.findIndex(
        (m) => m.startRow === cur.startRow && m.startCol === cur.startCol,
      );
      if (at >= 0) {
        i = (at + dir + matches.length) % matches.length;
      } else if (dir === 1) {
        const nx = matches.findIndex(
          (m) =>
            m.startRow > cur.startRow || (m.startRow === cur.startRow && m.startCol > cur.startCol),
        );
        i = nx >= 0 ? nx : 0;
      } else {
        let pv = -1;
        for (let k = 0; k < matches.length; k++) {
          const m = matches[k];
          if (
            m.startRow < cur.startRow ||
            (m.startRow === cur.startRow && m.startCol < cur.startCol)
          )
            pv = k;
        }
        i = pv >= 0 ? pv : matches.length - 1;
      }
    }
    const m = matches[i];
    // **선택은 뷰포트 행을 받는다**(코어가 안에서 절대로 바꾼다). 매치 좌표는 절대 행이므로
    // 화면에 올린 뒤 그 화면의 첫 줄을 빼야 한다.
    const len = this.#frame?.scroll.length ?? 0;
    const top = Math.min(Math.max(0, m.startRow - Math.floor(this.#size.rows / 2)), len);
    this.scrollToLine(top); // 이 뒤 화면 첫 줄의 절대 행이 곧 `top` 이다
    this.selectStart(m.startRow - top, m.startCol);
    this.selectExtend(m.endRow - top, m.endCol);
    return true;
  }

  selectStart(row: number, col: number, block = false): void {
    this.#need().selectStart(row, col, block);
  }
  selectExtend(row: number, col: number): void {
    this.#need().selectExtend(row, col);
  }
  selectWord(row: number, col: number): void {
    this.#need().selectWord(row, col);
  }
  selectLine(row: number): void {
    this.#need().selectLine(row);
  }
  selectAll(): void {
    this.#need().selectAll();
  }
  selectClear(): void {
    this.#need().selectClear();
  }

  setTheme(theme: Theme): void {
    this.#opts.theme = theme;
    this.#backend?.setTheme(theme);
    this.#dom?.setOptions({ theme });
  }
  setCursorShape(shape: CursorShape): void {
    this.#opts.cursorShape = shape;
    this.#backend?.setCursorShape(shape);
  }

  /**
   * 옵션을 바꾼다. **할 수 있는 것은 실제로 적용한다** — 격자는 `resize()` 로, 폰트는 받아서
   * 등록하고 격자를 다시 잰다.
   *
   * `worker` 와 `wasmUrl` 만 바꿀 수 없다. 둘 다 이미 만들어진 워커·wasm 인스턴스를 갈아야 해서
   * 사실상 재생성이고, 그러면 화면과 스크롤백이 사라진다 — 조용히 버리지 않고 알린다.
   */
  setOptions(opts: Partial<TerminalOptions>): void {
    const immutable = (["worker", "wasmUrl"] as const).filter((k) => opts[k] !== undefined);
    if (immutable.length > 0) {
      console.warn(
        `maru-term: ${immutable.join(", ")} 은 열 때 정해진다 — 바꾸려면 새 Terminal 을 만들어라`,
      );
    }
    this.#opts = { ...this.#opts, ...opts };
    // 격자를 명시했으면 그대로 맞춘다(컨테이너 추종은 그 순간 꺼진다 — 사용자가 정한 값이 이긴다).
    if (opts.cols !== undefined || opts.rows !== undefined) {
      this.#resizeObserver?.disconnect();
      this.#resizeObserver = null;
      // **열기 전이면 `#size` 만 고쳐 둔다.** 백엔드가 아직 없어 `resize()` 는 던진다 —
      // 래퍼는 `open()` 보다 먼저 `update()` 로 옵션을 넘길 수 있다(React 의 첫 렌더).
      const next = { cols: opts.cols ?? this.#size.cols, rows: opts.rows ?? this.#size.rows };
      if (this.#backend) this.resize(next.cols, next.rows);
      else this.#size = next;
    }
    // 폰트는 나중에도 켤 수 있다 — 받아서 등록한 뒤 격자를 다시 재고 그린다.
    if (opts.loadFont === "jetendard" || opts.fontUrl !== undefined) {
      void loadBundledFont(this.#opts.fontUrl).then(() => {
        if (this.#disposed || !this.#dom) return;
        this.#dom?.setOptions(this.#attachOptions());
        this.#dom?.fit();
      });
    }
    this.#applyOptions();
    if (
      this.#dom &&
      (opts.fontFamily ||
        opts.fontSize ||
        opts.lineHeight ||
        opts.theme ||
        opts.ligatures !== undefined ||
        opts.cursorShape !== undefined)
    ) {
      this.#dom.setOptions(this.#attachOptions());
      (this.#backend as WorkerBackend | null)?.setRenderOptions?.({
        fontFamily: this.#opts.fontFamily ?? DEFAULT_FONT,
        fontSize: this.#opts.fontSize ?? 14,
        lineHeight: this.#opts.lineHeight ?? 1.22,
        ligatures: this.#opts.ligatures ?? true,
      });
    }
  }

  // ── 조회 (항상 Promise) ──────────────────────────────────
  measureCells(text: string): Promise<number> {
    return this.#need().measureCells(text);
  }
  snapshot(): Promise<Snapshot> {
    return this.#need().snapshot();
  }
  selectionText(): Promise<string | null> {
    return this.#need().selectionText();
  }
  linkAt(row: number, col: number): Promise<string | null> {
    return this.#need().linkAt(row, col);
  }

  // ── 이벤트 ───────────────────────────────────────────────
  onData(cb: Listener<Uint8Array>): Disposable {
    return this.#data.on(cb);
  }
  /**
   * IME 조합 텍스트가 바뀔 때마다 알린다(확정·취소 시 빈 문자열).
   *
   * **구독하면 조합을 그리는 책임이 앱으로 넘어간다** — 라이브러리는 코어에 넣지 않는다.
   * 줄을 다시 그리는 앱(readline 류 셸)은 자기 줄에 조합 텍스트를 끼워 넣어야 하는데,
   * 라이브러리가 화면을 따로 건드리면 그 재그리기와 어긋나기 때문이다. 구독자가 없으면
   * 라이브러리가 `ICH`/`DCH`로 직접 넣어 준다(단순한 소비자를 위한 기본 동작).
   */
  onPreedit(cb: Listener<string>): Disposable {
    return this.#preedit.on(cb);
  }
  onTitle(cb: Listener<string>): Disposable {
    return this.#title.on(cb);
  }
  onBell(cb: Listener<void>): Disposable {
    return this.#bell.on(cb);
  }
  onResize(cb: Listener<Size>): Disposable {
    return this.#resize.on(cb);
  }
  onFallback(cb: Listener<FallbackReason>): Disposable {
    return this.#fallback.on(cb);
  }
  /**
   * 한 프레임이 그려졌다. **셀은 오지 않는다**(`FrameMeta`) — 워커 모드에서 매 프레임 셀
   * 버퍼를 왕복시키면(4K 에서 66 MB/s) 렌더를 워커로 옮긴 이유가 사라진다. 셀이 필요하면
   * `snapshot()` 으로 그때 가져간다.
   *
   * 두 모드에서 모두 온다. 구독자가 없으면 워커는 아무것도 보내지 않는다.
   */
  /**
   * 앱이 OSC 52 로 **클립보드에 쓰려 한다**. 라이브러리는 아무것도 하지 않는다 — 임의의 셸
   * 스크립트가 사용자 클립보드를 덮어쓸 수 있으면 안 되므로, 쓸지는 소비자가 정한다.
   *
   * ```ts
   * term.onClipboardWrite((text) => {
   *   if (trusted) void navigator.clipboard.writeText(text);
   * });
   * ```
   */
  onClipboardWrite(cb: Listener<string>): Disposable {
    return this.#clipboardWrite.on(cb);
  }
  /** OSC 52 쓰기가 상한(16 MB)을 넘어 거부됐다. 무음 실패 대신 이유를 보여줄 수 있다. */
  onClipboardRejected(cb: Listener<void>): Disposable {
    return this.#clipboardRejected.on(cb);
  }
  /**
   * 앱이 클립보드를 **읽으려 한다**(OSC 52 `?`). 인자는 target(`c`/`p` 등)이다.
   *
   * **답하지 않는 것이 기본이다** — 답하면 터미널에서 도는 아무 프로그램이나 사용자
   * 클립보드를 가져갈 수 있다. 굳이 답한다면 소비자가 만들어 보낸다:
   * `term.sendText(`\x1b]52;${target};${btoa(text)}\x07`)`.
   */
  onClipboardRead(cb: Listener<string>): Disposable {
    return this.#clipboardRead.on(cb);
  }
  /** OSC 9/777 데스크톱 알림. 띄울지는 소비자가 정한다(권한이 필요하다). */
  onNotification(cb: Listener<{ title: string; body: string }>): Disposable {
    return this.#notification.on(cb);
  }
  /** OSC 7 로 셸의 현재 디렉터리가 바뀌었다. */
  onCwdChange(cb: Listener<string>): Disposable {
    return this.#cwd.on(cb);
  }
  /** OSC 133 셸 진행 상태 — 프롬프트/입력/명령 시작과 끝(종료 코드 포함). */
  onShellEvent(cb: Listener<ShellEvent>): Disposable {
    return this.#shell.on(cb);
  }
  /**
   * 커서가 셸 프롬프트에 있는가. 창을 닫기 전에 "명령이 도는 중인지" 묻는 용도다.
   * 셸 통합이 없으면 보수적으로 `false`("실행 중")를 준다 — 확인 없이 닫는 것보다 낫다.
   */
  cursorAtPrompt(): Promise<boolean> {
    return this.#need().cursorAtPrompt();
  }

  onRender(cb: Listener<FrameMeta>): Disposable {
    return this.#render.on(cb);
  }
  /**
   * 커서가 **다른 칸으로 옮겨갔다**. 모양·깜빡임 변화는 여기 오지 않는다 — 깜빡임은 매
   * 프레임 토글되므로 이동과 섞이면 쓸 수 없다.
   */
  onCursorMove(cb: Listener<CursorState>): Disposable {
    return this.#cursorMove.on(cb);
  }
  /** 뷰포트 위치나 스크롤백 길이가 바뀌었다. 스크롤바를 그리는 쪽이 쓴다. */
  onScroll(cb: Listener<FrameMeta["scroll"]>): Disposable {
    return this.#scrollEv.on(cb);
  }
  /** 선택 영역이 바뀌었다. 해제되면 `null` 이 온다(복사 버튼을 끄는 신호). */
  onSelectionChange(cb: Listener<FrameMeta["selection"]>): Disposable {
    return this.#selectionChange.on(cb);
  }

  dispose(): void {
    this.#resizeObserver?.disconnect();
    this.#resizeObserver = null;
    if (this.#disposed) return;
    this.#disposed = true;
    this.#dom?.dispose();
    this.#dom = null;
    this.#backend?.dispose();
    this.#backend = null;
    for (const e of [
      this.#data,
      this.#title,
      this.#bell,
      this.#resize,
      this.#fallback,
      this.#render,
      this.#preedit,
    ])
      e.clear();
  }
}
