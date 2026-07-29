/**
 * 파일 패널 콘텐츠 영역의 React 스택이 실제로 서는지 검증한다(docs/file-panel.md §2.1).
 *
 * 왜 터미널에서 중요한가: 이 웹앱은 WKWebView 안에서 Safari 16 타깃으로 번들된 채 돈다. 개발 기계에서 되는
 * 것과 제품에서 도는 것이 다른 전례가 여러 번 있었다(zntc minifier가 만든 번들을 JavaScriptCore가 거부한 적,
 * 앱 번들 안 web이 stale이라 구버전이 실행된 적). 그래서 ⑴ 루트가 실제로 마운트·언마운트되는지, ⑵ Tailwind
 * 테마가 native 색 변수를 **참조**하는지(복사가 아니라), ⑶ 번들 예산이 지켜지는지를 자동 게이트로 둔다.
 */

import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const webRoot = join(import.meta.dir, "..");

describe("shell UI stack", () => {
  test("the React entry point exists and is wired for automatic JSX", () => {
    // 실제 마운트 검증은 첫 컴포넌트(컨텍스트 메뉴)가 생길 때 그 UI 테스트가 한다. 여기서 React 루트를 미리
    // 띄우면 스케줄러가 jsdom 정리 뒤에 돌아 **다른 테스트까지 오염시킨다**(실제로 겪었다 — window is not
    // defined가 7건 터졌다). 그래서 이 슬라이스는 스택이 서 있는지만 본다.
    const source = readFileSync(join(webRoot, "src", "shell-ui.tsx"), "utf8");
    expect(source).toContain("createRoot");
    // automatic runtime이라 `import React`가 없어야 한다 — 있으면 jsx 설정이 classic으로 새고 있다는 뜻이다.
    expect(source).not.toMatch(/^import React /m);

    const bundler = readFileSync(join(webRoot, "scripts", "zntc-bundle.ts"), "utf8");
    expect(bundler).toContain('jsx: "automatic"');
    expect(bundler).toContain('jsxImportSource: "react"');
  });

  test("Tailwind theme references the native colour variables instead of copying them", () => {
    // 값의 단일 출처는 native 주입이다(§2.1b). Tailwind 토큰이 리터럴 색을 들고 있으면 터미널 테마를 바꿔도
    // 그 부분만 따라오지 않는다 — 리치 본문에 터미널 폰트를 잘못 물려 한글이 깨졌던 것과 같은 계열의 사고다.
    const css = readFileSync(join(webRoot, "src", "app.css"), "utf8");
    const themeBlock = css.slice(
      css.indexOf("@theme inline"),
      css.indexOf("}", css.indexOf("@theme inline")),
    );
    expect(themeBlock).toContain("var(--maru-syntax-keyword)");
    expect(themeBlock).toContain("var(--maru-editor-selection)");
    expect(themeBlock).toContain("var(--maru-editor-font-family");
    // 리터럴 hex를 테마에 박으면 안 된다.
    expect(themeBlock).not.toMatch(/#[0-9a-fA-F]{6}/);
  });

  test("the build pins a shell bundle budget", () => {
    // 예산 자체가 사라지면 번들이 조용히 불어난다. 게이트가 존재하고 3 MiB로 걸려 있는지 고정한다.
    const verify = readFileSync(join(webRoot, "scripts", "verify-build.ts"), "utf8");
    expect(verify).toContain("shellBundleBudgetBytes");
    expect(verify).toContain("3 * 1024 * 1024");
    expect(verify).toContain("exceeds");
  });
});
