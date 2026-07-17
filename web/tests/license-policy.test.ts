import { expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { reviewedLicense } from "../scripts/license-policy";

test("khroma license exception pins both version and full license bytes", async () => {
  const license = await readFile(join(import.meta.dir, "..", "node_modules", "khroma", "license"));

  expect(reviewedLicense({ name: "khroma", version: "2.1.0" }, license)).toBe("MIT");
  expect(reviewedLicense({ name: "khroma", version: "2.2.0" }, license)).toBeUndefined();
  expect(
    reviewedLicense({ name: "khroma", version: "2.1.0" }, Buffer.from("The MIT License (MIT)")),
  ).toBeUndefined();
  expect(reviewedLicense({ name: "unknown", version: "1.0.0" })).toBeUndefined();
});
