import type { Metrics } from "./types";

export interface MetricsInput {
  fontFamily: string;
  fontSize: number;
  lineHeight: number;
  devicePixelRatio?: number;
}

/**
 * 기본 폰트 체인 — **리가처가 있는 폰트를 앞에 둔다.**
 *
 * 앞쪽은 Nerd Font 패치본(아이콘 + 리가처), 그다음이 순정 리가처 폰트, 마지막이 리가처 없는
 * 표준 고정폭이다. 설치된 것 중 가장 앞의 하나가 잡히므로, 사용자가 무엇을 깔아 뒀든
 * `=>` `!==` `<--` 같은 연산자가 이어져 보인다.
 *
 * 리가처는 폰트마다 구현 피처가 다르다 — JetBrains Mono 는 `liga` 가 아니라 `calt` 로 넣는다
 * (Nerd Font 패치본의 GSUB 확인). Canvas 는 둘 다 적용하므로 렌더러가 따로 할 일은 없다.
 */
export const DEFAULT_FONT = [
  // 라틴 — maru 본체의 `font.family` 기본값이 맨 앞이다
  '"JetBrains Mono"',
  '"JetBrainsMono Nerd Font"', // 같은 폰트의 아이콘 패치본
  // **한글** — 본체의 `font.fallback` 기본값. 한글을 라틴 2배 폭으로 디자인해 등폭 격자에
  // 정확히 맞는다. 이게 없으면 시스템 cascade 가 한글을 비례 폰트(Apple SD Gothic Neo)로
  // 그려서 셀마다 여백이 남는다 — 13pt 에서 글자당 4.76px(본체 실측, docs/font-strategy.md).
  // 앞의 라틴 폰트가 한글 글리프를 갖지 않으므로 자동으로 여기로 넘어온다.
  "Jetendard",
  // 나머지 리가처 폰트
  '"FiraCode Nerd Font"',
  '"CaskaydiaCove Nerd Font"', // Cascadia Code 의 Nerd 이름
  '"Hack Nerd Font"',
  '"Iosevka Nerd Font"',
  '"Fira Code"',
  '"Cascadia Code"',
  '"Victor Mono"',
  '"Iosevka"',
  '"Hasklig"',
  '"Monoid"',
  '"Recursive Mono Casual Static"',
  // 리가처는 없지만 품질 좋은 고정폭
  "ui-monospace",
  '"SF Mono"',
  '"IBM Plex Mono"',
  '"Source Code Pro"',
  "Menlo",
  "Consolas",
  "monospace",
].join(",");

/**
 * 셀 기하를 **실측한다**. 하드코딩하면 폰트·크기마다 격자가 어긋난다 — 같은 20px라도
 * JetBrains Mono는 12.00×32, SF Mono는 12.04×30이다(실측).
 */
export function measureMetrics(input: MetricsInput, ctx?: CanvasRenderingContext2D): Metrics {
  const fontSpec = `${input.fontSize}px ${input.fontFamily}`;
  const c = ctx ?? probeContext();
  c.font = fontSpec;
  const m = c.measureText("M");
  const ascent = m.fontBoundingBoxAscent ?? m.actualBoundingBoxAscent ?? input.fontSize * 0.8;
  const descent = m.fontBoundingBoxDescent ?? m.actualBoundingBoxDescent ?? input.fontSize * 0.2;
  return {
    cellWidth: m.width,
    cellHeight: Math.ceil((ascent + descent) * input.lineHeight),
    ascent,
    fontSpec,
    devicePixelRatio: input.devicePixelRatio ?? 1,
  };
}

function probeContext(): CanvasRenderingContext2D {
  const canvas =
    typeof OffscreenCanvas !== "undefined"
      ? (new OffscreenCanvas(8, 8) as unknown as HTMLCanvasElement)
      : document.createElement("canvas");
  const ctx = canvas.getContext("2d");
  if (!ctx) throw new Error("maru-term: 2d 컨텍스트를 만들지 못했다");
  return ctx as CanvasRenderingContext2D;
}
