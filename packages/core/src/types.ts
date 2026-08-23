/** 그리드 크기(셀 단위). */
export interface Size {
  cols: number;
  rows: number;
}

export type CursorShape = "block" | "underline" | "bar";

export interface CursorState {
  row: number;
  col: number;
  shape: CursorShape;
  blink: boolean;
  visible: boolean;
}

/** ANSI 16색 + 전경·배경·커서·선택. Ghostty 계열 테마 파일과 같은 축이다. */
export interface Theme {
  foreground: number;
  background: number;
  cursor?: number;
  selectionBackground?: number;
  selectionForeground?: number;
  /** 16개 슬롯. 빠진 자리는 기본 팔레트를 쓴다. */
  palette?: (number | undefined)[];
}

/**
 * 한 프레임의 요약. `onRender` 가 이걸 준다 — **셀은 들어 있지 않다**(워커 모드에서 매 프레임
 * 셀을 왕복시키지 않기 위해서다). 셀이 필요하면 `snapshot()` 을 쓴다.
 */
export interface FrameMeta {
  size: Size;
  cursor: CursorState;
  selection: { startRow: number; startCol: number; endRow: number; endCol: number } | null;
  scroll: { offset: number; length: number };
}

export interface TerminalOptions {
  cols?: number;
  rows?: number;
  /**
   * 코어와 렌더를 워커에 둘지. 기본은 `"full"`(둘 다 워커) — 대량 출력이 쌓여도 메인 스레드가
   * 막히지 않는 것이 기본 동작이다. 명시하지 않았을 때만 능력 감지로 하향 폴백한다.
   *
   * 렌더만 워커에 두는 중간 모드는 **두지 않는다**: 조회가 어차피 전부 Promise라 "동기 조회"라는
   * 명분이 없고, wasm 은 번들이 아니라 별도 파일이라 워커 번들도 줄지 않는다(측정 완료).
   */
  worker?: "full" | false;
  fontFamily?: string;
  fontSize?: number;
  lineHeight?: number;
  theme?: Theme;
  cursorShape?: CursorShape;
  scrollback?: number;
  /** East Asian Width Ambiguous를 2셀로 볼지. **레이아웃이 통째로 갈린다.** */
  ambiguousWide?: boolean;
  /** 리가처를 살리는 ASCII run 병합. 끄면 셀 단위로 그린다. */
  ligatures?: boolean;
  /**
   * 번들 폰트를 받아 등록한다. 기본은 받지 않는다(1.6 MB).
   *
   * `"jetendard"` 는 본체와 같은 한글 폴백이다 — 한글이 라틴 정확히 2배 폭이라 격자가 안 벌어진다.
   */
  /**
   * 컨테이너 크기를 따라갈지. 기본은 따라간다(`cols`/`rows` 를 명시하면 그쪽이 이긴다).
   *
   * **이 판단은 `Terminal` 이 소유한다.** 래퍼가 따로 `ResizeObserver` 를 걸면 같은 요소에
   * 둘이 붙어 매 프레임 `fit()` 이 두 번 돈다.
   */
  autoFit?: boolean;
  loadFont?: "jetendard" | false;
  /** 번들 폰트 위치를 직접 지정한다. */
  fontUrl?: string | URL;
  /** wasm 위치를 직접 지정한다. 기본은 패키지에 함께 실린 바이너리. */
  wasmUrl?: string | URL;
}

export interface Disposable {
  dispose(): void;
}

export type FallbackReason = "no-worker" | "no-offscreen-canvas";

/** 한 셀의 내용. 렌더러와 스냅샷 소비자가 함께 읽는다. */
export interface Cell {
  codepoint: number;
  /** 0=기본, 0x01xxxxxx=인덱스, 0x02rrggbb=RGB */
  fg: number;
  bg: number;
  flags: number;
  /** OSC 8 링크 id. 0이면 없음. */
  link: number;
}

export interface Snapshot {
  size: Size;
  cursor: CursorState;
  cells: Cell[];
}

export interface KeyInput {
  /** `"char"`이면 `codepoint`를 채운다. */
  key:
    | "char"
    | "enter"
    | "escape"
    | "tab"
    | "backspace"
    | "up"
    | "down"
    | "left"
    | "right"
    | "home"
    | "end"
    | "insert"
    | "delete"
    | "pageUp"
    | "pageDown"
    | "f";
  codepoint?: number;
  /** `key === "f"`일 때 1~12. */
  fn?: number;
  shift?: boolean;
  ctrl?: boolean;
  alt?: boolean;
  meta?: boolean;
}
