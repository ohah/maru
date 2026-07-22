import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

const htmlSources = ["index.html", "render.html"];
const criticalStylePattern = /<style data-maru-critical-background>([^<]+)<\/style>/;

test("trusted viewer documents paint the same CSP-pinned background before external CSS", async () => {
  const styles = await Promise.all(
    htmlSources.map(async (name) => {
      const html = await readFile(resolve(import.meta.dir, "../src", name), "utf8");
      const match = html.match(criticalStylePattern);

      expect(match, `${name} must contain the critical background style`).not.toBeNull();
      expect(html.indexOf(match?.[0] ?? "")).toBeLessThan(
        html.indexOf('<link rel="stylesheet" href="app.css" />'),
      );
      return match?.[1] ?? "";
    }),
  );

  expect(styles[0]).toBe(styles[1]);
  expect(styles[0]).toContain("background: Canvas");

  const digest = createHash("sha256").update(styles[0]).digest("base64");
  const cspSource = await readFile(
    resolve(import.meta.dir, "../../src/session/app_scheme.zig"),
    "utf8",
  );
  // FP12b 정책 분기(docs/file-panel.md §2.3): render origin은 md 파생·비신뢰 HTML을 materialize하므로 strict
  // style-src(critical 배경 sha256 hash 핀)를 유지한다. app origin은 CM6 syntaxHighlighting의 StyleModule 런타임
  // <style> 주입을 strict CSP가 WebKit에서 막아, 'unsafe-inline'을 쓴다(hash 핀 무의미). 어느 쪽이든 critical
  // 배경 인라인 style은 app.css 로드 전 차단 없이 페인트된다.
  const renderCsp = cspSource.match(/render_csp_header = "([^"]+)"/)?.[1] ?? "";
  const appCsp = cspSource.match(/app_csp_header = "([^"]+)"/)?.[1] ?? "";
  expect(renderCsp).toContain(`'sha256-${digest}'`);
  expect(renderCsp).not.toContain("unsafe-inline");
  expect(appCsp).toContain("style-src 'self' 'unsafe-inline'");
  expect(appCsp).not.toContain("sha256-");
});
