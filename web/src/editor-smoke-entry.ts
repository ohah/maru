//! E0.5A 스모크 페이지 진입점(docs/editor-surface.md §7.4). 제품 번들에 들어가지 않는다 —
//! `scripts/build-editor-smoke.ts`가 별도 asset root로만 빌드하고, 네이티브 스모크가 그 root를 제품 스킴
//! 핸들러에 물려 로드한다.
//!
//! **관측을 먼저 건다.** CSP 위반·console 오류 수집기를 마운트보다 먼저 설치해야 MergeView가 유발한 위반을
//! 놓치지 않는다(그것이 이 게이트가 처음 보는 값이다 — §7.2 남은 확인).

import { measureParse, mount, type DiffProbe, type Harness } from "./diff-harness";

type SmokeApi = {
  ready: boolean;
  error: string | null;
  violations: string[];
  console_errors: string[];
  probe: () => DiffProbe | null;
  accept: () => boolean;
  reject: () => boolean;
  /** CSP가 실제로 걸려 있는지 스스로 확인한다 — 아래 cspSelfTest 참고. */
  csp_self_test: () => boolean;
  /// 큰 응답을 웹이 파싱하는 비용(상한 근거).
  measure_parse: (bytes_per_side: number) => { response_bytes: number; parse_ms: number };
};

const violations: string[] = [];
const consoleErrors: string[] = [];

// CSP 위반은 이벤트로만 관측된다(문서 로드 실패와 달리 조용하다). directive와 차단된 URI만 남긴다 —
// 원본 스타일 내용은 artifact에 싣지 않는다(§7.4 — source text 금지).
document.addEventListener("securitypolicyviolation", (event) => {
  violations.push(`${event.effectiveDirective}|${event.blockedURI}`);
});

const originalConsoleError = console.error.bind(console);
console.error = (...args: unknown[]) => {
  consoleErrors.push(args.map((arg) => String(arg)).join(" "));
  originalConsoleError(...args);
};
window.addEventListener("error", (event) => {
  consoleErrors.push(`uncaught: ${event.message}`);
});
window.addEventListener("unhandledrejection", (event) => {
  consoleErrors.push(`unhandled: ${String(event.reason)}`);
});

let harness: Harness | null = null;
const api: SmokeApi = {
  ready: false,
  error: null,
  violations,
  console_errors: consoleErrors,
  probe: () => (harness === null ? null : harness.probe()),
  accept: () => harness?.acceptFirstChunk() ?? false,
  reject: () => harness?.rejectFirstChunk() ?? false,
  csp_self_test: cspSelfTest,
  measure_parse: measureParse,
};

/// **"위반 0"이 의미를 가지려면 CSP가 실제로 걸려 있어야 한다.** 헤더가 빠져도 위반은 0으로 보이므로, 반드시
/// 막혀야 하는 동작(`eval` — app origin은 `script-src 'self'`, `'unsafe-eval'` 없음)을 일부러 시도해 차단을
/// 확인한다. 게이트는 이 검사를 **모든 실제 측정이 끝난 뒤** 부른다(일부러 만든 위반이 계측을 오염시키지 않게).
function cspSelfTest(): boolean {
  try {
    // eslint-disable-next-line no-eval
    (0, eval)("1+1");
    return false; // 통과했다 = CSP가 안 걸렸다 = 이 실행의 "위반 0"은 근거가 없다
  } catch {
    return true;
  }
}

// 하니스 API는 `window`에 단 하나만 노출한다. 브리지가 아니라 계측 창구이며, 제품 페이지에는 존재하지 않는다.
(window as unknown as { __maruEditorSmoke: SmokeApi }).__maruEditorSmoke = api;

function start(): void {
  const parent = document.querySelector<HTMLElement>("#diff-harness");
  if (parent === null) {
    api.error = "mount target missing";
    return;
  }
  try {
    harness = mount(parent);
    api.ready = true;
  } catch (error) {
    // 마운트 실패를 조용히 두면 스모크가 "위반 0"만 보고 통과로 읽는다 — 실패 사실을 값으로 남긴다.
    api.error = String(error);
  }
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", start, { once: true });
} else {
  start();
}
