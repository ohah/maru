import type { FrameData } from "../backend/types";
import { CanvasRenderer } from "../render/canvas";
import { DEFAULT_FONT, measureMetrics } from "../render/metrics";
import type { Metrics, GlyphSource } from "../render/types";
import type { DecorationSpan } from "../decoration";
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
  /** OSC 8 → 등록된 provider 순으로 링크를 찾는다. `uri` 만 있으면 OSC 8 이다. */
  resolveLink(
    row: number,
    col: number,
  ): Promise<import("../link").TerminalLink | { uri: string } | null>;
  onRender(cb: (m: import("../types").FrameMeta) => void): { dispose(): void };
  readonly frame: FrameData | null;
  readonly size: { cols: number; rows: number };
}

export interface AttachOptions {
  /** 폰트 확대(1)·축소(-1)·되돌리기(0). 본체의 Cmd+= / Cmd+- / Cmd+0 과 같다. */
  onFontZoom?: (delta: number) => void;
  /** 스냅샷 셀 상한. `fit()` 이 격자를 여기에 맞춘다(넘으면 아래쪽이 안 그려진다). */
  cellsCap?: number;
  /** 프로시저럴 글리프 공급자. 없으면 폰트로만 그린다. */
  glyphs?: GlyphSource | null;
  /** 보조기술이 읽을 이름. 한 페이지에 터미널이 여럿이면 구별되게 준다. */
  ariaLabel?: string;
  /** 스크린 리더 모드. 켜면 바뀐 줄이 라이브 리전으로 읽힌다(비용이 있어 기본 꺼짐). */
  screenReaderMode?: boolean;
  /**
   * 키가 터미널에 닿기 전에 앱이 먼저 본다. `false` 를 돌려주면 터미널은 그 키를 **완전히
   * 무시한다**(기본 바인딩도, 코어 인코딩도 타지 않는다). 앱 단축키가 터미널보다 우선해야 할 때.
   *
   * **IME 조합 정리 뒤에 불린다** — 조합 중 `Cmd` 조합이 오면 라이브러리가 먼저 조합을
   * 취소하고(그러지 않으면 조합 글자가 화면에 남는다) 그다음 이 핸들러를 부른다. 조합 자체를
   * 가로채고 싶으면 `ev.isComposing` 을 보고 판단한다.
   */
  customKeyHandler?: ((ev: KeyboardEvent) => boolean) | null;
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
  /**
   * **소유권을 넘기기 직전에** backing store 를 격자에 맞춘다(워커 모드 전용).
   *
   * `transferControlToOffscreen()` 뒤에는 메인이 `width`/`height` 를 못 쓰므로 `sizeCanvas` 가
   * 워커 모드에서 backing 을 건드리지 않는데, 그 결과 **기본값 300×150 인 채로 넘어간다**.
   * 워커가 resize 메시지를 받아 다시 잡을 때까지 CSS 크기로 늘어나 흐릿하게 보인다(실측:
   * `open()` resolve 뒤 4프레임·22ms). 넘기기 전에 한 번 잡아 그 구간을 없앤다.
   */
  presizeBacking(): void;
  /** 이 프레임에 그릴 장식. 메인이 그리는 모드에서만 의미가 있다(워커 모드는 백엔드로 간다). */
  setDecorations(spans: DecorationSpan[]): void;
  /** 스크린 리더가 읽을 줄을 라이브 리전에 추가한다. */
  announce(lines: string[]): void;
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

  // ── 접근성 ────────────────────────────────────────────────
  // **캔버스는 보조기술이 읽을 수 없다.** 픽셀뿐이라 스크린 리더에게는 빈 요소와 같다. 그래서
  // 캔버스를 접근성 트리에서 빼고(`aria-hidden`), **이미 포커스를 받는 textarea 를 앵커로 삼는다** —
  // 사용자가 Tab 으로 도달하는 곳도, 키를 받는 곳도 거기다.
  canvas.setAttribute("aria-hidden", "true");
  canvas.tabIndex = -1; // 포커스는 textarea 가 받는다(캔버스로 가면 키가 안 먹는다)
  ime.setAttribute("role", "textbox");
  ime.setAttribute("aria-multiline", "true");
  ime.setAttribute("aria-label", opts.ariaLabel ?? "터미널");
  // 브라우저가 값 없는 textarea 를 "비어 있음"으로 읽지 않도록 설명을 붙인다.
  ime.setAttribute("aria-roledescription", "터미널");

  /**
   * 스크린 리더가 읽을 라이브 리전. **`screenReaderMode` 일 때만 내용이 들어간다** — 매 프레임
   * 화면을 텍스트로 뽑아 비교해야 해서 비용이 있고, 켜지 않은 사용자에게 물릴 이유가 없다.
   *
   * 시각적으로 숨기되 접근성 트리에는 남긴다(`display:none` 이면 읽히지 않는다).
   */
  const live = document.createElement("div");
  live.setAttribute("aria-live", "polite");
  live.setAttribute("aria-atomic", "false");
  Object.assign(live.style, {
    position: "absolute",
    width: "1px",
    height: "1px",
    margin: "-1px",
    padding: "0",
    border: "0",
    overflow: "hidden",
    clip: "rect(0 0 0 0)",
    clipPath: "inset(50%)",
    whiteSpace: "nowrap",
  } satisfies Partial<CSSStyleDeclaration>);

  if (getComputedStyle(el).position === "static") el.style.position = "relative";
  el.append(canvas, ime, live);

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
  let hovered: import("../link").TerminalLink | { uri: string } | null = null;
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

  let decorations: DecorationSpan[] = [];

  /** `DomHost.presizeBacking` 의 본체 — 계약은 그 선언을 본다. */
  function presizeBacking(): void {
    const { cols, rows } = term.size;
    canvas.width = Math.ceil(Math.ceil(cols * metrics.cellWidth) * dpr);
    canvas.height = rows * metrics.cellHeight * dpr;
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
        decorations,
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

  function cellOfPoint(clientX: number, clientY: number): [number, number] {
    const r = canvas.getBoundingClientRect();
    const row = Math.floor((clientY - r.top) / metrics.cellHeight);
    const col = Math.floor((clientX - r.left) / metrics.cellWidth);
    return [
      Math.max(0, Math.min(term.size.rows - 1, row)),
      Math.max(0, Math.min(term.size.cols - 1, col)),
    ];
  }
  const cellOf = (ev: MouseEvent): [number, number] => cellOfPoint(ev.clientX, ev.clientY);

  // ── 이벤트 ───────────────────────────────────────────────
  const onKeyDown = (ev: KeyboardEvent) => {
    const inIme = composing || ev.isComposing || ev.keyCode === 229;
    // 조합 중인 키는 IME 가 가진다. **단 Cmd 조합은 예외** — macOS 관례상 앱의 것이고,
    // 그대로 흘리면 Cmd+Delete 로 줄을 지워도 조합 텍스트가 화면에 남는다.
    if (inIme && !ev.metaKey) return;
    // **조합 중에 온 `Cmd` 조합은 조합을 확정시킨다.** 다만 그때 **기본 바인딩은 보내지 않는다**
    // (아래 `imeEnded` 가 그 자리에서 멈춘다).
    //
    // 보내면 순서가 뒤집히기 때문이다 — 확정 글자는 `term.key()` 로 **코어(워커일 수 있다)를
    // 거쳐** 나오는데 바인딩은 `sendText` 로 **메인에서 곧바로** 나가므로, 커서가 먼저 움직이고
    // 글자가 그 뒤에 들어간다. 실측: "무" 확정 + "야" 조합 중 `Cmd+←` → **`야무`**. 한 tick
    // 미뤄도 워커 왕복이 더 느려 소용이 없다. macOS 네이티브 앱들도 조합 중 명령키를 확정에
    // 쓴다 — 사용자는 한 번 더 누르면 된다.
    //
    // **여기서 통째로 막지는 않는다.** 선택·복사·폰트 크기·앱 단축키(`customKeyHandler`)는
    // 바이트를 보내지 않으므로 순서 문제가 없다. 막으면 조합 중에 ⌘C 가 안 먹고 앱이 키를
    // 먼저 볼 수도 없게 된다(계약 §7 이 약속한 것을 어긴다).
    const imeEnded = inIme && ev.metaKey;
    if (imeEnded) {
      composing = false;
      preedit = "";
      // `ime.value` 는 비우지 않는다 — 브라우저가 확정 텍스트를 그대로 흘려보내야 한다.
      opts.onPreedit?.("");
    }
    // 앱이 먼저 본다. 조합 정리 뒤이므로 여기서 false 를 받아도 조합이 남지 않는다.
    if (opts.customKeyHandler?.(ev) === false) return;
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
      ev.preventDefault();
      if (imeEnded) return; // 조합만 확정하고 바이트는 보내지 않는다 — 위 주석 참고
      term.scrollToBottom();
      term.sendText(bind.send);
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
    // `.catch` 가 필요하다 — `WorkerBackend.dispose()` 는 in-flight 조회를 일부러 reject 하므로,
    // 포인터를 캔버스에 둔 채 언마운트하면 미처리 거부가 되어 Vite/Next 에러 오버레이가 뜬다.
    void term
      .resolveLink(row, col)
      .then((link) => {
        // provider 링크는 hover/leave 콜백을 갖는다 — 툴팁 같은 것을 소비자가 붙일 수 있다.
        if (link !== hovered) {
          if (hovered && "leave" in hovered) hovered.leave?.();
          hovered = link;
          if (link && "hover" in link) link.hover?.(ev);
        }
        const next = link ? 1 : 0;
        if (next !== hoverLink) {
          hoverLink = next;
          canvas.style.cursor = link ? "pointer" : "default";
        }
      })
      .catch(() => {
        // 터미널이 사라졌다 — 커서 모양은 의미가 없다.
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
    void term
      .resolveLink(row, col)
      .then((link) => {
        if (!link) return;
        // provider 링크는 소비자가 무엇을 할지 정한다(에디터 열기 등). OSC 8 은 URI 뿐이라
        // 라이브러리가 새 탭으로 연다 — 앱이 선언한 링크의 기존 동작이다.
        if ("activate" in link) link.activate(ev);
        else globalThis.open(link.uri, "_blank", "noopener");
      })
      .catch(() => {});
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

  // ── 터치 ──────────────────────────────────────────────────
  //
  // **브라우저의 마우스 에뮬레이션에 기대지 않는다.** `touchend` 뒤에 오는 합성 `mousedown` 은
  // 300ms 늦고 좌표가 어긋나며, 무엇보다 **드래그를 선택으로 오해한다** — 손가락으로 화면을
  // 밀면 스크롤을 기대하지 텍스트가 잡히길 기대하지 않는다. 그래서 터치를 직접 다루고 합성
  // 이벤트는 `preventDefault` 로 막는다.
  //
  // 뜻은 셋이다: **탭**(포커스 — 소프트 키보드), **세로 드래그**(스크롤), **길게 누르기**(선택).
  const TOUCH_SLOP_PX = 10; // 이만큼 움직이면 탭이 아니라 드래그다
  const LONG_PRESS_MS = 500;
  let touch: {
    id: number;
    x: number;
    y: number;
    startY: number;
    moved: boolean;
    selecting: boolean;
    timer: ReturnType<typeof setTimeout>;
  } | null = null;

  const onTouchStart = (ev: TouchEvent) => {
    if (mouseGrabbed(ev as unknown as MouseEvent)) return; // 앱이 마우스를 잡았으면 그쪽 규약이다
    if (ev.touches.length !== 1) return; // 두 손가락은 브라우저 확대/스크롤에 맡긴다
    const t = ev.touches[0]!;
    touch = {
      id: t.identifier,
      x: t.clientX,
      y: t.clientY,
      startY: t.clientY,
      moved: false,
      selecting: false,
      timer: globalThis.setTimeout(() => {
        // 길게 누르면 그 자리의 단어를 잡는다 — 모바일에서 드래그로 선택하기는 어렵다.
        if (!touch || touch.moved) return;
        touch.selecting = true;
        const [row, col] = cellOfPoint(touch.x, touch.y);
        term.selectWord(row, col);
        redraw();
      }, LONG_PRESS_MS),
    };
  };

  const onTouchMove = (ev: TouchEvent) => {
    if (!touch) return;
    const t = [...ev.touches].find((x) => x.identifier === touch!.id);
    if (!t) return;
    const dy = t.clientY - touch.y;
    if (!touch.moved && Math.hypot(t.clientX - touch.x, t.clientY - touch.startY) > TOUCH_SLOP_PX) {
      touch.moved = true;
      clearTimeout(touch.timer);
    }
    if (touch.selecting) {
      const [row, col] = cellOfPoint(t.clientX, t.clientY);
      term.selectExtend(row, col);
      redraw();
    } else if (touch.moved) {
      // **위로 밀면 과거로 간다** — 종이를 밀어 올리는 감각이고, 네이티브 터미널도 그렇다.
      const rows = dy / metrics.cellHeight;
      if (Math.abs(rows) >= 1) {
        term.scroll(Math.trunc(rows));
        touch.y = t.clientY;
      }
    }
    ev.preventDefault(); // 페이지가 함께 스크롤되면 화면이 통째로 움직인다
  };

  const onTouchEnd = (ev: TouchEvent) => {
    if (!touch) return;
    clearTimeout(touch.timer);
    if (!touch.moved && !touch.selecting) {
      // 탭 — 소프트 키보드를 띄운다. 커서를 옮기지는 않는다(셸이 커서를 소유한다).
      ime.focus();
      ev.preventDefault(); // 합성 mousedown 이 선택을 시작하지 않게
    }
    touch = null;
  };

  canvas.addEventListener("touchstart", onTouchStart, { passive: true });
  canvas.addEventListener("touchmove", onTouchMove, { passive: false });
  canvas.addEventListener("touchend", onTouchEnd);
  canvas.addEventListener("touchcancel", onTouchEnd);

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
    presizeBacking,
    setDecorations(spans) {
      decorations = spans;
      redraw();
    },
    /**
     * 스크린 리더에게 읽힐 줄을 밀어 넣는다. **바뀐 줄만** 온다 — 화면 전체를 매번 읽으면
     * 사용자가 출력 하나마다 24 줄을 듣는다.
     */
    announce(lines) {
      if (lines.length === 0) return;
      for (const text of lines) {
        const p = document.createElement("div");
        p.textContent = text;
        live.append(p);
      }
      // 라이브 리전이 무한히 자라면 DOM 이 부풀고 일부 리더가 전체를 다시 읽는다.
      while (live.childElementCount > 40) live.firstElementChild?.remove();
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
      let cols = Math.max(2, Math.floor(rect.width / metrics.cellWidth));
      let rows = Math.max(1, Math.floor(rect.height / metrics.cellHeight));
      // **스냅샷 셀 상한을 넘지 않는다.** 넘으면 코어는 멀쩡히 그리는데 스냅샷이 잘려
      // 아래쪽 행이 영영 빈 배경으로 남는다(오류도 경고도 없이). 행을 줄여 맞춘다.
      const cap = opts.cellsCap;
      if (cap && cols * rows > cap) {
        rows = Math.max(1, Math.floor(cap / cols));
        if (cols * rows > cap) cols = Math.max(2, Math.floor(cap / rows));
      }
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
      canvas.removeEventListener("touchstart", onTouchStart);
      canvas.removeEventListener("touchmove", onTouchMove);
      canvas.removeEventListener("touchend", onTouchEnd);
      canvas.removeEventListener("touchcancel", onTouchEnd);
      if (touch) clearTimeout(touch.timer);
      canvas.removeEventListener("click", onClick);
      canvas.removeEventListener("wheel", onWheel);
      globalThis.removeEventListener("mouseup", onMouseUp);
      renderer?.dispose();
      canvas.remove();
      ime.remove();
    },
  };
}
