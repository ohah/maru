import { createHash } from "node:crypto";
import { mkdir, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "@zntc/core";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const dist = join(root, "dist");
const entry = join(root, "src", "main.ts");

await rm(dist, { recursive: true, force: true });
await mkdir(dist, { recursive: true });

await build({
  entryPoints: [entry],
  bundle: true,
  format: "esm",
  platform: "browser",
  target: ["safari16"],
  outdir: dist,
  minify: true,
  sourcemap: false,
});

const files = await readdir(dist);
const scriptName = files.find((name) => name.endsWith(".js") && !name.endsWith(".js.map"));
if (scriptName === undefined) throw new Error("zntc did not emit a JavaScript bundle");

const script = await readFile(join(dist, scriptName));
const sri = `sha384-${createHash("sha384").update(script).digest("base64")}`;
const sourceHtml = await readFile(join(root, "src", "index.html"), "utf8");
const scriptTag = `<script type="module" src="${basename(scriptName)}" integrity="${sri}"></script>`;
const html = sourceHtml.replace("</body>", `  ${scriptTag}\n  </body>`);

await writeFile(join(dist, "index.html"), html);
await writeFile(
  join(dist, "integrity.json"),
  `${JSON.stringify({ [basename(scriptName)]: sri }, null, 2)}\n`,
);

console.log(
  JSON.stringify({
    bundler: "@zntc/core@0.1.3",
    bundle: basename(scriptName),
    bytes: script.byteLength,
    sri,
  }),
);
