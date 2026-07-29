import { createHash } from "node:crypto";
import { readFile, readdir } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const dist = join(root, "dist");
const manifest = JSON.parse(await readFile(join(dist, "integrity.json"), "utf8")) as Record<
  string,
  string
>;
const entries = Object.entries(manifest);
if ((await readdir(dist, { withFileTypes: true })).some((entry) => entry.isDirectory())) {
  throw new Error("web dist must remain flat for the no-follow custom-scheme reader");
}

if (entries.length !== 2)
  throw new Error("integrity manifest must contain shell and Mermaid helper bundles");
if (!("bundle.js" in manifest) || !("mermaid-helper.js" in manifest)) {
  throw new Error("integrity manifest bundle names are not the pinned closed set");
}

// web bundle 예산(docs/file-panel.md §2.1c). React·Tailwind 도입으로 번들이 커지므로 상한을 게이트로 둔다 —
// 넘으면 그 PR에서 근거를 대거나 코드 분할을 한다. 로컬 스킴 로드라 네트워크 비용은 없지만 파싱 시간은
// 첫 paint에 들어간다. Mermaid helper는 별도 프로세스 전용이라 이 예산 밖이다.
const shellBundleBudgetBytes = 3 * 1024 * 1024;

const verifiedBundles = await Promise.all(
  entries.map(async ([bundleName, pinnedSri]) => {
    const bundle = await readFile(join(dist, bundleName));
    const actualSri = `sha384-${createHash("sha384").update(bundle).digest("base64")}`;
    if (actualSri !== pinnedSri) throw new Error(`${bundleName} bytes do not match integrity.json`);
    return { bundleName, bytes: bundle.byteLength, sri: actualSri };
  }),
);
const pages = await Promise.all(
  ["index.html", "render.html"].map((page) => readFile(join(dist, page), "utf8")),
);
await readFile(join(dist, "app.css"), "utf8");
const notices = await readFile(join(dist, "THIRD_PARTY_NOTICES.txt"), "utf8");

if (pages.some((html) => !html.includes(`src="bundle.js" integrity="${manifest["bundle.js"]}"`))) {
  throw new Error("every HTML entry must pin the emitted bundle SRI");
}
const shellBundle = verifiedBundles.find(({ bundleName }) => bundleName === "bundle.js");
if (shellBundle !== undefined && shellBundle.bytes > shellBundleBudgetBytes) {
  throw new Error(
    `shell bundle ${shellBundle.bytes} bytes exceeds the ${shellBundleBudgetBytes} byte budget (docs/file-panel.md §2.1c)`,
  );
}
if (pages.some((html) => html.includes("mermaid-helper.js"))) {
  throw new Error("the Mermaid helper bundle must not be loaded as a document script");
}
if (!notices.includes("dompurify@3.4.12") || notices.includes("@zntc/core@0.1.4")) {
  throw new Error("runtime notices must cover production dependencies only");
}

console.log(JSON.stringify({ verified: true, bundles: verifiedBundles }));
