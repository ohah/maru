import { expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { allowedLicenses, reviewedLicense } from "../scripts/license-policy";

test("runtime allowlist excludes GPL, LGPL, and AGPL families", () => {
  for (const license of allowedLicenses) expect(license).not.toMatch(/\b(?:GPL|LGPL|AGPL)-/);
  for (const license of [
    "GPL-2.0-only",
    "GPL-3.0-or-later",
    "LGPL-2.1-only",
    "LGPL-3.0-or-later",
    "AGPL-3.0-only",
    "AGPL-3.0-or-later",
  ]) {
    expect(allowedLicenses.has(license)).toBe(false);
  }
});

test("khroma license exception pins both version and full license bytes", async () => {
  const license = await readFile(join(import.meta.dir, "..", "node_modules", "khroma", "license"));

  expect(reviewedLicense({ name: "khroma", version: "2.1.0" }, license)).toBe("MIT");
  expect(reviewedLicense({ name: "khroma", version: "2.2.0" }, license)).toBeUndefined();
  expect(
    reviewedLicense({ name: "khroma", version: "2.1.0" }, Buffer.from("The MIT License (MIT)")),
  ).toBeUndefined();
  expect(reviewedLicense({ name: "unknown", version: "1.0.0" })).toBeUndefined();
});

test("옛 npm 형식(`licenses` 배열)도 선언으로 받되, 여러 개면 사람이 정한다", () => {
  // `license: "MIT"`와 증거의 세기가 같다 — 형식이 옛것이라는 이유로 거절하면 정상 패키지가 막힌다
  // (실제로 `format@0.2.2`가 이 형식만 갖고 있어 remark-frontmatter 도입이 막혔다).
  expect(reviewedLicense({ name: "format", version: "0.2.2", licenses: [{ type: "MIT" }] })).toBe(
    "MIT",
  );
  // 여러 개는 "둘 중 고르라"는 뜻이라 우리가 임의로 고르면 그 선택이 감사 기록에 안 남는다.
  expect(
    reviewedLicense({ name: "x", licenses: [{ type: "MIT" }, { type: "Apache-2.0" }] }),
  ).toBeUndefined();
  expect(reviewedLicense({ name: "x", licenses: [{}] })).toBeUndefined();
  // 새 형식이 있으면 그쪽이 이긴다.
  expect(reviewedLicense({ name: "x", license: "ISC", licenses: [{ type: "MIT" }] })).toBe("ISC");
});
