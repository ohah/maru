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
