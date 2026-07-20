import { expect, test } from "bun:test";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { emitZntcBundle } from "../scripts/zntc-bundle";

test("zntc diagnostics fail closed before an invalid bundle reaches disk", async () => {
  const root = await mkdtemp(join(tmpdir(), "maru-zntc-error-"));
  const entry = join(root, "main.ts");
  const dist = join(root, "dist");

  try {
    await writeFile(entry, `import "./missing";\nexport const unreachable = true;\n`);
    await mkdir(dist);

    await expect(emitZntcBundle(entry, dist)).rejects.toThrow("unresolved_import");
    await expect(readFile(join(dist, "bundle.js"))).rejects.toThrow();
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("live preview worker bundle selects DOM-free worker package exports", async () => {
  const root = await mkdtemp(join(tmpdir(), "maru-zntc-worker-"));
  const entry = join(import.meta.dir, "..", "src", "live-preview-worker.ts");
  try {
    const emitted = await emitZntcBundle(entry, root, "live-preview-worker.js", ["worker"]);
    const worker = new Worker(pathToFileURL(join(root, emitted.name)).href, { type: "module" });
    const result = await new Promise<unknown>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("worker response timeout")), 2_000);
      worker.onmessage = (event) => {
        clearTimeout(timer);
        resolve(event.data);
      };
      worker.onerror = (event) => {
        clearTimeout(timer);
        reject(event.error ?? new Error(event.message));
      };
      worker.postMessage({
        type: "seed",
        editorEpoch: 1,
        documentRevision: 0,
        source: "# worker",
      });
    });
    worker.terminate();
    expect(result).toEqual({
      type: "result",
      editorEpoch: 1,
      documentRevision: 0,
      projectionGeneration: 0,
      results: [],
      rejected: [],
    });
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("Mermaid helper stays isolated from trusted origins and universal packaging preserves its seal", async () => {
  const repository = join(import.meta.dir, "..", "..");
  const source = await readFile(join(import.meta.dir, "..", "src", "mermaid-helper.ts"), "utf8");
  const build = await readFile(join(import.meta.dir, "..", "scripts", "build.ts"), "utf8");
  const nativeBuild = await readFile(join(repository, "build.zig"), "utf8");
  const appScheme = await readFile(join(repository, "src", "session", "app_scheme.zig"), "utf8");
  const universalBuild = await readFile(
    join(repository, "tools", "build-macos-universal-dmg.sh"),
    "utf8",
  );
  expect(source).toContain("window.__maruRenderMermaid");
  expect(source).toContain("sanitizeMermaidSvg");
  expect(build).toContain('"mermaid-helper.js"');
  expect(nativeBuild).toContain("helper-only Mermaid runtime leaked into main app resources");
  expect(nativeBuild).toContain("Mermaid runtime must have exactly one nested-helper copy");
  expect(appScheme).toContain('eqlIgnoreCase(normalized_path, "mermaid-helper.js")');
  expect(universalBuild).toContain('helper_rel="Contents/Helpers/MaruMermaidRenderer.app"');
  expect(universalBuild).toContain(
    'cmp "$work/arm.app/$helper_rel/Contents/Resources/web/mermaid-helper.js"',
  );
  expect(universalBuild).toContain(
    "--entitlements src/platform/macos/MaruMermaidRenderer.entitlements",
  );
  expect(universalBuild).toContain("codesign --verify --strict --deep");
});

test("atomic renderer mode removes document viewport padding and legacy fragment selectors", async () => {
  const css = await readFile(join(import.meta.dir, "..", "src", "app.css"), "utf8");
  expect(css).toContain('body[data-renderer-mode="atomic"] #app');
  expect(css).not.toContain('body[data-renderer-mode="fragment"]');
});
