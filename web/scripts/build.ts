import { createHash } from "node:crypto";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { emitZntcBundle } from "./zntc-bundle";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const dist = join(root, "dist");
const entry = join(root, "src", "main.ts");

await rm(dist, { recursive: true, force: true });
await mkdir(dist, { recursive: true });

const emitted = await emitZntcBundle(entry, dist);
const scriptName = emitted.name;
const script = emitted.bytes;
const sri = `sha384-${createHash("sha384").update(script).digest("base64")}`;
const sourceHtml = await readFile(join(root, "src", "index.html"), "utf8");
const scriptTag = `<script type="module" src="${scriptName}" integrity="${sri}"></script>`;
const html = sourceHtml.replace("</body>", `  ${scriptTag}\n  </body>`);

await writeFile(join(dist, "index.html"), html);
await writeFile(
  join(dist, "integrity.json"),
  `${JSON.stringify({ [scriptName]: sri }, null, 2)}\n`,
);

console.log(
  JSON.stringify({
    bundler: "@zntc/core@0.1.3",
    bundle: scriptName,
    bytes: script.byteLength,
    sri,
  }),
);
