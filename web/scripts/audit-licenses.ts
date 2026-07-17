import { readdir, readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { reviewedLicense } from "./license-policy";

const allowed = new Set([
  "MIT",
  "MIT-0",
  "ISC",
  "BSD-2-Clause",
  "BSD-3-Clause",
  "Apache-2.0",
  "MPL-2.0",
  "(MPL-2.0 OR Apache-2.0)",
  "CC0-1.0",
  "CC-BY-4.0",
  "BlueOak-1.0.0",
  "Unlicense",
]);

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const manifests: string[] = [];

async function addPackage(directory: string): Promise<void> {
  const manifest = join(directory, "package.json");
  await readFile(manifest);
  manifests.push(manifest);
  try {
    await walkNodeModules(join(directory, "node_modules"));
  } catch {
    // Most hoisted packages have no nested node_modules directory.
  }
}

async function walkNodeModules(directory: string): Promise<void> {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    if (entry.name.startsWith(".")) continue;
    const child = join(directory, entry.name);

    if (entry.name.startsWith("@")) {
      for (const scoped of await readdir(child, { withFileTypes: true })) {
        if (scoped.isDirectory()) await addPackage(join(child, scoped.name));
      }
    } else {
      await addPackage(child);
    }
  }
}

await walkNodeModules(join(root, "node_modules"));

const packages = new Map<string, string>();
const rejected: string[] = [];

for (const manifest of manifests) {
  const pkg = JSON.parse(await readFile(manifest, "utf8")) as {
    name?: string;
    version?: string;
    license?: string;
  };
  if (pkg.name === undefined || pkg.version === undefined) {
    rejected.push("package-manifest:missing-name-or-version");
    continue;
  }

  let bundledLicense: Uint8Array | undefined;
  if (pkg.name === "khroma" && pkg.version === "2.1.0" && pkg.license === undefined) {
    bundledLicense = await readFile(join(dirname(manifest), "license"));
  }
  const license = reviewedLicense(pkg, bundledLicense);

  const key = `${pkg.name}@${pkg.version}`;
  if (license === undefined || !allowed.has(license))
    rejected.push(`${key}:${license ?? "missing"}`);
  else packages.set(key, license);
}

if (rejected.length > 0)
  throw new Error(`unreviewed package licenses: ${rejected.sort().join(", ")}`);

const counts = [...packages.values()].reduce<Record<string, number>>((acc, license) => {
  acc[license] = (acc[license] ?? 0) + 1;
  return acc;
}, {});
console.log(JSON.stringify({ auditedPackages: packages.size, licenses: counts }));
