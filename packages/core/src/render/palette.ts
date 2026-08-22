import type { Theme } from "../types";

/** xterm 256색 기본 팔레트. 테마가 앞 16칸을 덮을 수 있다. */
export function buildPalette(theme?: Theme): string[] {
  const base = [
    0x000000, 0xcd3131, 0x0dbc79, 0xe5e510, 0x2472c8, 0xbc3fbc, 0x11a8cd, 0xe5e5e5, 0x666666,
    0xf14c4c, 0x23d18b, 0xf5f543, 0x3b8eea, 0xd670d6, 0x29b8db, 0xf5f5f5,
  ];
  const out: string[] = [];
  for (let i = 0; i < 16; i++) out.push(hex(theme?.palette?.[i] ?? base[i]!));
  const steps = [0, 95, 135, 175, 215, 255];
  for (let i = 0; i < 216; i++) {
    const r = steps[Math.floor(i / 36)]!;
    const g = steps[Math.floor(i / 6) % 6]!;
    const b = steps[i % 6]!;
    out.push(hex((r << 16) | (g << 8) | b));
  }
  for (let i = 0; i < 24; i++) {
    const v = 8 + i * 10;
    out.push(hex((v << 16) | (v << 8) | v));
  }
  return out;
}

export function hex(n: number): string {
  return `#${(n >>> 0).toString(16).padStart(6, "0")}`;
}

/** `#rrggbb` + 알파 → `#rrggbbaa`. Canvas는 8자리 hex를 받는다. */
export function withAlpha(color: string, alpha: number): string {
  const a = Math.round(Math.max(0, Math.min(1, alpha)) * 255);
  return color.slice(0, 7) + a.toString(16).padStart(2, "0");
}

/**
 * 셀이 든 색 워드를 CSS 색으로. 0=기본(호출자가 준 fallback), 0x01xxxxxx=팔레트 인덱스,
 * 0x02rrggbb=직접 RGB.
 */
export function resolveColor(
  word: number,
  palette: string[],
  fallback: string | null,
): string | null {
  const kind = word >>> 24;
  if (kind === 0) return fallback;
  if (kind === 1) return palette[word & 0xff] ?? fallback;
  return hex(word & 0xffffff);
}
