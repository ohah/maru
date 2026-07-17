import { expect, test } from "bun:test";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
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
