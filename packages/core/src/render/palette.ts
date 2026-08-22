import type { Theme } from "../types";

/** xterm 256색 기본 팔레트. 테마가 앞 16칸을 덮을 수 있다. */
export function buildPalette(theme?: Theme): string[] {
  // **`src/color.zig` 의 `ansi16` 과 같은 값이어야 한다.** 같은 코어가 낸 `\e[31m` 이 네이티브
  // maru 와 이 라이브러리에서 다른 색으로 보이면 안 된다. 전에는 VS Code 테이블을 쓰고 있어
  // 16칸 중 15칸이 달랐다(예: idx1 이 0x800000 vs 0xcd3131).
  const base = [
    0x000000, 0x800000, 0x008000, 0x808000, 0x000080, 0x800080, 0x008080, 0xc0c0c0, 0x808080,
    0xff0000, 0x00ff00, 0xffff00, 0x0000ff, 0xff00ff, 0x00ffff, 0xffffff,
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
