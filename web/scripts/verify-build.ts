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
const pages = await Promise.all(
  ["index.html", "render.html"].map((page) => readFile(join(dist, page), "utf8")),
);
await readFile(join(dist, "app.css"), "utf8");
const notices = await readFile(join(dist, "THIRD_PARTY_NOTICES.txt"), "utf8");

if (actualSri !== pinnedSri) throw new Error("bundle bytes do not match integrity.json");
if (pages.some((html) => !html.includes(`src="${bundleName}" integrity="${pinnedSri}"`))) {
  throw new Error("every HTML entry must pin the emitted bundle SRI");
}
if (!notices.includes("dompurify@3.4.12") || notices.includes("@zntc/core@0.1.3")) {
  throw new Error("runtime notices must cover production dependencies only");
}

console.log(
  JSON.stringify({ verified: true, bundle: bundleName, bytes: bundle.byteLength, sri: actualSri }),
);
