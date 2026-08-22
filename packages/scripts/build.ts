/**
 * `@maru/*` 패키지를 번들한다.
 *
 * JS는 zntc, 타입 선언은 tsc가 만든다 — zntc에 `dts` 옵션이 없다(0.1.4 BuildOptions 확인).
 * `web/scripts/zntc-bundle.ts`의 fail-closed 패턴을 따른다: `write: false`로 받아 진단을
 * 확인한 **뒤에만** 디스크에 쓴다.
 */
import { rm, mkdir, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { build } from "@zntc/core";

const ROOT = new URL("..", import.meta.url).pathname;

interface Target {
  dir: string;
  /** peer로 두어 번들에 넣지 않을 것들. */
  external: string[];
  /** src/index.ts 외에 따로 낼 엔트리(워커 등). */
  extraEntries?: string[];
}

const TARGETS: Target[] = [
  // 워커는 별도 번들이어야 한다 — `new Worker(new URL("./entry.js", import.meta.url))`가
  // 그 파일을 직접 가리킨다.
  { dir: "core", external: [], extraEntries: ["src/worker/entry.ts"] },
  { dir: "react", external: ["react", "react/jsx-runtime", "@maru/core"] },
  { dir: "vue", external: ["vue", "@maru/core"] },
  { dir: "svelte", external: ["svelte", "svelte/store", "@maru/core"] },
  { dir: "lit", external: ["lit", "lit/decorators.js", "@maru/core"] },
];

/** React 래퍼는 JSX 라 `.tsx` 다. 확장자를 고정하지 않고 있는 쪽을 쓴다. */
function entryOf(pkgDir: string): string {
  const tsx = join(pkgDir, "src/index.tsx");
  return existsSync(tsx) ? tsx : join(pkgDir, "src/index.ts");
}

function formatDiagnostic(d: { code?: string; text: string }): string {
  return d.code === undefined ? d.text : `[${d.code}] ${d.text}`;
}

async function bundle(target: Target): Promise<number> {
  const pkgDir = join(ROOT, target.dir);
  const outdir = join(pkgDir, "dist");
  const options = {
    entryPoints: [entryOf(pkgDir), ...(target.extraEntries ?? []).map((e) => join(pkgDir, e))],
    bundle: true,
    format: "esm",
    platform: "browser",
    target: "safari16",
    jsx: "automatic",
    jsxImportSource: "react",
    external: target.external,
    // wasm은 번들에 인라인하지 않는다 — `new URL(..., import.meta.url)`로 에셋을 가리켜야
    // 소비자 번들러(Vite·webpack5)가 자기 방식으로 복사한다.
    loader: { ".wasm": "file" },
    jobs: 1,
    outdir,
    minify: false,
    minifyIdentifiers: false,
    minifyWhitespace: false,
    minifySyntax: false,
    sourcemap: false,
    write: false,
  };
  const result = await build(options as unknown as Parameters<typeof build>[0]);
  if (result.errors.length > 0) {
    throw new Error(
      `zntc build failed (${target.dir}): ${result.errors.map(formatDiagnostic).join("; ")}`,
    );
  }
  if (result.outputFiles.length === 0) {
    throw new Error(`zntc emitted nothing for ${target.dir}`);
  }
  await mkdir(outdir, { recursive: true });
  let bytes = 0;
  let sawWasmRef = false;
  for (const file of result.outputFiles) {
    // zntc 는 `bundle.js` 로 낸다. package.json 의 exports 가 가리키는 이름으로 맞춘다 —
    // 여러 청크가 나오면(splitting) 첫 진입점만 index.js 로 두고 나머지는 이름을 지킨다.
    // zntc 는 단일 엔트리를 `bundle.js` 로 낸다. 엔트리가 여럿이면 원래 이름을 지킨다.
    const original = file.path.split("/").pop()!;
    const name = original === "bundle.js" ? "index.js" : original;
    if (!/^[a-z0-9._-]+$/i.test(name)) throw new Error(`unexpected output name: ${name}`);
    let contents: Uint8Array | string = file.contents;
    if (target.dir === "core" && name.endsWith(".js")) {
      // wasm 상대 경로를 **번들 위치 기준**으로 고친다. 소스는 `core/src/wasm/loader.ts`라
      // 두 단계 위(`../../wasm/`)지만, 번들은 `core/dist/*.js`라 한 단계 위(`../wasm/`)다.
      //
      // **모든 청크에 적용한다.** 워커 엔트리는 별도 청크로 떨어지는데, 여기를 빼먹으면
      // 메인은 정상이고 워커만 wasm 을 못 찾아 `worker: 'full'` 이 통째로 죽는다(실측).
      const text = new TextDecoder().decode(file.contents);
      contents = text.replace('"../../wasm/maru-vt.wasm"', '"../wasm/maru-vt.wasm"');
      if (
        text.includes("maru-vt.wasm") &&
        contents === text &&
        !text.includes('"../wasm/maru-vt.wasm"')
      )
        throw new Error(`${name}: wasm 경로를 고치지 못했다 — loader.ts가 바뀌었는가?`);
      // 번들러가 `import.meta.url` 을 빈 문자열로 접으면 `new URL(rel, "")` 이 되어 런타임에
      // "Invalid base URL" 로 죽는다. 워커 청크에서 실제로 일어났으므로 빌드에서 막는다.
      if (/new URL\([^)]*,\s*""\s*\)/.test(contents))
        throw new Error(`${name}: new URL(..., "") — import.meta.url 이 접혔다`);
    }
    if (target.dir === "core" && typeof contents === "string" && contents.includes("maru-vt.wasm"))
      sawWasmRef = true;
    await writeFile(join(outdir, name), contents);
    bytes += typeof contents === "string" ? contents.length : contents.byteLength;
  }
  if (target.dir === "core" && !sawWasmRef)
    throw new Error("core 번들 어디에도 wasm 참조가 없다 — 로더가 빠졌는가?");
  return bytes;
}

async function emitTypes(dir: string): Promise<void> {
  const proc = Bun.spawn(["bunx", "tsc", "-p", join(ROOT, dir, "tsconfig.build.json")], {
    cwd: ROOT,
    stdout: "pipe",
    stderr: "pipe",
  });
  const code = await proc.exited;
  if (code !== 0) {
    const out = await new Response(proc.stdout).text();
    const err = await new Response(proc.stderr).text();
    throw new Error(`tsc failed (${dir}):\n${out}${err}`);
  }
}

for (const target of TARGETS) {
  await rm(join(ROOT, target.dir, "dist"), { recursive: true, force: true });
  const bytes = await bundle(target);
  await emitTypes(target.dir);
  console.log(`  ${target.dir.padEnd(7)} ${String(bytes).padStart(7)} B`);
}
console.log("build: OK");
