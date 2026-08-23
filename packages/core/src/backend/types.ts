import type { CursorState, KeyInput, Size, Snapshot, Theme } from "../types";

/** 백엔드가 밖으로 흘리는 사건. 워커 모드에서는 postMessage로 넘어온다. */
export type BackendEvent =
  | { type: "data"; bytes: Uint8Array }
  | { type: "title"; title: string }
  | { type: "bell" }
  | { type: "resize"; size: Size }
  | { type: "render"; frame: FrameData }
  /** `vt_modes` 가 바뀌었다. 마우스 추적 여부를 **동기로** 알아야 하는 DOM 층이 캐시한다. */
  | { type: "modes"; value: number }
  /**
   * OSC 52 로 앱이 클립보드에 쓰려 한다. **라이브러리는 아무것도 하지 않는다** — 임의의 셸
   * 스크립트가 사용자 클립보드를 덮어쓸 수 있으면 안 되므로, 정책은 소비자가 정한다.
   */
  | { type: "clipboard-write"; text: string }
  /** 상한(16 MB) 초과로 거부됐다. 무음 실패 대신 이유를 보여줄 수 있게 알린다. */
  | { type: "clipboard-rejected" }
  /**
   * OSC 52 로 앱이 클립보드를 **읽으려** 한다. 응답하려면 소비자가
   * `\x1b]52;<target>;<base64>\x07` 를 만들어 보낸다 — 답하지 않는 것이 기본이다.
   */
  | { type: "clipboard-read"; target: string }
  /** OSC 9/777 데스크톱 알림. 띄울지는 소비자가 정한다. */
  | { type: "notification"; title: string; body: string }
  /** OSC 7 로 현재 디렉터리가 바뀌었다. */
  | { type: "cwd"; cwd: string }
  /** OSC 133 셸 사건. `exit` 은 `command-end` 에서만 온다. */
  | { type: "shell"; event: ShellEvent };

/** OSC 133 이 알려 주는 셸 진행 상태. `row` 는 뷰포트 행이다. */
export type ShellEvent =
  | { kind: "prompt-start"; row: number }
  | { kind: "input-start"; row: number }
  | { kind: "command-start"; row: number }
  | { kind: "command-end"; row: number; exit: number | null }
  | { kind: "cwd-changed" };

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

/** 검색 결과 한 건. 좌표는 **절대 행**(0 = 스크롤백 최상단)이라 스크롤해도 유효하다. */
export interface Match {
  startRow: number;
  startCol: number;
  endRow: number;
  endCol: number;
}

/** 검색 결과. `total` 이 `matches.length` 보다 클 수 있다(버퍼 상한). */
export interface FindResult {
  matches: Match[];
  total: number;
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
  /** 뷰포트를 스크롤백 맨 위로. */
  scrollToTop(): void;
  /** 절대 행 `line`(0 = 스크롤백 최상단)이 뷰포트 첫 줄에 오도록. */
  scrollToLine(line: number): void;

  /**
   * 화면을 지운다. 셸이 프롬프트를 다시 그려야 하면 `\x0c`(^L)를 `data` 이벤트로 흘린다 —
   * 호스트가 그걸 PTY 에 써 준다(본체 `.clear_screen` 과 같은 계약).
   */
  clear(): void;

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
  /** 스크롤백을 포함해 전부 훑는다. 대소문자를 구분하고, 정규식은 지원하지 않는다. */
  find(needle: string): Promise<FindResult>;
  /** 커서가 셸 프롬프트에 있는가. 셸 통합(OSC 133)이 없으면 보수적으로 `false`("실행 중"). */
  cursorAtPrompt(): Promise<boolean>;
  /** 화면을 평문으로. 스타일·색은 버린다(코어 `dumpUtf8` 의 계약). */
  serialize(): Promise<string>;

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
