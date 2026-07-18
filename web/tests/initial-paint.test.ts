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
  expect(cspSource).toContain(`'sha256-${digest}'`);
  expect(cspSource).not.toContain("style-src 'self' 'unsafe-inline'");
});
