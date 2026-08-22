/** @jsxImportSource react */
/**
 * React 픽스처의 진입점. react·react-dom 은 브라우저에서 바로 불러올 ESM 진입점이 없어
 * (19 기준 CJS 뿐) 이 파일을 번들해서 픽스처가 로드한다.
 */
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { MaruTerminal } from "@maru/react";

const g = globalThis as { __term?: unknown; __ready?: boolean };

createRoot(document.getElementById("app")!).render(
  <StrictMode>
    <MaruTerminal
      options={{ cols: 50, rows: 15, worker: false, wasmUrl: "/core/wasm/maru-vt.wasm" }}
      onReady={(t) => {
        g.__term = t;
      }}
      style={{ width: "520px", height: "400px", display: "block" }}
    />
  </StrictMode>,
);

void (async () => {
  const start = Date.now();
  while (!g.__term && Date.now() - start < 10_000) await new Promise((r) => setTimeout(r, 50));
  (g.__term as { write: (s: string) => void } | undefined)?.write("react ok\r\n");
  await new Promise((r) => setTimeout(r, 200));
  g.__ready = true;
})();
