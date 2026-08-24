export { Terminal } from "./terminal";
export { mountTerminal, type TerminalProps } from "./wrapper";
export { LocalBackend } from "./backend/local";
export { instantiate as instantiateWasm, defaultWasmUrl } from "./wasm/loader";
export { CELL_STRIDE, CellFlag } from "./wasm/exports";
export { CanvasRenderer } from "./render/canvas";
export type { Decoration, DecorationOptions, DecorationSpan, Marker } from "./decoration";
export { DEFAULT_FONT, measureMetrics } from "./render/metrics";
export { buildPalette, hex, withAlpha } from "./render/palette";
export { attachDom } from "./dom/attach";
export { WorkerBackend, canUseWorker } from "./worker/proxy";
export { toKeyInput } from "./dom/keymap";
export { parseGhosttyTheme } from "./theme/parse";
export { themes, type PresetName } from "./theme/presets";
export type { Metrics, RenderOptions, Renderer } from "./render/types";
export type { AttachOptions, DomHost, DomTarget } from "./dom/attach";
export type { WasmExports } from "./wasm/exports";
export type { Backend, BackendEvent, FrameData, MouseReport, SelectionSpan } from "./backend/types";
export type {
  Cell,
  CursorShape,
  CursorState,
  Disposable,
  FallbackReason,
  KeyInput,
  Size,
  Snapshot,
  TerminalOptions,
  Theme,
} from "./types";
export { bundledFontUrl, loadBundledFont } from "./font";
