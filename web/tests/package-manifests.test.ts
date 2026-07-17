import { expect, test } from "bun:test";
import { mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { collectPackageManifests } from "../scripts/package-manifests";

async function writeManifest(directory: string, name: string): Promise<void> {
  await mkdir(directory, { recursive: true });
  await writeFile(
    join(directory, "package.json"),
    `${JSON.stringify({ name, version: "1.0.0", license: "MIT" })}\n`,
  );
}

test("license manifest walk includes scoped and symlink packages without cycles", async () => {
  const root = await mkdtemp(join(tmpdir(), "maru-license-walk-"));
  const nodeModules = join(root, "node_modules");
  const linked = join(root, "linked-package");

  try {
    await writeManifest(join(nodeModules, "plain"), "plain");
    await writeManifest(join(nodeModules, "@scope", "scoped"), "@scope/scoped");
    await writeManifest(linked, "linked");
    await mkdir(join(linked, "node_modules"));
    await symlink(linked, join(linked, "node_modules", "cycle"), "dir");
    await symlink(linked, join(nodeModules, "linked"), "dir");

    const manifests = await collectPackageManifests(nodeModules);
    const names = await Promise.all(
      manifests.map(
        async (manifest) => JSON.parse(await readFile(manifest, "utf8")) as { name: string },
      ),
    );

    expect(names.map((pkg) => pkg.name).sort()).toEqual(["@scope/scoped", "linked", "plain"]);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("license manifest walk propagates a nested package manifest failure", async () => {
  const root = await mkdtemp(join(tmpdir(), "maru-license-fail-"));
  const parent = join(root, "node_modules", "parent");

  try {
    await writeManifest(parent, "parent");
    await mkdir(join(parent, "node_modules", "missing-manifest"), { recursive: true });
    await writeManifest(join(parent, "node_modules", "zbad"), "zbad");

    await expect(collectPackageManifests(join(root, "node_modules"))).rejects.toThrow(
      join("missing-manifest", "package.json"),
    );
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
