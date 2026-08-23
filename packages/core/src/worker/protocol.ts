import type { FrameMeta } from "../types";
import type { BackendEvent } from "../backend/types";
import type { CursorShape, KeyInput, Size, Theme } from "../types";
import type { MouseReport } from "../backend/types";

/** 메인 → 워커. 명령은 단방향이고, 조회만 `id`로 응답을 짝짓는다. */
export type ToWorker =
  | {
      t: "init";
      canvas: OffscreenCanvas;
      size: Size;
      wasmUrl?: string;
      fontUrl?: string;
      /** 기본 번들 폰트(Regular+Bold)를 워커가 스스로 받는다. */
      loadFont?: boolean;
      opts: WorkerRenderOptions;
    }
  | { t: "write"; bytes: Uint8Array }
  | { t: "key"; input: KeyInput }
  | { t: "paste"; text: string }
  | { t: "mouse"; ev: MouseReport }
  | { t: "focus"; gained: boolean }
  | { t: "resize"; cols: number; rows: number }
  | { t: "scroll"; deltaUp: number }
  | { t: "scrollBottom" }
  | { t: "scrollTop" }
  | { t: "scrollToLine"; line: number }
  | { t: "clear" }
  | {
      t: "sel";
      op: "start" | "extend" | "word" | "line" | "all" | "clear";
      row?: number;
      col?: number;
      block?: boolean;
    }
  | { t: "opts"; opts: Partial<WorkerRenderOptions> }
  | { t: "blink"; on: boolean }
  | { t: "preedit"; text: string; insert: boolean }
  | {
      t: "query";
      id: number;
      kind: "measureCells" | "snapshot" | "selectionText" | "linkAt" | "find" | "cursorAtPrompt";
      arg?: unknown;
    }
  | { t: "dispose" };

/** 워커 → 메인. 백엔드 사건을 그대로 실어 보내되, 프레임은 메인이 쓸 일이 없어 뺀다. */
export type FromWorker =
  | { t: "ready" }
  | { t: "event"; event: Exclude<BackendEvent, { type: "render" }> }
  /**
   * 한 프레임을 그렸다. **셀 버퍼는 싣지 않는다** — 매 프레임 왕복하면 워커로 옮긴 이유가
   * 사라진다(120×40 만 해도 96 KB). 앱이 "화면이 갱신됐다"를 알기에 충분한 것만 보내고,
   * 셀이 필요하면 `snapshot()` 으로 그때 가져간다.
   */
  | { t: "rendered"; meta: FrameMeta }
  | { t: "reply"; id: number; value: unknown }
  | { t: "error"; id?: number; message: string };

export interface WorkerRenderOptions {
  theme: Theme;
  ligatures: boolean;
  fontFamily: string;
  fontSize: number;
  lineHeight: number;
  devicePixelRatio: number;
  cursorShape?: CursorShape;
  scrollback?: number;
  ambiguousWide?: boolean;
}
