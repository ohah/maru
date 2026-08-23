import type { WasmExports } from "./exports";

/**
 * 컴파일된 모듈 캐시. **같은 URL의 wasm은 한 번만 컴파일한다** — 프레임워크 패키지가 코어를
 * `peerDependency`로만 두어 설치는 한 벌이지만, 한 페이지에서 터미널을 여러 개 열면 인스턴스가
 * 여럿 생긴다. 컴파일 결과를 공유하면 그 비용이 한 번으로 접힌다(인스턴스 메모리는 각자 갖는다).
 */
const moduleCache = new Map<string, Promise<WebAssembly.Module>>();

/** 번들러가 에셋으로 잡는 기본 경로. Vite·webpack5·SvelteKit이 모두 이 형태를 인식한다. */
export function defaultWasmUrl(): URL {
  // 번들러가 청크에 따라 `import.meta.url` 을 빈 문자열로 접는 경우가 있다(실측: zntc 의 워커
  // 청크). 그때 `new URL(rel, "")` 은 "Invalid base URL" 로 죽으므로, 실행 문맥이 아는 주소로
  // 물러선다 — 워커에서는 `location.href` 가 곧 그 워커 스크립트의 주소라 정확하다.
  const base = import.meta.url || (typeof location !== "undefined" ? location.href : "");
  if (!base) throw new Error("maru-term: wasm 기본 경로를 정할 수 없다 — wasmUrl 을 직접 넘겨라");
  return new URL("../../wasm/maru-vt.wasm", base);
}

function compile(url: string): Promise<WebAssembly.Module> {
  const cached = moduleCache.get(url);
  if (cached) return cached;
  // `compileStreaming`은 MIME이 application/wasm이어야 한다. 아닌 서버(정적 호스팅 오설정)에서
  // 조용히 실패하지 않도록 fetch → arrayBuffer 폴백을 둔다.
  const task = (async () => {
    const res = await fetch(url);
    if (!res.ok) throw new Error(`maru-term: wasm을 받지 못했다 (${res.status} ${url})`);
    const type = res.headers.get("content-type") ?? "";
    if (type.includes("application/wasm") && WebAssembly.compileStreaming) {
      return WebAssembly.compileStreaming(Promise.resolve(res));
    }
    return WebAssembly.compile(await res.arrayBuffer());
  })();
  // **실패한 시도는 캐시에서 뺀다.** 남겨 두면 일시적인 네트워크 오류 한 번이 그 URL 을
  // 페이지 수명 내내 막아, 이후 모든 `new Terminal()` 이 같은 에러로 죽는다(재시도 불가).
  const guarded = task.catch((e: unknown) => {
    moduleCache.delete(url);
    throw e;
  });
  moduleCache.set(url, guarded);
  return guarded;
}

/**
 * wasm 인스턴스를 만든다. 인스턴스는 **터미널마다 하나**다 — 선형 메모리를 공유하면 한 터미널의
 * 스크롤백이 다른 터미널의 버퍼를 덮는다(모듈 스코프 버퍼를 쓰는 교환 규약 때문).
 */
export async function instantiate(wasmUrl?: string | URL): Promise<WasmExports> {
  const url = String(wasmUrl ?? defaultWasmUrl());
  const mod = await compile(url);
  const instance = await WebAssembly.instantiate(mod, {});
  return instance.exports as unknown as WasmExports;
}

/** 테스트에서 모듈 캐시를 비운다. 제품 경로에서는 쓰지 않는다. */
export function clearModuleCache(): void {
  moduleCache.clear();
}
