import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const dist = join(root, "dist");
const manifest = JSON.parse(await readFile(join(dist, "integrity.json"), "utf8")) as Record<
  string,
  string
>;
const entries = Object.entries(manifest);

if (entries.length !== 1) throw new Error("integrity manifest must contain exactly one bundle");

const [bundleName, pinnedSri] = entries[0];
const bundle = await readFile(join(dist, bundleName));
const actualSri = `sha384-${createHash("sha384").update(bundle).digest("base64")}`;
const html = await readFile(join(dist, "index.html"), "utf8");

if (actualSri !== pinnedSri) throw new Error("bundle bytes do not match integrity.json");
if (!html.includes(`src="${bundleName}" integrity="${pinnedSri}"`)) {
  throw new Error("index.html does not pin the emitted bundle SRI");
}

console.log(
  JSON.stringify({ verified: true, bundle: bundleName, bytes: bundle.byteLength, sri: actualSri }),
);
