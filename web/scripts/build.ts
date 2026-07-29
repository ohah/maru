import { createHash } from "node:crypto";
import { copyFile, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { emitZntcBundle } from "./zntc-bundle";
import { buildRuntimeNotices } from "./runtime-notices";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const dist = join(root, "dist");
const entry = join(root, "src", "main.ts");
const mermaidHelperEntry = join(root, "src", "mermaid-helper.ts");

await rm(dist, { recursive: true, force: true });
await mkdir(dist, { recursive: true });

const emitted = await emitZntcBundle(entry, dist);
const mermaidHelperEmitted = await emitZntcBundle(mermaidHelperEntry, dist, "mermaid-helper.js");
const mermaidRuntime = await readFile(
  join(root, "node_modules", "mermaid", "dist", "mermaid.min.js"),
);
const mermaidHelperBytes = Buffer.concat([
  mermaidRuntime,
  Buffer.from("\n", "utf8"),
  mermaidHelperEmitted.bytes,
]);
await writeFile(join(dist, mermaidHelperEmitted.name), mermaidHelperBytes);
const scriptName = emitted.name;
const script = emitted.bytes;
const sri = `sha384-${createHash("sha384").update(script).digest("base64")}`;
const mermaidHelperSri = `sha384-${createHash("sha384")
  .update(mermaidHelperBytes)
  .digest("base64")}`;
const scriptTag = `<script type="module" src="${scriptName}" integrity="${sri}"></script>`;
for (const page of ["index.html", "render.html"]) {
  const sourceHtml = await readFile(join(root, "src", page), "utf8");
  const html = sourceHtml.replace("</body>", `  ${scriptTag}\n  </body>`);
  await writeFile(join(dist, page), html);
}
await copyFile(join(root, "src", "app.css"), join(dist, "app.css"));
await writeFile(join(dist, "THIRD_PARTY_NOTICES.txt"), await buildRuntimeNotices(root));
await writeFile(
  join(dist, "integrity.json"),
  `${JSON.stringify(
    {
      [scriptName]: sri,
      [mermaidHelperEmitted.name]: mermaidHelperSri,
    },
    null,
    2,
  )}\n`,
);

console.log(
  JSON.stringify({
    bundler: "@zntc/core@0.1.4",
    bundle: scriptName,
    bytes: script.byteLength,
    sri,
    mermaidHelperBundle: mermaidHelperEmitted.name,
    mermaidHelperBytes: mermaidHelperBytes.byteLength,
    mermaidHelperSri,
  }),
);
