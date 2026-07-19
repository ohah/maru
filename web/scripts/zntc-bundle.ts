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

export async function emitZntcBundle(
  entry: string,
  outdir: string,
  outputName = "bundle.js",
  conditions?: string[],
): Promise<EmittedBundle> {
  // write:false is the fail-closed boundary. zntc 0.1.3 can return diagnostics and
  // an output file together, so no bytes may reach dist before errors are checked.
  const result = await build({
    entryPoints: [entry],
    bundle: true,
    format: "esm",
    platform: "browser",
    target: ["safari16"],
    jobs: 1,
    conditions,
    outdir,
    // zntc 0.1.3 syntax minifier can emit a bundle that its own safari16 target accepts but the macOS
    // JavaScriptCore parser rejects once the CM6 graph is present. Identifier/whitespace minification remains
    // deterministic; syntax rewriting stays off and the real WKWebView smoke is the executable compatibility gate.
    minify: false,
    minifyIdentifiers: true,
    minifyWhitespace: true,
    minifySyntax: false,
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
  const emittedName = basename(output.path);
  if (emittedName !== output.path || emittedName !== "bundle.js") {
    throw new Error(`unexpected zntc output path: ${output.path}`);
  }
  const name = basename(outputName);
  if (name !== outputName || !/^[a-z0-9-]+\.js$/.test(name)) {
    throw new Error(`invalid deterministic bundle name: ${outputName}`);
  }

  await mkdir(outdir, { recursive: true });
  await writeFile(join(outdir, name), output.contents);
  return { name, bytes: output.contents };
}
