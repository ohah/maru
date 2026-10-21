import type { MouseReport } from "../backend/types";

/** 마우스 보고에 필요한 DOM 사건 필드. 테스트에서 MouseEvent 없이 만든다. */
export type MouseEventLike = Pick<
  MouseEvent,
  "button" | "buttons" | "shiftKey" | "altKey" | "ctrlKey"
>;

/**
 * DOM 마우스 사건을 코어 보고로 옮긴다(좌 0 · 중 1 · 우 2).
 *
 * 버튼 없이 움직인 사건(1003 any-event 호버)은 xterm 규약대로 "버튼 없음"(3)의 이동으로 보낸다.
 * DOM 은 누른 버튼이 없어도 `button` 을 0(왼쪽)으로 주므로, 그대로 넘기면 SGR `ESC[<32;x;ym`
 * — 왼쪽 버튼 끌기 — 가 되어 Claude Code 처럼 이동 보고를 켠 앱이 호버를 드래그로 읽고 커서를
 * 옮긴다. 코어는 이동 보고의 끝 글자를 `pressed` 로 고르므로 버튼 없음 이동은 `M` 으로 낸다
 * (`ESC[<35;x;yM`, xterm ctlseqs "Mouse Tracking" — any-event 모드의 버튼 없는 이동).
 */
export function mouseReport(
  ev: MouseEventLike,
  row: number,
  col: number,
  pressed: boolean,
  motion: boolean,
): MouseReport {
  const hover = motion && ev.buttons === 0;
  let button = 0;
  if (hover) button = 3;
  else if (ev.button === 1 || ev.button === 2) button = ev.button;
  return {
    button,
    col,
    row,
    pressed: hover || pressed,
    motion,
    mods: (ev.shiftKey ? 1 : 0) | (ev.altKey ? 2 : 0) | (ev.ctrlKey ? 4 : 0),
  };
}
