import type { AtomicRole } from "./live-preview-projection";
import {
  isNonNegativeSafeInteger,
  isPositiveSafeInteger,
  sourceRangeIsValid,
} from "./live-preview-identity";

export type AtomicProjectionRequest = Readonly<{
  editorEpoch: number;
  documentRevision: number;
  projectionGeneration: number;
  requestNonce: number;
  kind: AtomicRole;
  from: number;
  to: number;
}>;

export type AtomicProjectionResult = Readonly<{
  request: AtomicProjectionRequest;
  sourceHash: string;
  sanitizedPayload: string;
  assetGrants: readonly AssetGrant[];
}>;

export type AssetGrant = Readonly<{
  editorEpoch: number;
  assetNonce: number;
  opaqueId: number;
  normalizedPath: string;
  expectedMimeFamily: "raster-image" | "svg-image";
}>;

export const maxAtomicSourceBytes = {
  image: 32 * 1024,
  math: 32 * 1024,
  "fenced-code": 256 * 1024,
  mermaid: 32 * 1024,
} as const satisfies Readonly<Record<AtomicRole, number>>;
export const maxMermaidSourceLines = 512;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasExactRequestKeys(value: Record<string, unknown>): boolean {
  const expected = [
    "documentRevision",
    "editorEpoch",
    "from",
    "kind",
    "projectionGeneration",
    "requestNonce",
    "to",
  ];
  const actual = Object.keys(value).sort();
  return actual.length === expected.length && actual.every((key, index) => key === expected[index]);
}

function atomicRoleValid(value: string): value is AtomicRole {
  return value === "image" || value === "math" || value === "fenced-code" || value === "mermaid";
}

export function atomicProjectionRequestShapeValid(
  request: unknown,
  documentLength: unknown,
): request is AtomicProjectionRequest {
  return (
    isRecord(request) &&
    hasExactRequestKeys(request) &&
    isNonNegativeSafeInteger(documentLength) &&
    isPositiveSafeInteger(request.editorEpoch) &&
    isNonNegativeSafeInteger(request.documentRevision) &&
    isPositiveSafeInteger(request.projectionGeneration) &&
    isPositiveSafeInteger(request.requestNonce) &&
    atomicRoleValid(request.kind) &&
    sourceRangeIsValid(request.from, request.to, documentLength, false)
  );
}

/** Worker-side byte admission. The main thread owns only identity/range validation and never copies source. */
export function atomicSourceWithinLimit(kind: AtomicRole, source: string): boolean {
  let bytes = 0;
  let lines = 1;
  const cap = maxAtomicSourceBytes[kind];
  for (let index = 0; index < source.length; index += 1) {
    const code = source.charCodeAt(index);
    if (code === 0x0a && kind === "mermaid" && (lines += 1) > maxMermaidSourceLines) return false;
    if (code < 0x80) bytes += 1;
    else if (code < 0x800) bytes += 2;
    else if (code >= 0xd800 && code <= 0xdbff && index + 1 < source.length) {
      const low = source.charCodeAt(index + 1);
      if (low >= 0xdc00 && low <= 0xdfff) {
        bytes += 4;
        index += 1;
      } else bytes += 3;
    } else bytes += 3;
    if (bytes > cap) return false;
  }
  return true;
}
