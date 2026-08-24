import type { FrameData } from "../backend/types";
import type { Theme } from "../types";

/** 실측한 셀 기하. 폰트가 바뀌면 다시 잰다. */
export interface Metrics {
  /** 셀 너비(px, 소수). `measureText("M").width` */
  cellWidth: number;
  /** 셀 높이(px, 정수). ascent+descent에 줄간격을 곱한 값. */
  cellHeight: number;
  /** baseline 위치(px). */
  ascent: number;
  fontSpec: string;
  devicePixelRatio: number;
}

export interface RenderOptions {
  theme: Theme;
  ligatures: boolean;
  /** IME 조합 중인 텍스트. 코어에 이미 삽입돼 있고 여기서는 강조만 한다. */
  preedit?: string;
  /** 커서 깜빡임의 현재 위상. false면 커서를 그리지 않는다. */
  blinkOn?: boolean;
  /**
   * 이 프레임에 얹을 장식(뷰포트 좌표로 이미 접혀 있다). 배경은 셀 배경 **뒤**, 선택 **앞**에
   * 깔린다 — 선택이 장식을 덮어야 사용자가 지금 무엇을 잡았는지 헷갈리지 않는다.
   */
  decorations?: import("../decoration").DecorationSpan[];
}

/** 코어가 계산해 주는 글리프 커버리지. 폰트 없이 셀을 꽉 채우는 선을 얻는다. */
export interface GlyphSource {
  /** 이 코드포인트를 코어가 그릴 수 있는가. */
  covers(cp: number): boolean;
  /** RGBA 커버리지를 만든다. 그릴 게 없으면 null. */
  coverage(cp: number, width: number, height: number): Uint8Array | null;
}

export interface Renderer {
  attach(canvas: HTMLCanvasElement | OffscreenCanvas, metrics: Metrics): void;
  /** 프로시저럴 글리프 공급자를 꽂는다. 없으면 폰트로만 그린다. */
  setGlyphSource?(source: GlyphSource | null): void;
  draw(frame: FrameData, opts: RenderOptions): void;
  dispose(): void;
}
