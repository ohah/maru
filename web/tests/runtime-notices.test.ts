import { expect, test } from "bun:test";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildRuntimeNotices } from "../scripts/runtime-notices";

async function writePackage(
  directory: string,
  manifest: Record<string, unknown>,
  license = "fixture license text",
): Promise<void> {
  await mkdir(directory, { recursive: true });
  await writeFile(join(directory, "package.json"), `${JSON.stringify(manifest)}\n`);
  await writeFile(join(directory, "LICENSE"), `${license}\n`);
}

test("runtime notices follow production dependencies and exclude development tools", async () => {
  const root = await mkdtemp(join(tmpdir(), "maru-runtime-notices-"));
  try {
    await writeFile(
      join(root, "package.json"),
      `${JSON.stringify({ dependencies: { runtime: "1.0.0" }, devDependencies: { tool: "1.0.0" } })}\n`,
    );
    await writePackage(join(root, "node_modules", "runtime"), {
      name: "runtime",
      version: "1.0.0",
      license: "MIT",
      dependencies: { child: "1.0.0" },
    });
    await writePackage(join(root, "node_modules", "child"), {
      name: "child",
      version: "1.0.0",
      license: "ISC",
    });
    await writePackage(join(root, "node_modules", "tool"), {
      name: "tool",
      version: "1.0.0",
      license: "MIT",
    });

    const notices = await buildRuntimeNotices(root);
    expect(notices).toContain("runtime@1.0.0");
    expect(notices).toContain("child@1.0.0");
    expect(notices).not.toContain("tool@1.0.0");
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("runtime notices fail closed when a package has no license text", async () => {
  const root = await mkdtemp(join(tmpdir(), "maru-runtime-notices-missing-"));
  try {
    await writeFile(
      join(root, "package.json"),
      `${JSON.stringify({ dependencies: { runtime: "1.0.0" } })}\n`,
    );
    const packageDirectory = join(root, "node_modules", "runtime");
    await mkdir(packageDirectory, { recursive: true });
    await writeFile(
      join(packageDirectory, "package.json"),
      `${JSON.stringify({ name: "runtime", version: "1.0.0", license: "MIT" })}\n`,
    );

    await expect(buildRuntimeNotices(root)).rejects.toThrow(
      "runtime dependency has no license text: runtime@1.0.0",
    );
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("runtime notices fail closed for an unreviewed production license", async () => {
  const root = await mkdtemp(join(tmpdir(), "maru-runtime-notices-license-"));
  try {
    await writeFile(
      join(root, "package.json"),
      `${JSON.stringify({ dependencies: { runtime: "1.0.0" } })}\n`,
    );
    await writePackage(join(root, "node_modules", "runtime"), {
      name: "runtime",
      version: "1.0.0",
      license: "LicenseRef-Unapproved",
    });

    await expect(buildRuntimeNotices(root)).rejects.toThrow(
      "runtime dependency license is not reviewed: runtime@1.0.0",
    );
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
