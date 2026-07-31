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
  // `bundle`은 이 버전 타입 정의에 없지만 런타임이 요구하는 값이다(빼면 번들이 안 묶인다) — 타입만 넓혀 넘긴다.
  // 라이브러리 타입이 실제 옵션을 다 담지 못하는 경우라, 값을 지어내는 게 아니라 **알려진 옵션을 통과**시킨다.
  const options = {
    entryPoints: [entry],
    bundle: true,
    format: "esm",
    platform: "browser",
    // 단일 값이다(타입이 `BuildTarget` = 문자열 하나). 배열로 넘기던 것을 고친다 — 산출물이 같은지는 빌드
    // 결과 바이트로 확인했다(같다: 배열도 같은 값으로 해석돼 왔다).
    target: "safari16",
    // React 19의 automatic runtime — 컴포넌트마다 `import React`를 쓰지 않는다(docs/file-panel.md §2.1).
    jsx: "automatic",
    jsxImportSource: "react",
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
  };
  const result = await build(options as unknown as Parameters<typeof build>[0]);

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
