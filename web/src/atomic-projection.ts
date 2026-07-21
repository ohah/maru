import type { AtomicRole } from "./live-preview-projection";
import { normalizeAssetReference } from "./asset-path";
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
  mermaidSource: string | null;
}>;

const atomicResultFixedWireBytes = 128;
const atomicGrantFixedWireBytes = 64;
const atomicBatchFixedWireBytes = 128;
const atomicRejectionFixedWireBytes = 64;
const atomicReservedRejectionWireBytes = 128;
const atomicWireEncoder = new TextEncoder();

type AtomicWireRejection = Readonly<{ requestNonce: number; reason: string }>;

/** Conservative structured-clone admission shared by the worker producer and shell validator. */
export function atomicProjectionResultWireBytes(result: AtomicProjectionResult): number {
  let bytes =
    atomicResultFixedWireBytes +
    atomicWireEncoder.encode(result.sourceHash).byteLength +
    atomicWireEncoder.encode(result.sanitizedPayload).byteLength +
    (result.mermaidSource === null ? 0 : atomicWireEncoder.encode(result.mermaidSource).byteLength);
  for (const grant of result.assetGrants) {
    bytes +=
      atomicGrantFixedWireBytes +
      atomicWireEncoder.encode(grant.normalizedPath).byteLength +
      atomicWireEncoder.encode(grant.expectedMimeFamily).byteLength;
  }
  return bytes;
}

/** Conservative whole-message admission shared by the worker producer and shell validator. */
export function atomicProjectionBatchWireBytes(
  results: readonly AtomicProjectionResult[],
  rejected: readonly AtomicWireRejection[],
  reservedRejections = 0,
): number {
  let bytes = atomicBatchFixedWireBytes + reservedRejections * atomicReservedRejectionWireBytes;
  for (const result of results) bytes += atomicProjectionResultWireBytes(result);
  for (const rejection of rejected)
    bytes += atomicRejectionFixedWireBytes + atomicWireEncoder.encode(rejection.reason).byteLength;
  return bytes;
}

// 활성 atomic widget(이미지·수식·fenced·Mermaid)의 batch·retention 상한. 문서의 "atomic widget batch≤8"이
// 이 상수다. 제거된 legacy fragment 모델의 "fragment당 4 diagrams"와는 무관하다(docs/file-panel.md 참조).
export const maxAtomicProjectionRequests = 8;
export const maxAtomicAssetGrants = 8;

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
// Mermaid source의 **줄 개수** 상한(줄바꿈 수 기준). Zig admission의 `max_line_bytes`(mermaid_coordinator.zig)는
// 같은 512지만 **한 줄의 바이트** 상한으로 축이 다르다: 513개 짧은 줄은 여기서, 513바이트 단일 줄은 Zig가
// 먼저 source-preserving으로 강등한다(둘 다 fail-safe). docs/file-panel.md "Mermaid fence 계약" 단일 출처.
export const maxMermaidSourceLines = 512;

let atomicSourceHashProbe: ((bytes: number) => void) | null = null;

/** Test/perf-only observation of actual fingerprint work; production pays one nullable branch per hash. */
export function startAtomicSourceHashProbe(): Readonly<{ stop: () => number }> {
  if (atomicSourceHashProbe !== null) throw new Error("atomic source hash probe already active");
  let hashedBytes = 0;
  atomicSourceHashProbe = (bytes) => {
    hashedBytes += bytes;
  };
  return {
    stop: () => {
      atomicSourceHashProbe = null;
      return hashedBytes;
    },
  };
}

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

function hasExactKeys(value: Record<string, unknown>, expected: readonly string[]): boolean {
  const actual = Object.keys(value).sort();
  const sortedExpected = [...expected].sort();
  return (
    actual.length === sortedExpected.length &&
    actual.every((key, index) => key === sortedExpected[index])
  );
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

export function assetGrantShapeValid(value: unknown): value is AssetGrant {
  return (
    isRecord(value) &&
    hasExactKeys(value, [
      "editorEpoch",
      "assetNonce",
      "opaqueId",
      "normalizedPath",
      "expectedMimeFamily",
    ]) &&
    isPositiveSafeInteger(value.editorEpoch) &&
    isPositiveSafeInteger(value.assetNonce) &&
    isPositiveSafeInteger(value.opaqueId) &&
    typeof value.normalizedPath === "string" &&
    value.normalizedPath.length > 0 &&
    value.normalizedPath.length <= 4_096 &&
    normalizeAssetReference(value.normalizedPath) === value.normalizedPath &&
    (value.expectedMimeFamily === "raster-image" || value.expectedMimeFamily === "svg-image")
  );
}

export function atomicProjectionResultShapeValid(
  value: unknown,
  documentLength: number,
): value is AtomicProjectionResult {
  if (
    !isRecord(value) ||
    !hasExactKeys(value, [
      "request",
      "sourceHash",
      "sanitizedPayload",
      "assetGrants",
      "mermaidSource",
    ]) ||
    !atomicProjectionRequestShapeValid(value.request, documentLength) ||
    typeof value.sourceHash !== "string" ||
    !(
      (value.request.kind === "mermaid" && /^[0-9a-f]{64}$/.test(value.sourceHash)) ||
      (value.request.kind !== "mermaid" && /^[0-9a-f]{16}$/.test(value.sourceHash))
    ) ||
    typeof value.sanitizedPayload !== "string" ||
    !Array.isArray(value.assetGrants) ||
    value.assetGrants.length > maxAtomicAssetGrants ||
    !value.assetGrants.every(assetGrantShapeValid) ||
    !(
      (value.request.kind === "mermaid" &&
        typeof value.mermaidSource === "string" &&
        value.mermaidSource.length > 0 &&
        atomicSourceWithinLimit("mermaid", value.mermaidSource) &&
        value.sanitizedPayload.length === 0 &&
        value.assetGrants.length === 0) ||
      (value.request.kind !== "mermaid" && value.mermaidSource === null)
    )
  ) {
    return false;
  }
  const seenOpaqueIds = new Set<number>();
  const seenNonces = new Set<number>();
  for (const grant of value.assetGrants) {
    if (
      grant.editorEpoch !== value.request.editorEpoch ||
      seenOpaqueIds.has(grant.opaqueId) ||
      seenNonces.has(grant.assetNonce)
    ) {
      return false;
    }
    seenOpaqueIds.add(grant.opaqueId);
    seenNonces.add(grant.assetNonce);
  }
  return true;
}

/** A deterministic worker-owned source fingerprint. The caller must run the byte cap first. */
export function atomicSourceFingerprint(
  source: string,
): Readonly<{ sourceHash: string; sourceBytes: number }> {
  let high = 0xcbf29ce4;
  let low = 0x84222325;
  const bytes = new TextEncoder().encode(source);
  atomicSourceHashProbe?.(bytes.byteLength);
  for (const byte of bytes) {
    low ^= byte;
    const nextLow = Math.imul(low, 0x1b3);
    const carry = Math.floor(((low >>> 0) * 0x1b3) / 0x1_0000_0000);
    const nextHigh = (Math.imul(high, 0x1b3) + Math.imul(low, 0x100) + carry) >>> 0;
    high = nextHigh;
    low = nextLow >>> 0;
  }
  return {
    sourceHash: high.toString(16).padStart(8, "0") + low.toString(16).padStart(8, "0"),
    sourceBytes: bytes.byteLength,
  };
}

export function atomicSourceHash(source: string): string {
  return atomicSourceFingerprint(source).sourceHash;
}
