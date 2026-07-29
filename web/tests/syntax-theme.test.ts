/**
 * 터미널 색상 테마에서 파생한 syntax 색이 웹까지 **끊김 없이** 도달하는지 검증한다.
 *
 * 왜 터미널에서 중요한가: 파일 패널의 코드 색은 시스템 light/dark가 아니라 옆 터미널과 같은 팔레트에서
 * 나온다(docs/file-panel.md §2.3). 그 경로는 세 조각이 이름 하나로 맞물려 있다 —
 * native `syntax_theme.zig`가 `--maru-syntax-*`를 주입하고, 소스 편집기(`source-language.ts`)와
 * 읽기 프리뷰 코드펜스(`app.css`)가 같은 이름을 읽는다. **한쪽 이름만 바뀌어도 색은 조용히 기본값으로
 * 떨어지고, 자동 게이트 없이는 제품에서만 드러난다.** 라이브 프리뷰 폐기로 web 모듈이 크게 바뀐 뒤라
 * 이 계약을 고정해 둔다.
 */

import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { JSDOM } from "jsdom";

const repoRoot = join(import.meta.dir, "..", "..");
const readRepoFile = (...parts: string[]) => readFileSync(join(repoRoot, ...parts), "utf8");

const uniqueSorted = (values: Iterable<string>) => [...new Set(values)].sort();

/** native가 `setProperty('--maru-syntax-X', …)`로 세우는 토큰 이름. */
function nativeInjectedTokens(): string[] {
  const zig = readRepoFile("src", "session", "syntax_theme.zig");
  return uniqueSorted(
    [...zig.matchAll(/\.\{ \.name = "([a-z_]+)", \.rgb =/g)].map((match) => match[1] as string),
  );
}

/** 웹이 `var(--maru-syntax-X)`로 읽는 토큰 이름. */
function webConsumedTokens(source: string): string[] {
  return uniqueSorted(
    [...source.matchAll(/var\(--maru-syntax-([a-z]+)\)/g)].map((match) => match[1] as string),
  );
}

describe("terminal theme syntax colors", () => {
  test("native injects exactly the token names both web consumers read", () => {
    const injected = nativeInjectedTokens();
    const editorTokens = webConsumedTokens(readRepoFile("web", "src", "source-language.ts"));
    const previewTokens = webConsumedTokens(readRepoFile("web", "src", "app.css"));

    // Zig는 `type_name` 필드를 CSS `type`으로 내보낸다(`--maru-syntax-type`). 그 한 쌍만 이름이 다르다.
    const injectedCssNames = uniqueSorted(
      injected.map((name) => (name === "type_name" ? "type" : name)),
    );

    expect(injectedCssNames).toEqual(editorTokens);
    expect(injectedCssNames).toEqual(previewTokens);
    // 회귀 가드: 토큰이 하나라도 사라지면 그 문법 요소가 색을 잃는다.
    expect(injectedCssNames).toEqual([
      "attribute",
      "comment",
      "function",
      "invalid",
      "keyword",
      "number",
      "property",
      "punctuation",
      "string",
      "tag",
      "type",
    ]);
  });

  test("app.css ships a fallback for every token in both light and dark", () => {
    const css = readRepoFile("web", "src", "app.css");
    // 주입 전(첫 paint)과 주입 실패 시 쓰는 폴백이다. 없으면 그 순간 코드가 무채색으로 보인다.
    const rootBlock = css.slice(css.indexOf(":root {"), css.indexOf("@media (prefers-color-scheme: dark)"));
    const darkBlock = css.slice(css.indexOf("@media (prefers-color-scheme: dark)"));
    for (const token of webConsumedTokens(css)) {
      expect(rootBlock).toContain(`--maru-syntax-${token}:`);
      expect(darkBlock).toContain(`--maru-syntax-${token}:`);
    }
  });

  test("the injected snippet overrides the stylesheet fallback at runtime", () => {
    // native가 실제로 보내는 형태 그대로다(syntax_theme.writeCssVarsJs). 여기서는 그 bytes가 문서에
    // 적용됐을 때 폴백을 이기는지만 본다 — 색 파생 자체는 Zig 단위 테스트가 소유한다.
    const injected =
      "(function(s){" +
      "s.setProperty('--maru-syntax-keyword','#c792ea');" +
      "s.setProperty('--maru-syntax-string','#7ee787');" +
      "s.setProperty('--maru-editor-selection','#334455');" +
      "s.setProperty('--maru-editor-font-size','14px');" +
      "})(document.documentElement.style)";
    const dom = new JSDOM("<!doctype html><html><body></body></html>", { runScripts: "outside-only" });
    try {
      const root = dom.window.document.documentElement;
      root.style.setProperty("--maru-syntax-keyword", "#9333ea"); // 스타일시트 폴백 자리
      dom.window.eval(injected);
      const style = root.style;
      expect(style.getPropertyValue("--maru-syntax-keyword")).toBe("#c792ea");
      expect(style.getPropertyValue("--maru-syntax-string")).toBe("#7ee787");
      expect(style.getPropertyValue("--maru-editor-selection")).toBe("#334455");
      // 단위는 px다 — pt로 주입하면 편집기 글자가 터미널보다 33% 커진다(2026-07-28 정정).
      expect(style.getPropertyValue("--maru-editor-font-size")).toBe("14px");
    } finally {
      dom.window.close();
    }
  });
});
