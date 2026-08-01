import { createHash } from "node:crypto";

export type PackageLicense = {
  name?: string;
  version?: string;
  license?: string;
  /** npm 초기 형식. 지금도 옛 패키지가 이 필드로만 선언한다(예: `format@0.2.2`). */
  licenses?: { type?: string }[];
};

const khroma210LicenseSha256 = "66b333b0f66759a0b710459e03f7029abe17f4358114a128d2c972e642961b49";

export const allowedLicenses = new Set([
  "MIT",
  "MIT-0",
  "ISC",
  "BSD-2-Clause",
  "BSD-3-Clause",
  "Apache-2.0",
  "MPL-2.0",
  "(MPL-2.0 OR Apache-2.0)",
  "CC0-1.0",
  "CC-BY-4.0",
  "BlueOak-1.0.0",
  "Unlicense",
]);

export function reviewedLicense(
  pkg: PackageLicense,
  bundledLicense?: Uint8Array,
): string | undefined {
  if (pkg.license !== undefined) return pkg.license;

  // **옛 npm 형식(`licenses` 배열)도 선언이다.** `license: "MIT"`와 증거의 세기가 같으므로 형식이 옛것이라는
  // 이유로 거절하지 않는다. 단 **항목이 하나일 때만** 받는다 — 여러 개는 "둘 중 고르라"는 뜻이라 사람이
  // 정할 일이고, 우리가 임의로 하나를 고르면 그 선택이 감사 기록에 안 남는다.
  if (pkg.licenses !== undefined && pkg.licenses.length === 1) {
    const type = pkg.licenses[0]?.type;
    if (type !== undefined && type.length > 0) return type;
  }
  if (pkg.name !== "khroma" || pkg.version !== "2.1.0" || bundledLicense === undefined) {
    return undefined;
  }

  const digest = createHash("sha256").update(bundledLicense).digest("hex");
  return digest === khroma210LicenseSha256 ? "MIT" : undefined;
}
