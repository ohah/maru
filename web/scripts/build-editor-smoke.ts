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
    // 제품에서는 native가 터미널 테마에서 파생해 주입하는 변수다(syntax_theme.writeCssVarsJs). 게이트도 같은
    // 변수를 정의해, 스크린샷이 "변수를 쓰는 경로"를 실제로 지나가게 한다(폴백만 보고 통과하지 않게).
    ":root { --maru-diff-added: #3fb950; --maru-diff-removed: #f85149; }",
    "html, body { margin: 0; height: 100%; background: Canvas; color: CanvasText; }",
    "#diff-harness { display: flex; flex-direction: column; gap: 12px; height: 100%; padding: 8px; box-sizing: border-box; }",
    // 제품 app.css(.diff-merge …)와 **같은 규칙**: 각 편집기가 자기 안에서 스크롤한다 — 그래야 가로 막대가
    // 문서 맨 아래가 아니라 보이는 영역 아래에 있다. merge의 auto !important를 우리 쪽 !important로 되돌린다.
    "#diff-split, #diff-unified { flex: 1 1 0; min-height: 0; overflow: hidden; }",
    "#diff-split .cm-mergeView, #diff-split .cm-mergeViewEditors, #diff-split .cm-mergeViewEditor { height: 100%; min-height: 0; }",
    "#diff-split .cm-mergeViewEditor > .cm-editor, #diff-split .cm-mergeViewEditor > .cm-editor > .cm-scroller { height: 100% !important; }",
    "#diff-split .cm-mergeViewEditor > .cm-editor > .cm-scroller { overflow: auto !important; }",
    "#diff-split .cm-mergeViewEditor + .cm-mergeViewEditor { border-left: 1px solid color-mix(in srgb, CanvasText 14%, transparent); }",
    "#diff-unified .cm-editor, #diff-unified .cm-editor > .cm-scroller { height: 100% !important; }",
    "",
  ].join("\n"),
);

console.log(
  JSON.stringify({ outdir, bundle_bytes: emitted.bytes.byteLength, bundle_sri: sri }, null, 0),
);
