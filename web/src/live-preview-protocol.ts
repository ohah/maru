import {
  atomicProjectionBatchWireBytes,
  atomicProjectionRequestShapeValid,
  atomicProjectionResultShapeValid,
  maxAtomicProjectionRequests,
  type AtomicProjectionRequest,
  type AtomicProjectionResult,
} from "./atomic-projection";

export const maxLivePreviewSourceBytes = 8 * 1024 * 1024;
export const maxLivePreviewResultBytes = 2 * 1024 * 1024;
export const maxLivePreviewWorkers = 8;
export const maxLivePreviewChanges = 1_024;
export const maxLivePreviewProjectionCodeUnits = 64 * 1024;

export type SourceChange = Readonly<{ from: number; to: number; insert: string }>;

export type SeedRequest = Readonly<{
  type: "seed";
  editorEpoch: number;
  documentRevision: number;
  source: string;
}>;

export type ApplyRequest = Readonly<{
  type: "apply";
  editorEpoch: number;
  baseRevision: number;
  targetRevision: number;
  changes: readonly SourceChange[];
  projectionGeneration: number;
  requests: readonly AtomicProjectionRequest[];
}>;

export type ProjectRequest = Readonly<{
  type: "project";
  editorEpoch: number;
  documentRevision: number;
  projectionGeneration: number;
  requests: readonly AtomicProjectionRequest[];
}>;

export type LivePreviewRequest = SeedRequest | ApplyRequest | ProjectRequest;

export const atomicProjectionRejectionReasons = [
  "rich-source-limit",
  "renderer-unavailable",
  "invalid-request",
] as const;
export type AtomicProjectionRejectionReason = (typeof atomicProjectionRejectionReasons)[number];

export type AtomicProjectionRejection = Readonly<{
  requestNonce: number;
  reason: AtomicProjectionRejectionReason;
}>;

export type ProjectionResult = Readonly<{
  type: "result";
  editorEpoch: number;
  documentRevision: number;
  projectionGeneration: number;
  results: readonly AtomicProjectionResult[];
  rejected: readonly AtomicProjectionRejection[];
}>;

export type WorkerFailure = Readonly<{ type: "failure"; reason: string }>;
export type LivePreviewResponse = ProjectionResult | WorkerFailure;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasExactKeys(value: Record<string, unknown>, expected: readonly string[]): boolean {
  const actual = Object.keys(value).sort();
  const sortedExpected = [...expected].sort();
  return (
    actual.length === sortedExpected.length &&
    actual.every((key, index) => key === sortedExpected[index])
  );
}

function isSafeRevision(value: unknown): value is number {
  return Number.isSafeInteger(value) && Number(value) >= 0;
}

function isPositiveSafeInteger(value: unknown): value is number {
  return Number.isSafeInteger(value) && Number(value) > 0;
}

export function utf8Length(value: string): number {
  return new TextEncoder().encode(value).byteLength;
}

export function insertedBytes(changes: readonly SourceChange[]): number {
  let total = 0;
  for (const change of changes) {
    const next = utf8Length(change.insert);
    if (total > maxLivePreviewSourceBytes - next) return maxLivePreviewSourceBytes + 1;
    total += next;
  }
  return total;
}

export function isSourceChange(value: unknown): value is SourceChange {
  return (
    isRecord(value) &&
    hasExactKeys(value, ["from", "insert", "to"]) &&
    isSafeRevision(value.from) &&
    isSafeRevision(value.to) &&
    value.from <= value.to &&
    typeof value.insert === "string" &&
    utf8Length(value.insert) <= maxLivePreviewSourceBytes
  );
}

function atomicRequestsValid(
  value: unknown,
  editorEpoch: number,
  documentRevision: number,
  projectionGeneration: number,
): value is readonly AtomicProjectionRequest[] {
  if (!Array.isArray(value) || value.length > maxAtomicProjectionRequests) return false;
  const nonces = new Set<number>();
  for (const request of value) {
    if (
      !atomicProjectionRequestShapeValid(request, Number.MAX_SAFE_INTEGER) ||
      request.editorEpoch !== editorEpoch ||
      request.documentRevision !== documentRevision ||
      request.projectionGeneration !== projectionGeneration ||
      nonces.has(request.requestNonce)
    ) {
      return false;
    }
    nonces.add(request.requestNonce);
  }
  return true;
}

export function isLivePreviewRequest(value: unknown): value is LivePreviewRequest {
  if (!isRecord(value) || typeof value.type !== "string") return false;
  if (value.type === "seed") {
    return (
      hasExactKeys(value, ["documentRevision", "editorEpoch", "source", "type"]) &&
      isPositiveSafeInteger(value.editorEpoch) &&
      isSafeRevision(value.documentRevision) &&
      typeof value.source === "string" &&
      utf8Length(value.source) <= maxLivePreviewSourceBytes
    );
  }
  if (value.type === "apply") {
    return (
      hasExactKeys(value, [
        "baseRevision",
        "changes",
        "editorEpoch",
        "projectionGeneration",
        "requests",
        "targetRevision",
        "type",
      ]) &&
      isPositiveSafeInteger(value.editorEpoch) &&
      isSafeRevision(value.baseRevision) &&
      isSafeRevision(value.targetRevision) &&
      value.targetRevision > value.baseRevision &&
      Array.isArray(value.changes) &&
      value.changes.length <= maxLivePreviewChanges &&
      value.changes.every(isSourceChange) &&
      insertedBytes(value.changes) <= maxLivePreviewSourceBytes &&
      isPositiveSafeInteger(value.projectionGeneration) &&
      atomicRequestsValid(
        value.requests,
        value.editorEpoch,
        value.targetRevision,
        value.projectionGeneration,
      )
    );
  }
  if (value.type === "project") {
    return (
      hasExactKeys(value, [
        "documentRevision",
        "editorEpoch",
        "projectionGeneration",
        "requests",
        "type",
      ]) &&
      isPositiveSafeInteger(value.editorEpoch) &&
      isSafeRevision(value.documentRevision) &&
      isPositiveSafeInteger(value.projectionGeneration) &&
      atomicRequestsValid(
        value.requests,
        value.editorEpoch,
        value.documentRevision,
        value.projectionGeneration,
      )
    );
  }
  return false;
}

function rejectionValid(value: unknown): value is AtomicProjectionRejection {
  return (
    isRecord(value) &&
    hasExactKeys(value, ["reason", "requestNonce"]) &&
    isPositiveSafeInteger(value.requestNonce) &&
    typeof value.reason === "string" &&
    atomicProjectionRejectionReasons.includes(value.reason as AtomicProjectionRejectionReason)
  );
}

export function isProjectionResult(value: unknown): value is ProjectionResult {
  if (
    !isRecord(value) ||
    !hasExactKeys(value, [
      "documentRevision",
      "editorEpoch",
      "projectionGeneration",
      "rejected",
      "results",
      "type",
    ]) ||
    value.type !== "result" ||
    !isPositiveSafeInteger(value.editorEpoch) ||
    !isSafeRevision(value.documentRevision) ||
    !isSafeRevision(value.projectionGeneration) ||
    !Array.isArray(value.results) ||
    !Array.isArray(value.rejected) ||
    value.results.length + value.rejected.length > maxAtomicProjectionRequests ||
    !value.results.every((result) =>
      atomicProjectionResultShapeValid(result, Number.MAX_SAFE_INTEGER),
    ) ||
    !value.rejected.every(rejectionValid)
  ) {
    return false;
  }
  const nonces = new Set<number>();
  for (const result of value.results) {
    if (
      result.request.editorEpoch !== value.editorEpoch ||
      result.request.documentRevision !== value.documentRevision ||
      result.request.projectionGeneration !== value.projectionGeneration ||
      nonces.has(result.request.requestNonce)
    ) {
      return false;
    }
    nonces.add(result.request.requestNonce);
  }
  for (const rejection of value.rejected) {
    if (nonces.has(rejection.requestNonce)) return false;
    nonces.add(rejection.requestNonce);
  }
  return atomicProjectionBatchWireBytes(value.results, value.rejected) <= maxLivePreviewResultBytes;
}

export function applySourceChanges(
  source: string,
  changes: readonly SourceChange[],
): string | null {
  let cursor = 0;
  let output = "";
  for (const change of changes) {
    if (change.from < cursor || change.to > source.length) return null;
    output += source.slice(cursor, change.from);
    output += change.insert;
    cursor = change.to;
  }
  return output + source.slice(cursor);
}

export function applySourceChangesBounded(
  source: string,
  sourceBytes: number,
  changes: readonly SourceChange[],
): Readonly<{ source: string; sourceBytes: number }> | null {
  let cursor = 0;
  let nextBytes = sourceBytes;
  for (const change of changes) {
    if (change.from < cursor || change.to > source.length) return null;
    if (!isUtf16Boundary(source, change.from) || !isUtf16Boundary(source, change.to)) return null;
    nextBytes -= utf8Length(source.slice(change.from, change.to));
    nextBytes += utf8Length(change.insert);
    if (nextBytes > maxLivePreviewSourceBytes) return null;
    cursor = change.to;
  }
  const next = applySourceChanges(source, changes);
  return next === null ? null : { source: next, sourceBytes: nextBytes };
}

function isUtf16Boundary(source: string, offset: number): boolean {
  if (offset <= 0 || offset >= source.length) return true;
  const previous = source.charCodeAt(offset - 1);
  const next = source.charCodeAt(offset);
  return !(previous >= 0xd800 && previous <= 0xdbff && next >= 0xdc00 && next <= 0xdfff);
}

export function projectionResultIsCurrent(
  result: ProjectionResult,
  editorEpoch: number,
  documentRevision: number,
  projectionGeneration: number,
): boolean {
  return (
    result.editorEpoch === editorEpoch &&
    result.documentRevision === documentRevision &&
    result.projectionGeneration === projectionGeneration
  );
}
