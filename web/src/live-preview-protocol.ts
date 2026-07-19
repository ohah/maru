export const maxLivePreviewSourceBytes = 8 * 1024 * 1024;
export const maxLivePreviewResultBytes = 2 * 1024 * 1024;
export const maxLivePreviewWorkers = 8;
export const maxLivePreviewFragments = 8;
export const maxLivePreviewChanges = 1_024;
export const maxLivePreviewProjectionCodeUnits = 64 * 1024;

export type SourceChange = Readonly<{ from: number; to: number; insert: string }>;
export type ProjectionRange = Readonly<{ from: number; to: number; active: boolean }>;

export type SeedRequest = Readonly<{
  type: "seed";
  documentRevision: number;
  source: string;
}>;

export type ApplyRequest = Readonly<{
  type: "apply";
  baseRevision: number;
  targetRevision: number;
  changes: readonly SourceChange[];
  projectionGeneration: number;
  visibleRanges: readonly ProjectionRange[];
}>;

export type ProjectRequest = Readonly<{
  type: "project";
  documentRevision: number;
  projectionGeneration: number;
  visibleRanges: readonly ProjectionRange[];
}>;

export type LivePreviewRequest = SeedRequest | ApplyRequest | ProjectRequest;

export type ProjectedFragment = Readonly<{
  from: number;
  to: number;
  kind: string;
  html?: string;
}>;

export type ProjectionResult = Readonly<{
  type: "result";
  documentRevision: number;
  projectionGeneration: number;
  fragments: readonly ProjectedFragment[];
}>;

export type WorkerFailure = Readonly<{ type: "failure"; reason: string }>;
export type LivePreviewResponse = ProjectionResult | WorkerFailure;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isSafeRevision(value: unknown): value is number {
  return Number.isSafeInteger(value) && Number(value) >= 0;
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

export function isProjectionRange(value: unknown): value is ProjectionRange {
  return (
    isRecord(value) &&
    isSafeRevision(value.from) &&
    isSafeRevision(value.to) &&
    value.from <= value.to &&
    typeof value.active === "boolean"
  );
}

function projectionRangesAreBounded(value: unknown): value is readonly ProjectionRange[] {
  if (!Array.isArray(value) || value.length > 16 || !value.every(isProjectionRange)) return false;
  const viewports = value.filter((range) => !range.active);
  return (
    viewports.length === 1 &&
    viewports[0]!.to - viewports[0]!.from <= maxLivePreviewProjectionCodeUnits
  );
}

export function isSourceChange(value: unknown): value is SourceChange {
  return (
    isRecord(value) &&
    isSafeRevision(value.from) &&
    isSafeRevision(value.to) &&
    value.from <= value.to &&
    typeof value.insert === "string" &&
    utf8Length(value.insert) <= maxLivePreviewSourceBytes
  );
}

export function isLivePreviewRequest(value: unknown): value is LivePreviewRequest {
  if (!isRecord(value) || typeof value.type !== "string") return false;
  if (value.type === "seed") {
    return (
      isSafeRevision(value.documentRevision) &&
      typeof value.source === "string" &&
      utf8Length(value.source) <= maxLivePreviewSourceBytes
    );
  }
  if (value.type === "apply") {
    return (
      isSafeRevision(value.baseRevision) &&
      isSafeRevision(value.targetRevision) &&
      value.targetRevision > value.baseRevision &&
      Array.isArray(value.changes) &&
      value.changes.length <= maxLivePreviewChanges &&
      value.changes.every(isSourceChange) &&
      insertedBytes(value.changes) <= maxLivePreviewSourceBytes &&
      isSafeRevision(value.projectionGeneration) &&
      projectionRangesAreBounded(value.visibleRanges)
    );
  }
  if (value.type === "project") {
    return (
      isSafeRevision(value.documentRevision) &&
      isSafeRevision(value.projectionGeneration) &&
      projectionRangesAreBounded(value.visibleRanges)
    );
  }
  return false;
}

export function isProjectionResult(value: unknown): value is ProjectionResult {
  if (
    !isRecord(value) ||
    value.type !== "result" ||
    !isSafeRevision(value.documentRevision) ||
    !isSafeRevision(value.projectionGeneration) ||
    !Array.isArray(value.fragments) ||
    value.fragments.length > maxLivePreviewFragments
  ) {
    return false;
  }
  let resultBytes = 0;
  for (const fragment of value.fragments) {
    if (
      !isRecord(fragment) ||
      !isSafeRevision(fragment.from) ||
      !isSafeRevision(fragment.to) ||
      fragment.from >= fragment.to ||
      typeof fragment.kind !== "string" ||
      fragment.kind.length === 0 ||
      fragment.kind.length > 32 ||
      (fragment.html !== undefined && typeof fragment.html !== "string")
    ) {
      return false;
    }
    if (typeof fragment.html === "string") {
      const next = utf8Length(fragment.html);
      if (resultBytes > maxLivePreviewResultBytes - next) return false;
      resultBytes += next;
    }
    const metadataBytes = utf8Length(fragment.kind) + 32;
    if (resultBytes > maxLivePreviewResultBytes - metadataBytes) return false;
    resultBytes += metadataBytes;
  }
  return true;
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
  documentRevision: number,
  projectionGeneration: number,
): boolean {
  return (
    result.documentRevision === documentRevision &&
    result.projectionGeneration === projectionGeneration
  );
}
