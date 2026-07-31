//! E0.5A 스모크 **전용 asset root**를 만든다(docs/editor-surface.md §7.4).
//!
//! 제품 `dist/`와 분리하는 이유: 하니스는 제품 UI가 아니다. `web:build`의 산출물 집합은 닫힌 집합으로 검증되고
//! (`verify-build.ts`) 그 집합에 계측 페이지를 끼워 넣으면 신뢰 origin에 제품이 쓰지 않는 문서가 하나 늘어난다.
//! 대신 같은 번들러·같은 파일 배치(flat)로 별도 root를 만들어, 네이티브 스모크가 **제품 스킴 핸들러와 제품 CSP**에
//! 그 root만 물린다 — 검증하는 경로는 제품 그대로이고 제품 자산은 그대로 둔다.
//!
//! 사용: `bun run scripts/build-editor-smoke.ts <outdir>`

import { createHash } from "node:crypto";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { dirname, isAbsolute, join } from "node:path";
import { fileURLToPath } from "node:url";
import { emitZntcBundle } from "./zntc-bundle";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const outArg = process.argv[2];
if (outArg === undefined) throw new Error("usage: build-editor-smoke.ts <outdir>");
const outdir = isAbsolute(outArg) ? outArg : join(process.cwd(), outArg);

await rm(outdir, { recursive: true, force: true });
await mkdir(outdir, { recursive: true });

const emitted = await emitZntcBundle(join(root, "src", "editor-smoke-entry.ts"), outdir);
const sri = `sha384-${createHash("sha384").update(emitted.bytes).digest("base64")}`;
const page = await readFile(join(root, "src", "editor-smoke.html"), "utf8");
// 제품 페이지와 같은 방식으로 SRI를 핀한다 — 번들이 바뀌면 로드가 실패해야 하고, 그 실패가 게이트에 잡혀야 한다.
await writeFile(
  join(outdir, "index.html"),
  page.replace(
    "</body>",
    `  <script type="module" src="bundle.js" integrity="${sri}"></script>\n  </body>`,
  ),
);

// 하니스 전용 CSS. 제품 app.css(Tailwind 산출물)를 끌어오지 않는다 — 하니스가 제품 스타일 변화에 흔들리면
// "MergeView가 표시된다"는 판정이 남의 변경으로 깨진다. 여기서 재는 것은 CM6가 만든 layout뿐이므로 최소만 둔다.
await writeFile(
  join(outdir, "app.css"),
  [
    "html, body { margin: 0; height: 100%; background: Canvas; color: CanvasText; }",
    "#diff-harness { display: flex; flex-direction: column; gap: 12px; height: 100%; padding: 8px; box-sizing: border-box; }",
    "#diff-split, #diff-unified { flex: 1 1 0; min-height: 120px; overflow: auto; }",
    "",
  ].join("\n"),
);

console.log(
  JSON.stringify({ outdir, bundle_bytes: emitted.bytes.byteLength, bundle_sri: sri }, null, 0),
);
