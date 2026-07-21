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
  // write:false is the fail-closed boundary. 0.1.3에서 확인된 diagnostics+output 동시 반환 가능성을
  // 0.1.4에서도 보수적으로 방어하므로, 오류 확인 전에는 어떤 bytes도 dist에 쓰지 않는다.
  const result = await build({
    entryPoints: [entry],
    bundle: true,
    format: "esm",
    platform: "browser",
    target: ["safari16"],
    jobs: 1,
    conditions,
    outdir,
    // 0.1.3에서 zntc syntax minifier가 자기 safari16 target은 통과하지만 CM6 graph를 실제 macOS
    // JavaScriptCore가 거부하는 bundle을 생성했다. 0.1.4에서도 검증된 보수 정책을 유지해 identifier/whitespace만
    // 결정적으로 줄이고 syntax rewrite는 끄며, 실제 WKWebView smoke를 실행 호환 gate로 둔다.
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
