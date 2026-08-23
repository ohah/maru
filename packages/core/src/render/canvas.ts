import type { FrameData, SelectionSpan } from "../backend/types";
import { CELL_STRIDE, CellFlag } from "../wasm/exports";
import type { Theme } from "../types";
import { buildPalette, hex, resolveColor, withAlpha } from "./palette";
import type { GlyphSource, Metrics, RenderOptions, Renderer } from "./types";

type Ctx = CanvasRenderingContext2D | OffscreenCanvasRenderingContext2D;

/**
 * 셀 격자를 Canvas에 그린다. `worker: false`는 메인에서, `"full"`은 워커 안에서 **같은 클래스**를
 * 쓴다 — 렌더 로직이 한 벌이라 두 모드가 갈리지 않는다.
 *
 * 규칙 넷(전부 실측으로 얻은 것):
 *  1) 셀 X는 **정수로 스냅**한다. 소수 좌표로 셀마다 `fillRect`를 하면 경계에 안티앨리어싱
 *     틈이 생겨 세로 줄무늬로 보인다.
 *  2) 글자 폭은 **논리 폭**(`cellWidth × cells`)을 쓴다. 정수 스냅한 폭을 주면 반올림만큼
 *     글리프가 가로로 압축된다(8.4 → 8이면 95.2%).
 *  3) ASCII·폭1·같은 스타일은 **run으로 묶어 한 번에** 그린다. 셀마다 `fillText`를 부르면
 *     폰트에 리가처가 있어도 절대 적용되지 않는다.
 *  4) 선택은 **반투명 오버레이**로 배경 위·글자 아래에 얹는다. 배경을 대체하면 256색 띠가 사라진다.
 */
export class CanvasRenderer implements Renderer {
  #ctx: Ctx | null = null;
  #metrics: Metrics | null = null;
  #palette: string[] = buildPalette();
  #themeKey = "";
  #glyphs: GlyphSource | null = null;
  /**
   * 커버리지를 색칠해 둔 캐시. **키에 색이 들어가므로 글리프 수가 아니라 색 수만큼 늘어난다** —
   * btop 처럼 컬럼마다 truecolour 그라데이션을 칠하는 앱에서는 프레임마다 새 항목이 생긴다.
   * 상한을 두고 넘으면 오래된 것부터 버린다(Map 은 삽입 순서를 지킨다). 상한이 없으면 살아 있는
   * OffscreenCanvas 가 수십만 개가 되고, Safari 는 캔버스 예산이 바닥나면 `getContext` 가 null 을
   * 돌려줘 합성 글리프가 통째로 폰트 경로로 떨어진다 — 이 모듈이 막으려던 바로 그 상태다.
   */
  #stamps = new Map<string, OffscreenCanvas | HTMLCanvasElement | null>();

  attach(canvas: HTMLCanvasElement | OffscreenCanvas, metrics: Metrics): void {
    const ctx = canvas.getContext("2d") as Ctx | null;
    if (!ctx) throw new Error("maru-term: 2d 컨텍스트를 만들지 못했다");
    this.#ctx = ctx;
    this.#metrics = metrics;
  }

  setMetrics(metrics: Metrics): void {
    this.#metrics = metrics;
    this.#stamps.clear();
  }

  setGlyphSource(source: GlyphSource | null): void {
    this.#glyphs = source;
    this.#stamps.clear();
  }

  /**
   * 프로시저럴 글리프를 그린다. 그릴 수 없으면 false — 호출자가 폰트 경로로 넘어간다.
   * 커버리지를 색칠한 결과를 캐시해 매 프레임 픽셀을 다시 칠하지 않는다.
   */
  #drawProcedural(
    ctx: Ctx,
    cp: number,
    x: number,
    y: number,
    w: number,
    h: number,
    color: string,
  ): boolean {
    const src = this.#glyphs;
    if (!src || !src.covers(cp)) return false;
    const key = `${cp}:${w}x${h}:${color}`;
    let stamp = this.#stamps.get(key);
    if (stamp === null) return false; // 코어가 안 그리는 글자 — 폰트로 간다
    if (stamp === undefined) {
      const cov = src.coverage(cp, w, h);
      if (!cov) {
        // **null 로 넣는다.** `undefined` 로 두면 `Map.get` 이 미스와 구분되지 않아, 코어가
        // 안 그리는 코드포인트마다 매 프레임 wasm 을 다시 부른다.
        this.#stamps.set(key, null);
        return false;
      }
      const buf =
        typeof OffscreenCanvas !== "undefined"
          ? new OffscreenCanvas(w, h)
          : Object.assign(document.createElement("canvas"), { width: w, height: h });
      const bctx = buf.getContext("2d") as Ctx | null;
      if (!bctx) return false;
      const img = bctx.createImageData(w, h);
      const rgb = Number.parseInt(color.slice(1, 7), 16);
      const r = (rgb >> 16) & 0xff,
        g = (rgb >> 8) & 0xff,
        b = rgb & 0xff;
      for (let i = 0; i < w * h; i++) {
        img.data[i * 4] = r;
        img.data[i * 4 + 1] = g;
        img.data[i * 4 + 2] = b;
        img.data[i * 4 + 3] = cov[i * 4 + 3]!;
      }
      bctx.putImageData(img, 0, 0);
      stamp = buf as OffscreenCanvas;
      this.#stamps.set(key, stamp);
      // 오래된 것부터 버린다. 4096 이면 한 화면의 고유 (글리프, 색) 쌍을 넉넉히 덮는다.
      if (this.#stamps.size > 4096) {
        const oldest = this.#stamps.keys().next().value;
        if (oldest !== undefined) this.#stamps.delete(oldest);
      }
    }
    if (!stamp) return false;
    ctx.drawImage(stamp as CanvasImageSource, x, y);
    return true;
  }

  dispose(): void {
    this.#ctx = null;
    this.#metrics = null;
  }

  draw(frame: FrameData, opts: RenderOptions): void {
    const ctx = this.#ctx;
    const m = this.#metrics;
    if (!ctx || !m) return;

    const theme = opts.theme;
    const key = themeKey(theme);
    if (key !== this.#themeKey) {
      this.#palette = buildPalette(theme);
      this.#themeKey = key;
    }

    const bg = hex(theme.background);
    const fg = hex(theme.foreground);
    const cursorColor = hex(theme.cursor ?? theme.foreground);
    const selBg =
      theme.selectionBackground !== undefined ? hex(theme.selectionBackground) : "#264f78";

    const { cols, rows } = frame.size;
    const cw = m.cellWidth;
    const ch = m.cellHeight;
    const X = (c: number) => Math.round(c * cw);
    const dv = new DataView(frame.cells.buffer, frame.cells.byteOffset, frame.cells.byteLength);
    const cellAt = (i: number) => ({
      cp: dv.getUint32(i * CELL_STRIDE, true),
      fg: dv.getUint32(i * CELL_STRIDE + 4, true),
      bg: dv.getUint32(i * CELL_STRIDE + 8, true),
      flags: dv.getUint32(i * CELL_STRIDE + 12, true),
      link: dv.getUint32(i * CELL_STRIDE + 16, true),
    });

    ctx.fillStyle = bg;
    ctx.fillRect(0, 0, Math.ceil(cols * cw), rows * ch);
    ctx.textBaseline = "alphabetic";

    // ── 패스 1a: 배경 (같은 색 연속 구간을 하나로 병합) ──
    for (let r = 0; r < rows; r++) {
      let runStart = 0;
      let runFill: string | null = null;
      for (let c = 0; c <= cols; c++) {
        let fill: string | null = null;
        if (c < cols) {
          const i = r * cols + c;
          if (i < frame.cellCount) {
            const cell = cellAt(i);
            fill =
              cell.flags & CellFlag.reverse
                ? resolveColor(cell.fg, this.#palette, fg)
                : resolveColor(cell.bg, this.#palette, null);
          }
        }
        if (fill !== runFill) {
          if (runFill) {
            ctx.fillStyle = runFill;
            ctx.fillRect(X(runStart), r * ch, X(c) - X(runStart), ch);
          }
          runStart = c;
          runFill = fill;
        }
      }
    }

    // ── 패스 1b: 선택 오버레이 (배경 위·글자 아래) ──
    if (frame.selection) {
      ctx.fillStyle = withAlpha(selBg, 0.55);
      const sel = frame.selection;
      for (let r = 0; r < rows; r++) {
        let start = -1;
        for (let c = 0; c <= cols; c++) {
          const on = c < cols && inSelection(sel, r, c);
          if (on && start < 0) start = c;
          if (!on && start >= 0) {
            ctx.fillRect(X(start), r * ch, X(c) - X(start), ch);
            start = -1;
          }
        }
      }
    }

    // ── 패스 2: 글리프 (ASCII run 병합 → 리가처가 산다) ──
    for (let r = 0; r < rows; r++) {
      let run = "";
      let runCol = 0;
      let runKey: string | null = null;
      let runFill = fg;
      const flush = () => {
        if (!run) return;
        ctx.fillStyle = runFill;
        ctx.fillText(run, X(runCol), r * ch + m.ascent);
        run = "";
      };
      for (let c = 0; c < cols; c++) {
        const i = r * cols + c;
        if (i >= frame.cellCount) break;
        const cell = cellAt(i);
        if (cell.flags & CellFlag.continuation) continue;
        const w = cell.flags & CellFlag.widthMask || 1;
        const x = X(c);
        const y = r * ch;
        let color = resolveColor(cell.fg, this.#palette, fg) ?? fg;
        if (cell.flags & CellFlag.reverse) color = resolveColor(cell.bg, this.#palette, bg) ?? bg;

        // 장식은 run과 무관하게 셀 단위로
        const cellPx = X(c + w) - x;
        if (cell.flags & CellFlag.underline) {
          ctx.fillStyle = color;
          ctx.fillRect(x, y + ch - 3, cellPx, 1);
        }
        if (cell.link !== 0) {
          ctx.fillStyle = withAlpha(cursorColor, 0.55);
          ctx.fillRect(x, y + ch - 2, cellPx, 1);
        }

        const font = `${cell.flags & CellFlag.bold ? "bold " : ""}${cell.flags & CellFlag.italic ? "italic " : ""}${m.fontSpec}`;
        const isAsciiRun =
          opts.ligatures && cell.cp >= 0x20 && cell.cp < 0x7f && w === 1 && cell.link === 0;
        const key = `${color}|${font}`;
        if (isAsciiRun) {
          if (key !== runKey || run === "") {
            flush();
            runCol = c;
            runKey = key;
            runFill = color;
            ctx.font = font;
          }
          run += String.fromCodePoint(cell.cp);
        } else {
          flush();
          runKey = null;
          if (cell.cp !== 32 && cell.cp !== 0) {
            // 박스 드로잉 등은 **폰트보다 먼저** 코어가 그린다 — 셀을 꽉 채워야 선이 이어진다.
            const pw = X(c + w) - x;
            if (!this.#drawProcedural(ctx, cell.cp, x, y, pw, ch, color)) {
              ctx.font = font;
              ctx.fillStyle = color;
              drawGlyph(ctx, String.fromCodePoint(cell.cp), x, y + m.ascent, cw * w);
            }
          }
        }
      }
      flush();
    }

    // ── 커서 / IME 조합 ──
    const cur = frame.cursor;
    if (opts.preedit) {
      // **조합 텍스트는 화면 버퍼에 넣지 않고 여기서만 그린다.**
      //
      // 코어에 삽입하면 화면을 소유한 앱과 어긋난다 — zsh 는 프롬프트와 입력줄을 자기가
      // 관리하는데, 우리가 ICH/DCH 로 끼어들면 그 다음 앱이 그릴 때 엉뚱한 자리를 밟는다
      // (실측: `echo ` 뒤에 조합을 시작하자 "ec" 가 지워졌다). xterm.js 가 오버레이를 쓰는
      // 이유도 같다.
      //
      // 대신 **커서 뒤 셀을 조합 폭만큼 밀어 그려** 밀리는 것처럼 보이게 한다. 화면 버퍼는
      // 그대로이므로 앱과 어긋나지 않는다.
      ctx.font = m.fontSpec;
      const pre = [...opts.preedit];
      const width = pre.reduce((n, chr) => n + widthOf(chr), 0);
      const rowY = cur.row * ch;

      // 1) 커서부터 줄 끝까지를 배경으로 지우고, 밀어서 다시 그린다.
      ctx.fillStyle = bg;
      ctx.fillRect(X(cur.col), rowY, X(cols) - X(cur.col), ch);
      for (let c = cur.col; c < cols; c++) {
        const i = cur.row * cols + c;
        if (i >= frame.cellCount) break;
        const cell = cellAt(i);
        if (cell.flags & CellFlag.continuation) continue;
        const w = cell.flags & CellFlag.widthMask || 1;
        const to = c + width;
        if (to >= cols) break;
        const x = X(to);
        const color = resolveColor(cell.fg, this.#palette, fg) ?? fg;
        if (cell.cp !== 32 && cell.cp !== 0) {
          ctx.fillStyle = color;
          drawGlyph(ctx, String.fromCodePoint(cell.cp), x, rowY + m.ascent, cw * w);
        }
      }

      // 2) 조합 텍스트를 커서 자리에 그린다 — 반투명 하이라이트 + 밑줄.
      let col = cur.col;
      for (const chr of pre) {
        const w = widthOf(chr);
        const x = X(col);
        const px = X(col + w) - x;
        ctx.fillStyle = withAlpha(cursorColor, 0.3);
        ctx.fillRect(x, rowY, px, ch);
        ctx.fillStyle = fg;
        drawGlyph(ctx, chr, x, rowY + m.ascent, cw * w);
        ctx.fillStyle = cursorColor;
        ctx.fillRect(x, rowY + ch - 2, px, 2);
        col += w;
      }
    } else if (cur.visible && (!cur.blink || (opts.blinkOn ?? true))) {
      // **코어의 blink 상태가 우선이다.** DECSCUSR 로 steady 를 고른 앱(vim 등)의 커서가
      // 호스트 타이머 때문에 깜빡이면 안 된다 — `opts.blinkOn` 은 blink 가 켜졌을 때만 본다.
      drawCursor(ctx, frame, cur, m, cellAt, X, cursorColor, bg);
    }
  }
}

/** span의 끝은 **inclusive**다(코어 규약) — exclusive로 그리면 마지막 칸이 빠진다. */
function inSelection(sel: SelectionSpan, row: number, col: number): boolean {
  if (sel.block) {
    const r0 = Math.min(sel.startRow, sel.endRow);
    const r1 = Math.max(sel.startRow, sel.endRow);
    const c0 = Math.min(sel.startCol, sel.endCol);
    const c1 = Math.max(sel.startCol, sel.endCol);
    return row >= r0 && row <= r1 && col >= c0 && col <= c1;
  }
  if (row < sel.startRow || row > sel.endRow) return false;
  if (row === sel.startRow && col < sel.startCol) return false;
  if (row === sel.endRow && col > sel.endCol) return false;
  return true;
}

/** 셀 폭에 글리프를 맞춘다. 넘치면 가로로 압축하고, 좁으면 칸 안에서 가운데로. */
function drawGlyph(ctx: Ctx, chr: string, x: number, baseline: number, target: number): void {
  const w = ctx.measureText(chr).width;
  if (w <= 0.01) return;
  if (w > target + 0.3) {
    ctx.save();
    ctx.translate(x, 0);
    ctx.scale(target / w, 1);
    ctx.fillText(chr, 0, baseline);
    ctx.restore();
  } else {
    ctx.fillText(chr, x + (target - w) / 2, baseline);
  }
}

type CellReader = (i: number) => { cp: number; flags: number };

/** block 커서는 **반전**이다. 덮기만 하면 아래 글자가 사라진다. */
function drawCursor(
  ctx: Ctx,
  frame: FrameData,
  cur: FrameData["cursor"],
  m: Metrics,
  cellAt: CellReader,
  X: (c: number) => number,
  color: string,
  bg: string,
): void {
  let col = cur.col;
  let cp = 32;
  let w = 1;
  const i = cur.row * frame.size.cols + col;
  if (i >= 0 && i < frame.cellCount) {
    const cell = cellAt(i);
    cp = cell.cp;
    w = cell.flags & CellFlag.widthMask || 1;
    if (cell.flags & CellFlag.continuation && i > 0) {
      const base = cellAt(i - 1);
      cp = base.cp;
      w = base.flags & CellFlag.widthMask || 1;
      col -= 1;
    }
  }
  const x = X(col);
  const px = X(col + w) - x;
  const y = cur.row * m.cellHeight;
  ctx.fillStyle = color;
  if (cur.shape === "underline") {
    ctx.fillRect(x, y + m.cellHeight - 3, px, 3);
  } else if (cur.shape === "bar") {
    ctx.fillRect(x, y, Math.max(2, Math.round(m.cellWidth * 0.18)), m.cellHeight);
  } else {
    ctx.fillRect(x, y, px, m.cellHeight);
    if (cp !== 32 && cp !== 0) {
      ctx.fillStyle = bg;
      ctx.font = m.fontSpec;
      drawGlyph(ctx, String.fromCodePoint(cp), x, y + m.ascent, m.cellWidth * w);
    }
  }
}

/** 조합 텍스트의 셀 폭 어림. 정확한 값은 코어가 알지만 렌더는 동기라 근사한다. */
function widthOf(chr: string): number {
  const cp = chr.codePointAt(0) ?? 32;
  if (cp < 0x1100) return 1;
  return cp >= 0x1100 && cp <= 0x115f
    ? 2
    : cp >= 0x2e80 && cp <= 0xa4cf
      ? 2
      : cp >= 0xac00 && cp <= 0xd7a3
        ? 2
        : cp >= 0xf900 && cp <= 0xfaff
          ? 2
          : cp >= 0xff00 && cp <= 0xff60
            ? 2
            : cp >= 0x1f300 && cp <= 0x1faff
              ? 2
              : 1;
}

function themeKey(t: Theme): string {
  return `${t.foreground}|${t.background}|${(t.palette ?? []).join(",")}`;
}
