import { mkdir, writeFile } from "node:fs/promises";
import { basename, join } from "node:path";
import { build } from "@zntc/core";

export type EmittedBundle = {
  name: string;
  bytes: Uint8Array;
};

function formatDiagnostic(diagnostic: { code?: string; text: string }): string {
  return diagnostic.code === undefined
    ? diagnostic.text
    : `[${diagnostic.code}] ${diagnostic.text}`;
}

export async function emitZntcBundle(entry: string, outdir: string): Promise<EmittedBundle> {
  // write:false is the fail-closed boundary. zntc 0.1.3 can return diagnostics and
  // an output file together, so no bytes may reach dist before errors are checked.
  const result = await build({
    entryPoints: [entry],
    bundle: true,
    format: "esm",
    platform: "browser",
    target: ["safari16"],
    outdir,
    minify: true,
    sourcemap: false,
    write: false,
  });

  if (result.errors.length > 0) {
    throw new Error(`zntc build failed: ${result.errors.map(formatDiagnostic).join("; ")}`);
  }
  if (result.outputFiles.length !== 1) {
    throw new Error(
      `zntc must emit exactly one JavaScript bundle, got ${result.outputFiles.length}`,
    );
  }

  const output = result.outputFiles[0];
  const name = basename(output.path);
  if (name !== output.path || name !== "bundle.js") {
    throw new Error(`unexpected zntc output path: ${output.path}`);
  }

  await mkdir(outdir, { recursive: true });
  await writeFile(join(outdir, name), output.contents);
  return { name, bytes: output.contents };
}
