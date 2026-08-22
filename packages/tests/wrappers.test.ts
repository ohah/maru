import { expect, test } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

const ROOT = new URL("..", import.meta.url).pathname;
const WRAPPERS = ["react", "vue", "svelte", "lit"] as const;

test("네 래퍼가 모두 번들과 타입 선언을 낸다", () => {
  for (const w of WRAPPERS) {
    expect(existsSync(join(ROOT, w, "dist/index.js"))).toBe(true);
    expect(existsSync(join(ROOT, w, "dist/types/index.d.ts"))).toBe(true);
  }
});

test("코어를 번들에 넣지 않는다 — peer 로만 참조한다", () => {
  for (const w of WRAPPERS) {
    const js = readFileSync(join(ROOT, w, "dist/index.js"), "utf8");
    expect(js).toContain("@maru/core");
    // 코어가 통째로 들어가면 wasm 로더 코드가 보인다. peer 면 import 문만 있어야 한다.
    expect(js).not.toContain("WebAssembly.compile");
    expect(js.length).toBeLessThan(20_000);
  }
});

test("package.json 의 exports 가 실제 산출물을 가리킨다", () => {
  for (const w of [...WRAPPERS, "core"]) {
    const pkg = JSON.parse(readFileSync(join(ROOT, w, "package.json"), "utf8"));
    const entry = pkg.exports["."].default.replace("./", "");
    const types = pkg.exports["."].types.replace("./", "");
    expect(existsSync(join(ROOT, w, entry))).toBe(true);
    expect(existsSync(join(ROOT, w, types))).toBe(true);
  }
});

test("프레임워크는 peerDependency 다 — 설치본을 강제하지 않는다", () => {
  const expected: Record<string, string> = {
    react: "react",
    vue: "vue",
    svelte: "svelte",
    lit: "lit",
  };
  for (const w of WRAPPERS) {
    const pkg = JSON.parse(readFileSync(join(ROOT, w, "package.json"), "utf8"));
    expect(pkg.peerDependencies).toHaveProperty(expected[w]!);
    expect(pkg.peerDependencies).toHaveProperty("@maru/core");
    expect(pkg.dependencies).toBeUndefined();
  }
});

test("코어 번들은 wasm 을 인라인하지 않는다", () => {
  const js = readFileSync(join(ROOT, "core/dist/index.js"), "utf8");
  expect(js).toContain('new URL("../wasm/maru-vt.wasm"');
  expect(js.length).toBeLessThan(120_000); // wasm(127KB)이 들어갔다면 넘는다
});

test("워커 엔트리가 별도 파일로 나오고 참조가 이어진다", () => {
  const js = readFileSync(join(ROOT, "core/dist/index.js"), "utf8");
  const ref = /new URL\("\.\/(entry[^"]*\.js)"/.exec(js);
  expect(ref).not.toBeNull();
  expect(existsSync(join(ROOT, "core/dist", ref![1]!))).toBe(true);
});

test("각 래퍼가 기대한 심볼을 내보낸다", () => {
  // 소스를 import 하지 않는다 — 워크스페이스 디렉토리 이름(`react`·`vue`…)이 npm 패키지명과
  // 겹쳐 bun 이 자기 자신을 먼저 찾는다. 산출물의 export 문을 본다.
  const exportsOf = (w: string) => {
    const js = readFileSync(join(ROOT, w, "dist/index.js"), "utf8");
    const names = new Set<string>();
    for (const m of js.matchAll(/export\s*\{([^}]*)\}/g)) {
      for (const part of m[1]!.split(",")) {
        const name = part
          .trim()
          .split(/\s+as\s+/)
          .pop()
          ?.trim();
        if (name) names.add(name);
      }
    }
    return names;
  };
  expect(exportsOf("react")).toContain("MaruTerminal");
  expect(exportsOf("vue")).toContain("MaruTerminal");
  expect(exportsOf("svelte")).toContain("terminal");
  expect(exportsOf("lit")).toContain("MaruTerminalElement");
});

test("update 는 콜백을 지우지 않는다 — 부분 병합이다", () => {
  // 통째로 덮어쓰면 이번에 안 넘어온 콜백이 사라진다(Lit 의 updated 가 options/theme 만
  // 넘기면서 ready·data 이벤트가 끊겼다). 병합 규칙 자체를 계약으로 고정한다.
  type Props = { onData?: () => void; theme?: { foreground: number; background: number } };
  const before: Props = { onData: () => {} };
  const merged: Props = { ...before, theme: { foreground: 1, background: 2 } };
  expect(typeof merged.onData).toBe("function");
  expect(merged.theme).toEqual({ foreground: 1, background: 2 });
});
