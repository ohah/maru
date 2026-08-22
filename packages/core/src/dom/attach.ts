import type { FrameData } from "../backend/types";
import { CanvasRenderer } from "../render/canvas";
import { DEFAULT_FONT, measureMetrics } from "../render/metrics";
import type { Metrics, GlyphSource } from "../render/types";
import type { Theme } from "../types";
import { toKeyInput } from "./keymap";

/** `attachDom`이 조작하는 터미널의 최소 표면. `Terminal`이 이걸 만족한다. */
export interface DomTarget {
  write(data: string | Uint8Array): void;
  key(input: import("../types").KeyInput): void;
  paste(text: string): void;
  sendText(text: string): void;
  /** `vt_modes` 비트. bits8+ 가 마우스 추적이다. */
  readonly modes: number;
  mouse(ev: import("../backend/types").MouseReport): void;
  focus(gained: boolean): void;
  resize(cols: number, rows: number): void;
  scroll(deltaUp: number): void;
  scrollToBottom(): void;
  selectStart(row: number, col: number, block?: boolean): void;
  selectExtend(row: number, col: number): void;
  selectWord(row: number, col: number): void;
  selectLine(row: number): void;
  selectAll(): void;
  selectClear(): void;
  selectionText(): Promise<string | null>;
  linkAt(row: number, col: number): Promise<string | null>;
  onRender(cb: (f: FrameData) => void): { dispose(): void };
  readonly frame: FrameData | null;
  readonly size: { cols: number; rows: number };
}

export interface AttachOptions {
  /** 폰트 확대(1)·축소(-1)·되돌리기(0). 본체의 Cmd+= / Cmd+- / Cmd+0 과 같다. */
  onFontZoom?: (delta: number) => void;
  /** 프로시저럴 글리프 공급자. 없으면 폰트로만 그린다. */
  glyphs?: GlyphSource | null;
  fontFamily?: string;
  fontSize?: number;
  lineHeight?: number;
  theme: Theme;
  ligatures?: boolean;
  /**
   * 이 계층이 직접 그릴지. `worker: "full"`이면 false — 캔버스 소유권이 워커로 넘어가므로
   * 메인에서 `getContext("2d")`를 부르면 예외가 난다. 그때는 입력만 처리한다.
   */
  render?: boolean;
  /** 워커 모드에서 조합/깜빡임 상태를 렌더 소유자에게 알린다. */
  onPreedit?: (text: string) => void;
  onBlink?: (on: boolean) => void;
  /** 워커 모드에서 캔버스 backing store 를 다시 잡아야 할 때. */
  onResizeCanvas?: (cols: number, rows: number) => void;
}

export interface DomHost {
  canvas: HTMLCanvasElement;
  metrics: Metrics;
  /** 폰트·크기·줄간격이 바뀌면 격자를 다시 재고 그리드를 맞춘다. */
  setOptions(opts: Partial<AttachOptions>): void;
  /** 요소 크기에 맞춰 cols/rows를 다시 계산한다. */
  fit(): void;
  redraw(): void;
  dispose(): void;
}

const BLINK_MS = 530;

/**
 * 기본 터미널 키바인딩 — macOS 줄 편집 관례를 셸 시퀀스로 매핑한다.
 *
 * maru 본체의 `default_terminal_bindings`(`src/config/keybinding.zig`)와 **같은 표**다(Ghostty
 * 기본 keybind 와도 동작이 같다). 코어의 키 인코딩은 이 조합을 평범한 Backspace/화살표와
 * 구분하지 않으므로, 이 층이 없으면 Cmd+Delete 가 그냥 `\x7f` 로 나간다.
 *
 * Option+Backspace(단어 삭제 `\x1b\x7f`)는 코어의 meta-ESC 인코딩이 이미 처리해 여기 없다.
 */
const KEY_BINDINGS: { meta?: boolean; alt?: boolean; key: string; send: string }[] = [
  { meta: true, key: "Backspace", send: "\x15" }, // 줄 시작까지 삭제(Ctrl+U)
  { meta: true, key: "ArrowLeft", send: "\x01" }, // 줄 시작(Ctrl+A)
  { meta: true, key: "ArrowRight", send: "\x05" }, // 줄 끝(Ctrl+E)
  { alt: true, key: "ArrowLeft", send: "\x1bb" }, // 단어 왼쪽(Meta-b)
  { alt: true, key: "ArrowRight", send: "\x1bf" }, // 단어 오른쪽(Meta-f)
];

/**
 * 요소에 canvas와 입력 처리를 붙인다. **DOM을 아는 유일한 자리**다 — 코어와 렌더러는
 * 브라우저 이벤트를 모른다.
 */
export function attachDom(el: HTMLElement, term: DomTarget, opts: AttachOptions): DomHost {
  type RenderOpts = {
    fontFamily: string;
    fontSize: number;
    lineHeight: number;
    ligatures: boolean;
    theme: Theme;
  };
  let options: RenderOpts = {
    fontFamily: opts.fontFamily ?? DEFAULT_FONT,
    fontSize: opts.fontSize ?? 14,
    lineHeight: opts.lineHeight ?? 1.22,
    ligatures: opts.ligatures ?? true,
    theme: opts.theme,
  };

  const dpr = Math.min(globalThis.devicePixelRatio || 1, 2);
  const canvas = document.createElement("canvas");
  canvas.tabIndex = 0;
  canvas.style.display = "block";
  // IME는 canvas에 조합 이벤트를 주지 않는다. 숨은 textarea가 키와 조합을 모두 받는다.
  const ime = document.createElement("textarea");
  Object.assign(ime.style, {
    position: "absolute",
    left: "0",
    top: "0",
    width: "2px",
    height: "2px",
    opacity: "0",
    border: "0",
    padding: "0",
    resize: "none",
    overflow: "hidden",
    whiteSpace: "nowrap",
    zIndex: "2",
  } satisfies Partial<CSSStyleDeclaration>);
  ime.autocapitalize = "off";
  ime.spellcheck = false;
  if (getComputedStyle(el).position === "static") el.style.position = "relative";
  el.append(canvas, ime);

  const doRender = opts.render !== false;
  const renderer = doRender ? new CanvasRenderer() : null;
  if (renderer && opts.glyphs) renderer.setGlyphSource(opts.glyphs);
  let metrics = measureMetrics({ ...options, devicePixelRatio: dpr });

  let preedit = "";
  let composing = false;
  let blinkOn = true;
  let blinkTimer = 0;
  let dragging = false;
  let clickCount = 0;
  let clickTimer = 0;
  let lastCell: [number, number] = [-9, -9];
  let hoverLink = 0;
  /** 앱이 마우스를 잡고 있는가(DECSET 1000/1002/1003). Shift 를 누르면 선택이 우선한다. */
  const mouseGrabbed = (ev: MouseEvent): boolean => term.modes >> 8 !== 0 && !ev.shiftKey;
  /** DOM 버튼 번호를 xterm 관례로 옮긴다(좌 0 · 중 1 · 우 2). */
  const reportOf = (ev: MouseEvent, pressed: boolean, motion: boolean) => {
    const [row, col] = cellOf(ev);
    return {
      button: ev.button === 1 ? 1 : ev.button === 2 ? 2 : 0,
      col,
      row,
      pressed,
      motion,
      mods: (ev.shiftKey ? 1 : 0) | (ev.altKey ? 2 : 0) | (ev.ctrlKey ? 4 : 0),
    };
  };
  let hoverCell: [number, number] = [-9, -9];

  const ctx2d = doRender ? canvas.getContext("2d") : null;

  function sizeCanvas(): void {
    const { cols, rows } = term.size;
    const cssW = Math.ceil(cols * metrics.cellWidth);
    const cssH = rows * metrics.cellHeight;
    // CSS 크기는 어느 모드든 메인이 정한다(레이아웃은 DOM 몫).
    canvas.style.width = `${cssW}px`;
    canvas.style.height = `${cssH}px`;
    if (!doRender || !renderer) {
      // **워커 모드에서는 backing store 를 만질 수 없다.** transferControlToOffscreen 이후
      // 메인에서 width/height 를 쓰면 예외가 난다 — 크기 조정은 워커가 한다(resize 메시지).
      opts.onResizeCanvas?.(cols, rows);
      return;
    }
    canvas.width = Math.ceil(cssW * dpr);
    canvas.height = cssH * dpr;
    ctx2d?.setTransform(1, 0, 0, 1, 0, 0);
    ctx2d?.scale(dpr, dpr);
    renderer.attach(canvas, metrics);
  }

  function redraw(): void {
    if (!doRender || !renderer) return;
    const frame = term.frame;
    if (frame)
      renderer.draw(frame, {
        theme: options.theme,
        ligatures: options.ligatures,
        preedit,
        blinkOn,
      });
  }

  function restartBlink(): void {
    // 커서가 움직이면 **위상을 리셋**한다. 안 하면 "사라진 구간"에 이동했을 때
    // 새 위치가 한 주기 동안 안 보인다.
    blinkOn = true;
    opts.onBlink?.(true);
    clearInterval(blinkTimer);
    blinkTimer = setInterval(() => {
      blinkOn = !blinkOn;
      opts.onBlink?.(blinkOn);
      redraw();
    }, BLINK_MS) as unknown as number;
  }

  function cellOf(ev: MouseEvent): [number, number] {
    const r = canvas.getBoundingClientRect();
    const row = Math.floor((ev.clientY - r.top) / metrics.cellHeight);
    const col = Math.floor((ev.clientX - r.left) / metrics.cellWidth);
    return [
      Math.max(0, Math.min(term.size.rows - 1, row)),
      Math.max(0, Math.min(term.size.cols - 1, col)),
    ];
  }

  // ── 이벤트 ───────────────────────────────────────────────
  const onKeyDown = (ev: KeyboardEvent) => {
    const inIme = composing || ev.isComposing || ev.keyCode === 229;
    // 조합 중인 키는 IME 가 가진다. **단 Cmd 조합은 예외** — macOS 관례상 앱의 것이고,
    // 그대로 흘리면 Cmd+Delete 로 줄을 지워도 조합 텍스트가 화면에 남는다.
    if (inIme && !ev.metaKey) return;
    if (inIme && ev.metaKey) {
      composing = false;
      preedit = "";
      ime.value = "";
      opts.onPreedit?.("");
    }
    if (ev.metaKey && ev.key === "a") {
      term.selectAll();
      redraw();
      ev.preventDefault();
      return;
    }
    if (ev.metaKey && ev.key === "c") {
      void copySelection();
      ev.preventDefault();
      return;
    }
    if (ev.metaKey && ev.key === "v") return; // paste 이벤트가 처리한다
    // 기본 바인딩은 **코어 인코딩보다 먼저** 본다 — 코어는 Cmd+Backspace 를 그냥 Backspace 로
    // 인코딩하므로, 여기서 걸러내지 않으면 줄 삭제가 한 글자 삭제가 된다.
    for (const bind of KEY_BINDINGS) {
      if (ev.key !== bind.key) continue;
      if (!!bind.meta !== ev.metaKey || !!bind.alt !== ev.altKey) continue;
      if (ev.ctrlKey || ev.shiftKey) continue; // 수식자가 더 붙으면 다른 조합이다
      term.scrollToBottom();
      term.sendText(bind.send);
      ev.preventDefault();
      return;
    }
    // 폰트 크기 — 본체의 increase/decrease/reset_font_size 와 같은 조합이다.
    if (ev.metaKey && !ev.ctrlKey && !ev.altKey) {
      const zoom =
        ev.key === "=" || ev.key === "+"
          ? 1
          : ev.key === "-" || ev.key === "_"
            ? -1
            : ev.key === "0"
              ? 0
              : null;
      if (zoom !== null) {
        opts.onFontZoom?.(zoom);
        ev.preventDefault();
        return;
      }
    }
    if (ev.key === "Escape") term.selectClear();
    const input = toKeyInput(ev);
    if (!input) return;
    ev.preventDefault();
    restartBlink();
    term.key(input);
  };

  const onPaste = (ev: ClipboardEvent) => {
    const text = ev.clipboardData?.getData("text");
    if (text) {
      term.paste(text);
      ev.preventDefault();
    }
  };

  async function copySelection(): Promise<void> {
    const text = await term.selectionText();
    if (text) await navigator.clipboard?.writeText(text);
  }

  const onCompositionStart = () => {
    composing = true;
    preedit = "";
  };
  const onCompositionUpdate = (ev: CompositionEvent) => {
    preedit = ev.data ?? "";
    opts.onPreedit?.(preedit);
    restartBlink();
    redraw();
  };
  const onCompositionEnd = (ev: CompositionEvent) => {
    composing = false;
    preedit = "";
    opts.onPreedit?.("");
    ime.value = "";
    const text = ev.data ?? "";
    if (text) for (const chr of text) term.key({ key: "char", codepoint: chr.codePointAt(0)! });
    redraw();
  };

  const onMouseDown = (ev: MouseEvent) => {
    // 앱이 마우스를 켜 두었으면(vim `set mouse=a`, tmux, htop) 클릭은 **앱의 것**이다.
    // Shift 를 누르면 관례대로 선택이 우선한다.
    if (mouseGrabbed(ev)) {
      term.mouse(reportOf(ev, true, false));
      ev.preventDefault();
      setTimeout(() => ime.focus(), 0);
      return;
    }
    if (ev.button !== 0) return;
    const [row, col] = cellOf(ev);
    // 연속 클릭은 **같은 셀 근처에서만** 누적한다. 위치를 안 보면 400ms 안의 아무 클릭이나
    // 2회로 세어 엉뚱한 곳에서 단어 선택으로 빠지고 드래그가 시작되지 않는다.
    const near = row === lastCell[0] && Math.abs(col - lastCell[1]) <= 1;
    clickCount = near ? clickCount + 1 : 1;
    lastCell = [row, col];
    clearTimeout(clickTimer);
    clickTimer = setTimeout(() => {
      clickCount = 0;
    }, 400) as unknown as number;

    if (clickCount === 2) term.selectWord(row, col);
    else if (clickCount >= 3) term.selectLine(row);
    else term.selectStart(row, col, ev.altKey);
    dragging = true; // 더블/트리플 뒤에도 드래그로 확장할 수 있어야 한다
    ev.preventDefault();
    setTimeout(() => ime.focus(), 0);
    restartBlink();
  };

  const onMouseMove = (ev: MouseEvent) => {
    if (mouseGrabbed(ev)) {
      // 3=button-event(드래그 중만) · 4=any-event(항상). 그 아래는 이동을 안 보낸다.
      const track = term.modes >> 8;
      if (track >= 4 || (track === 3 && ev.buttons !== 0)) {
        term.mouse(reportOf(ev, ev.buttons !== 0, true));
      }
      return;
    }
    const [row, col] = cellOf(ev);
    if (dragging) {
      term.selectExtend(row, col);
      return;
    }
    // 워커 모드에는 메인에 프레임이 없다. 좌표가 바뀔 때만 코어에 물어본다.
    if (row === hoverCell[0] && col === hoverCell[1]) return;
    hoverCell = [row, col];
    void term.linkAt(row, col).then((uri) => {
      const next = uri ? 1 : 0;
      if (next !== hoverLink) {
        hoverLink = next;
        canvas.style.cursor = uri ? "pointer" : "default";
      }
    });
  };

  const onMouseUp = (ev: MouseEvent) => {
    if (mouseGrabbed(ev)) {
      term.mouse(reportOf(ev, false, false));
      return;
    }
    dragging = false;
  };

  const onClick = (ev: MouseEvent) => {
    if (!hoverLink) return;
    const [row, col] = cellOf(ev);
    void term.linkAt(row, col).then((uri) => {
      if (uri) globalThis.open(uri, "_blank", "noopener");
    });
  };

  const onWheel = (ev: WheelEvent) => {
    ev.preventDefault();
    if (mouseGrabbed(ev)) {
      // 휠은 버튼 64/65 로 보낸다(xterm 관례) — less·htop 이 이걸로 스크롤한다.
      const [row, col] = cellOf(ev);
      term.mouse({
        button: ev.deltaY < 0 ? 64 : 65,
        col,
        row,
        pressed: true,
        motion: false,
        mods: (ev.shiftKey ? 1 : 0) | (ev.altKey ? 2 : 0) | (ev.ctrlKey ? 4 : 0),
      });
      return;
    }
    term.scroll(Math.sign(-ev.deltaY) * 3);
  };

  canvas.addEventListener("mousedown", onMouseDown);
  canvas.addEventListener("mousemove", onMouseMove);
  canvas.addEventListener("click", onClick);
  canvas.addEventListener("wheel", onWheel, { passive: false });
  globalThis.addEventListener("mouseup", onMouseUp);
  ime.addEventListener("keydown", onKeyDown);
  ime.addEventListener("paste", onPaste);
  ime.addEventListener("compositionstart", onCompositionStart);
  ime.addEventListener("compositionupdate", onCompositionUpdate);
  ime.addEventListener("compositionend", onCompositionEnd);
  ime.addEventListener("input", () => {
    if (!composing) ime.value = "";
  });
  // 포커스 리포트(DECSET 1004). 코어가 그 모드일 때만 바이트를 내므로 항상 불러도 안전하다 —
  // vim 은 이걸로 `FocusGained`/`FocusLost` 를 띄우고 tmux 는 패널 활성화를 따라간다.
  ime.addEventListener("focus", () => term.focus(true));
  ime.addEventListener("blur", () => term.focus(false));

  const renderSub = term.onRender(() => redraw());

  sizeCanvas();
  restartBlink();
  redraw();

  return {
    canvas,
    get metrics() {
      return metrics;
    },
    setOptions(next) {
      options = { ...options, ...next };
      metrics = measureMetrics({ ...options, devicePixelRatio: dpr });
      sizeCanvas();
      redraw();
    },
    fit() {
      const rect = el.getBoundingClientRect();
      if (rect.width < 1 || rect.height < 1) return; // 아직 레이아웃 전이다
      const cols = Math.max(2, Math.floor(rect.width / metrics.cellWidth));
      const rows = Math.max(1, Math.floor(rect.height / metrics.cellHeight));
      // **크기가 그대로면 아무것도 하지 않는다.** 리사이즈는 soft-wrap 을 재배치하고 커서를
      // 따라 옮기므로, 같은 값으로 다시 부르면 화면과 커서가 흐트러진다. `ResizeObserver` 는
      // observe() 직후 한 번 발화하므로 이 가드가 없으면 열자마자 그 일이 벌어진다(실측).
      const cur = term.size;
      if (cur.cols === cols && cur.rows === rows) {
        sizeCanvas();
        return;
      }
      term.resize(cols, rows);
      sizeCanvas();
      redraw();
    },
    redraw,
    dispose() {
      clearInterval(blinkTimer);
      clearTimeout(clickTimer);
      renderSub.dispose();
      canvas.removeEventListener("mousedown", onMouseDown);
      canvas.removeEventListener("mousemove", onMouseMove);
      canvas.removeEventListener("click", onClick);
      canvas.removeEventListener("wheel", onWheel);
      globalThis.removeEventListener("mouseup", onMouseUp);
      renderer?.dispose();
      canvas.remove();
      ime.remove();
    },
  };
}
