import { LocalBackend } from "../core/src/backend/local";
import { Terminal } from "../core/src/terminal";
import { readFile } from "node:fs/promises";
import type { WasmExports } from "../core/src/wasm/exports";
import type { Size } from "../core/src/types";

/**
 * 테스트용 wasm 경로. `import.meta.url` 기반 기본값은 번들 후 위치를 가리키므로,
 * 소스 트리에서 도는 테스트는 커밋된 바이너리를 직접 가리킨다.
 */
export const WASM_URL = new URL("../core/wasm/maru-vt.wasm", import.meta.url);

/** wasm 을 직접 물어야 하는 계약(합성 글리프 범위 등)을 위한 로더. */
export async function loadWasm(): Promise<WasmExports> {
  const buf = await readFile(WASM_URL);
  const { instance } = await WebAssembly.instantiate(buf, {});
  return instance.exports as unknown as WasmExports;
}

export async function makeTerminal(size: Size = { cols: 40, rows: 8 }): Promise<Terminal> {
  const term = new Terminal({ ...size, wasmUrl: WASM_URL });
  const backend = await LocalBackend.create(size, WASM_URL);
  term.attachBackend(backend);
  return term;
}

/** 프레임 발행이 마이크로태스크로 접히므로, 단언 전에 한 번 넘긴다. */
export const settle = (): Promise<void> => new Promise((r) => queueMicrotask(() => r()));

/** 한 행을 텍스트로. continuation 셀은 건너뛴다(2셀 문자의 뒤쪽). */
export function rowText(
  cells: { codepoint: number; flags: number }[],
  cols: number,
  row: number,
): string {
  let out = "";
  for (let c = 0; c < cols; c++) {
    const cell = cells[row * cols + c];
    if (!cell || cell.flags & (1 << 8)) continue;
    out += String.fromCodePoint(cell.codepoint);
  }
  return out.replace(/\s+$/, "");
}
