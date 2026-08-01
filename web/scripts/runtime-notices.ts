import { readFile, readdir, realpath } from "node:fs/promises";
import { dirname, join, parse } from "node:path";
import { allowedLicenses, reviewedLicense } from "./license-policy";

type PackageManifest = {
  name?: string;
  version?: string;
  license?: string;
  dependencies?: Record<string, string>;
  optionalDependencies?: Record<string, string>;
};

type PendingDependency = {
  name: string;
  importerDirectory: string;
};

const licenseFilePattern = /^(license|licence|copying|notice)(\..*)?$/i;
const exactFallbackLicenses = new Map([
  // 패키지가 라이선스 **파일**을 안 담고 Readme의 "License" 절과 `licenses` 필드로만 MIT를 선언한다
  // (2026-08-01 확인 — `Copyright 2010 - 2014 Sami Samhuri`, http://sjs.mit-license.org).
  ["format@0.2.2", "licenses/format-0.2.2-MIT.txt"],
  ["rehype-katex@7.0.1", "licenses/remark-math-MIT.txt"],
  ["remark-math@6.0.0", "licenses/remark-math-MIT.txt"],
]);

async function resolvePackageDirectory(
  packageName: string,
  importerDirectory: string,
  packageRoot: string,
): Promise<string> {
  let cursor = importerDirectory;
  const filesystemRoot = parse(cursor).root;
  while (true) {
    const candidate = join(cursor, "node_modules", packageName);
    try {
      return await realpath(candidate);
    } catch (error) {
      if (!(error instanceof Error) || !("code" in error) || error.code !== "ENOENT") throw error;
    }
    if (cursor === packageRoot || cursor === filesystemRoot) break;
    cursor = dirname(cursor);
  }
  throw new Error(`runtime dependency is not installed: ${packageName}`);
}

async function licenseTexts(
  packageDirectory: string,
  packageKey: string,
  packageRoot: string,
): Promise<Array<{ name: string; text: string }>> {
  const files = (await readdir(packageDirectory))
    .filter((name) => licenseFilePattern.test(name))
    .sort();
  if (files.length > 0) {
    return Promise.all(
      files.map(async (name) => ({
        name,
        text: await readFile(join(packageDirectory, name), "utf8"),
      })),
    );
  }

  const fallback = exactFallbackLicenses.get(packageKey);
  if (fallback === undefined)
    throw new Error(`runtime dependency has no license text: ${packageKey}`);
  return [
    {
      name: `fallback:${fallback}`,
      text: await readFile(join(packageRoot, fallback), "utf8"),
    },
  ];
}

export async function buildRuntimeNotices(packageRoot: string): Promise<string> {
  const rootManifest = JSON.parse(
    await readFile(join(packageRoot, "package.json"), "utf8"),
  ) as PackageManifest;
  const pending: PendingDependency[] = Object.keys(rootManifest.dependencies ?? {})
    .sort()
    .map((name) => ({ name, importerDirectory: packageRoot }));
  const packages = new Map<
    string,
    { manifest: Required<Pick<PackageManifest, "name" | "version" | "license">>; directory: string }
  >();
  const visitedDirectories = new Set<string>();

  while (pending.length > 0) {
    const dependency = pending.shift();
    if (dependency === undefined) break;
    const directory = await resolvePackageDirectory(
      dependency.name,
      dependency.importerDirectory,
      packageRoot,
    );
    if (visitedDirectories.has(directory)) continue;
    visitedDirectories.add(directory);

    const manifest = JSON.parse(
      await readFile(join(directory, "package.json"), "utf8"),
    ) as PackageManifest;
    if (manifest.name === undefined || manifest.version === undefined) {
      throw new Error(`runtime dependency manifest is incomplete: ${directory}`);
    }
    const bundledLicense =
      manifest.name === "khroma" && manifest.version === "2.1.0"
        ? await readFile(join(directory, "license"))
        : undefined;
    const license = reviewedLicense(manifest, bundledLicense);
    if (license === undefined || !allowedLicenses.has(license)) {
      throw new Error(
        `runtime dependency license is not reviewed: ${manifest.name}@${manifest.version}`,
      );
    }
    const key = `${manifest.name}@${manifest.version}`;
    packages.set(key, {
      manifest: { name: manifest.name, version: manifest.version, license },
      directory,
    });

    const childNames = Object.keys({
      ...manifest.dependencies,
      ...manifest.optionalDependencies,
    }).sort();
    for (const name of childNames) pending.push({ name, importerDirectory: directory });
  }

  const sections = await Promise.all(
    [...packages.entries()]
      .sort(([left], [right]) => left.localeCompare(right))
      .map(async ([key, value]) => {
        const texts = await licenseTexts(value.directory, key, packageRoot);
        const body = texts.map(({ name, text }) => `--- ${name} ---\n${text.trim()}\n`).join("\n");
        return `================================================================================\n${key}\nSPDX: ${value.manifest.license}\n================================================================================\n${body}`;
      }),
  );

  return `Maru File Panel - Third-Party Notices\n\nThis file covers the production dependency graph embedded in Resources/web/bundle.js and live-preview-worker.js.\nDevelopment-only tools are excluded.\n\n${sections.join("\n")}`;
}
