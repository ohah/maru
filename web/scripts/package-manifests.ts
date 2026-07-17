import { readFile, readdir, realpath } from "node:fs/promises";
import { join } from "node:path";

function isMissingDirectory(error: unknown): boolean {
  return (
    error instanceof Error && "code" in error && (error as NodeJS.ErrnoException).code === "ENOENT"
  );
}

export async function collectPackageManifests(rootNodeModules: string): Promise<string[]> {
  const manifests: string[] = [];
  const visitedPackageRoots = new Set<string>();

  async function addPackage(directory: string): Promise<void> {
    const packageRoot = await realpath(directory);
    if (visitedPackageRoots.has(packageRoot)) return;
    visitedPackageRoots.add(packageRoot);

    const manifest = join(packageRoot, "package.json");
    await readFile(manifest);
    manifests.push(manifest);
    await walkNodeModules(join(packageRoot, "node_modules"), true);
  }

  async function walkNodeModules(directory: string, allowMissing: boolean): Promise<void> {
    let entries;
    try {
      entries = await readdir(directory, { withFileTypes: true });
    } catch (error) {
      if (allowMissing && isMissingDirectory(error)) return;
      throw error;
    }

    for (const entry of entries) {
      if ((!entry.isDirectory() && !entry.isSymbolicLink()) || entry.name.startsWith(".")) {
        continue;
      }
      const child = join(directory, entry.name);

      if (entry.name.startsWith("@")) {
        for (const scoped of await readdir(child, { withFileTypes: true })) {
          if (scoped.isDirectory() || scoped.isSymbolicLink()) {
            await addPackage(join(child, scoped.name));
          }
        }
      } else {
        await addPackage(child);
      }
    }
  }

  await walkNodeModules(rootNodeModules, false);
  return manifests;
}
