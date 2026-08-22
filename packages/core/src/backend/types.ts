import type { CursorState, KeyInput, Size, Snapshot, Theme } from "../types";

/** 백엔드가 밖으로 흘리는 사건. 워커 모드에서는 postMessage로 넘어온다. */
export type BackendEvent =
  | { type: "data"; bytes: Uint8Array }
  | { type: "title"; title: string }
  | { type: "bell" }
  | { type: "resize"; size: Size }
  | { type: "render"; frame: FrameData }
  /** `vt_modes` 가 바뀌었다. 마우스 추적 여부를 **동기로** 알아야 하는 DOM 층이 캐시한다. */
  | { type: "modes"; value: number };

/** 렌더러가 한 프레임을 그리는 데 필요한 전부. */
export interface FrameData {
  size: Size;
  cursor: CursorState;
  /** 셀 레코드 원본(20바이트 × 셀 수). 복사 없이 그대로 읽는다. */
  cells: Uint8Array;
  cellCount: number;
  selection: SelectionSpan | null;
  scroll: { offset: number; length: number };
  /**
   * `vt_modes` 비트. 마우스 추적 여부를 **동기로** 알아야 해서 프레임에 싣는다 — 워커 모드에서
   * 조회는 비동기라 mousedown 안에서 물을 수 없다.
   *
   * bit0 bracketed paste · bit1 application cursor keys · bit2 keypad · bit3 ambiguous wide ·
   * bits8+ mouse tracking(0 none, 1 x10, 2 normal, 3 button, 4 any)
   */
  modes: number;
}

export interface SelectionSpan {
  startRow: number;
  startCol: number;
  endRow: number;
  endCol: number;
  block: boolean;
}

/**
 * wasm 코어의 소유자. `Terminal`은 이 인터페이스만 알고, 코어가 메인에 있는지 워커에 있는지
 * 모른다. **명령은 단방향, 조회는 Promise** — 그래야 모드가 바뀌어도 타입이 안 갈린다.
 */
export interface Backend {
  write(bytes: Uint8Array): void;
  resize(cols: number, rows: number): void;
  key(input: KeyInput): void;
  paste(text: string): void;
  mouse(ev: MouseReport): void;
  focus(gained: boolean): void;

  scroll(deltaUp: number): void;
  scrollToBottom(): void;

  selectStart(row: number, col: number, block: boolean): void;
  selectExtend(row: number, col: number): void;
  selectWord(row: number, col: number): void;
  selectLine(row: number): void;
  selectAll(): void;
  selectClear(): void;
  /** IME 조합 텍스트를 화면에 넣고 되돌린다(뒤 텍스트가 밀린다). 빈 문자열이면 지운다. */
  setPreedit(text: string, insert?: boolean): void;

  setTheme(theme: Theme): void;
  setCursorShape(shape: CursorState["shape"]): void;
  setScrollback(lines: number): void;
  setAmbiguousWide(on: boolean): void;

  measureCells(text: string): Promise<number>;
  snapshot(): Promise<Snapshot>;
  selectionText(): Promise<string | null>;
  linkAt(row: number, col: number): Promise<string | null>;

  on(cb: (e: BackendEvent) => void): void;
  dispose(): void;
}

export interface MouseReport {
  button: number;
  col: number;
  row: number;
  pressed: boolean;
  motion: boolean;
  mods: number;
}

/** `vt_key`가 받는 kind. `wasm_bridge.zig`의 switch와 맞물린다. */
export const KeyKind: Record<KeyInput["key"], number> = {
  char: 0,
  enter: 1,
  escape: 2,
  tab: 3,
  backspace: 4,
  up: 5,
  down: 6,
  left: 7,
  right: 8,
  home: 9,
  end: 10,
  insert: 11,
  delete: 12,
  pageUp: 13,
  pageDown: 14,
  f: 15,
};

export function modsOf(k: KeyInput): number {
  return (k.shift ? 1 : 0) | (k.ctrl ? 2 : 0) | (k.alt ? 4 : 0) | (k.meta ? 8 : 0);
}
