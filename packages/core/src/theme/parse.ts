import type { Theme } from "../types";

/**
 * Ghostty 계열 테마 파일을 읽는다. iTerm2-Color-Schemes를 vendoring한 형식이고,
 * Ghostty가 배포하는 수백 개 테마를 그대로 쓸 수 있다.
 *
 * ```
 * palette = 0=#21222c
 * background = #282a36
 * foreground = #f8f8f2
 * cursor-color = #ff79c6
 * selection-background = #44475a
 * ```
 *
 * 인식하지 못하는 줄은 조용히 건너뛴다 — 테마 파일에는 이 라이브러리가 쓰지 않는 키
 * (`cursor-text`, `bold-is-bright` 등)가 섞여 있다.
 */
export function parseGhosttyTheme(text: string): Theme | null {
  const palette: (number | undefined)[] = Array.from({ length: 16 });
  let foreground: number | undefined;
  let background: number | undefined;
  let cursor: number | undefined;
  let selectionBackground: number | undefined;
  let selectionForeground: number | undefined;

  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;

    const pal = /^palette\s*=\s*(\d+)\s*=\s*#?([0-9a-fA-F]{6})$/.exec(line);
    if (pal) {
      const idx = Number(pal[1]);
      if (idx >= 0 && idx < 16) palette[idx] = Number.parseInt(pal[2]!, 16);
      continue;
    }

    const kv = /^([a-z-]+)\s*=\s*#?([0-9a-fA-F]{6})$/.exec(line);
    if (!kv) continue;
    const value = Number.parseInt(kv[2]!, 16);
    switch (kv[1]) {
      case "foreground":
        foreground = value;
        break;
      case "background":
        background = value;
        break;
      case "cursor-color":
        cursor = value;
        break;
      case "selection-background":
        selectionBackground = value;
        break;
      case "selection-foreground":
        selectionForeground = value;
        break;
      default:
        break;
    }
  }

  // 전경·배경이 없으면 테마로 쓸 수 없다.
  if (foreground === undefined || background === undefined) return null;
  return {
    foreground,
    background,
    cursor: cursor ?? foreground,
    selectionBackground,
    selectionForeground,
    palette: palette.some((c) => c !== undefined) ? palette : undefined,
  };
}
