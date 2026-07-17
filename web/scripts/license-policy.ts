import { createHash } from "node:crypto";

export type PackageLicense = {
  name?: string;
  version?: string;
  license?: string;
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
  if (pkg.name !== "khroma" || pkg.version !== "2.1.0" || bundledLicense === undefined) {
    return undefined;
  }

  const digest = createHash("sha256").update(bundledLicense).digest("hex");
  return digest === khroma210LicenseSha256 ? "MIT" : undefined;
}
