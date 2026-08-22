import type { WasmExports } from "../wasm/exports";
import type { GlyphSource } from "./types";

/**
 * 박스 드로잉·파워라인 같은 글자를 **폰트 없이** 그린다.
 *
 * 왜 필요한가: 이 글자들은 셀을 꽉 채워야 선이 이어지는데, 폰트가 그리면 advance 가 셀 폭과
 * 달라 가운데 정렬되고 양옆에 틈이 생긴다(표의 가로선이 끊겨 보인다). 코어는 셀 크기를 받아
 * 그 안을 채우는 커버리지를 계산하므로 폰트가 무엇이든 이음매가 맞는다.
 */
export function wasmGlyphSource(w: WasmExports): GlyphSource {
  // 캐시 키는 코드포인트+크기다. 같은 셀 크기에서 같은 글자가 반복되므로 적중률이 높다.
  const cache = new Map<string, Uint8Array | null>();
  const coverCache = new Map<number, boolean>();
  return {
    covers(cp: number): boolean {
      // **범위를 JS에서 다시 쓰지 않는다.** 코어의 `isSynthesizedCodepoint`가 단일 출처이고,
      // 여기에 복제하면 계열이 늘 때마다 어긋난다(실제로 박스만 덮다가 파워라인을 놓쳤다).
      if (cp < 0x2500) return false; // ASCII 는 묻지 않는다 — 호출 비용이 대부분이다
      let hit = coverCache.get(cp);
      if (hit === undefined) {
        hit = w.glyph_covers(cp) !== 0;
        coverCache.set(cp, hit);
      }
      return hit;
    },
    coverage(cp: number, width: number, height: number): Uint8Array | null {
      const key = `${cp}:${width}x${height}`;
      const hit = cache.get(key);
      if (hit !== undefined) return hit;
      const px =
        w.glyph_box(cp, width, height) > 0
          ? new Uint8Array(w.memory.buffer, w.glyph_ptr(), width * height * 4).slice()
          : null;
      cache.set(key, px);
      return px;
    },
  };
}
