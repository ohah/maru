export const maxDiagnosticTestRanges = 16;

export const projectionFallbackReasons = [
  "incomplete-tree",
  "ambiguous-syntax",
  "projection-limit",
  "table-limit",
  "atomic-not-enabled",
  "rich-source-limit",
  "renderer-unavailable",
  "stale-capability",
] as const;

export type ProjectionFallbackReason = (typeof projectionFallbackReasons)[number];
export type ProjectionFallbackCounts = Record<ProjectionFallbackReason, number>;

export type LivePreviewDiagnostics = {
  editorEpoch: number;
  documentRevision: number;
  projectionGeneration: number;
  decorationCount: number;
  desiredWidgets: number;
  mountedWidgets: number;
  activeSourceRangeCount: number;
  activeSourceRangesTruncated: boolean;
  fallbackCounts: ProjectionFallbackCounts;
};

export type DiagnosticsCommit = Readonly<{
  documentRevision: number;
  projectionGeneration: number;
  decorationCount: number;
  desiredWidgets: number;
  mountedWidgets: number;
  activeSourceRangeCount: number;
  activeSourceRanges: readonly Readonly<{ from: number; to: number }>[];
  fallbackCounts?: Readonly<Partial<ProjectionFallbackCounts>>;
}>;

function emptyFallbackCounts(): ProjectionFallbackCounts {
  return {
    "incomplete-tree": 0,
    "ambiguous-syntax": 0,
    "projection-limit": 0,
    "table-limit": 0,
    "atomic-not-enabled": 0,
    "rich-source-limit": 0,
    "renderer-unavailable": 0,
    "stale-capability": 0,
  };
}

export class LivePreviewDiagnosticsStore {
  private readonly fallbackCounts = emptyFallbackCounts();
  private readonly testRanges = new Uint32Array(maxDiagnosticTestRanges * 2);
  private testRangeCount = 0;
  private documentRevision = 0;
  private projectionGeneration = 1;
  private decorationCount = 0;
  private desiredWidgets = 0;
  private mountedWidgets = 0;
  private activeSourceRangeCount = 0;
  private activeSourceRangesTruncated = false;

  constructor(private readonly editorEpoch: number) {
    if (!isPositiveSafeInteger(editorEpoch))
      throw new RangeError("editor epoch must be a positive safe integer");
  }

  commit(commit: DiagnosticsCommit): void {
    if (
      !isNonNegativeSafeInteger(commit.documentRevision) ||
      !isPositiveSafeInteger(commit.projectionGeneration) ||
      !isNonNegativeSafeInteger(commit.decorationCount) ||
      !isNonNegativeSafeInteger(commit.desiredWidgets) ||
      !isNonNegativeSafeInteger(commit.mountedWidgets) ||
      !isNonNegativeSafeInteger(commit.activeSourceRangeCount) ||
      commit.activeSourceRanges.length > maxDiagnosticTestRanges ||
      commit.activeSourceRanges.length > commit.activeSourceRangeCount
    ) {
      throw new RangeError("invalid live preview diagnostics scalar");
    }
    for (const range of commit.activeSourceRanges) {
      if (!sourceRangeIsValid(range.from, range.to, 0xffff_ffff, true))
        throw new RangeError("invalid live preview diagnostics range");
    }
    for (const reason of projectionFallbackReasons) {
      const count = commit.fallbackCounts?.[reason] ?? 0;
      if (!isNonNegativeSafeInteger(count))
        throw new RangeError("invalid live preview diagnostics fallback count");
    }
    this.documentRevision = commit.documentRevision;
    this.projectionGeneration = commit.projectionGeneration;
    this.decorationCount = commit.decorationCount;
    this.desiredWidgets = commit.desiredWidgets;
    this.mountedWidgets = commit.mountedWidgets;
    this.activeSourceRangeCount = commit.activeSourceRangeCount;
    this.activeSourceRangesTruncated =
      commit.activeSourceRangeCount > commit.activeSourceRanges.length;
    this.testRangeCount = commit.activeSourceRanges.length;
    for (let index = 0; index < this.testRangeCount; index += 1) {
      const range = commit.activeSourceRanges[index];
      if (range === undefined) break;
      this.testRanges[index * 2] = range.from;
      this.testRanges[index * 2 + 1] = range.to;
    }
    for (const reason of projectionFallbackReasons) {
      this.fallbackCounts[reason] = commit.fallbackCounts?.[reason] ?? 0;
    }
  }

  writeSnapshot(target: LivePreviewDiagnostics): void {
    target.editorEpoch = this.editorEpoch;
    target.documentRevision = this.documentRevision;
    target.projectionGeneration = this.projectionGeneration;
    target.decorationCount = this.decorationCount;
    target.desiredWidgets = this.desiredWidgets;
    target.mountedWidgets = this.mountedWidgets;
    target.activeSourceRangeCount = this.activeSourceRangeCount;
    target.activeSourceRangesTruncated = this.activeSourceRangesTruncated;
    for (const reason of projectionFallbackReasons) {
      target.fallbackCounts[reason] = this.fallbackCounts[reason];
    }
  }

  writeTestOnlyActiveSourceRanges(target: Uint32Array): number {
    const valueCount = this.testRangeCount * 2;
    if (target.length < valueCount) throw new RangeError("diagnostics range target is too small");
    target.set(this.testRanges.subarray(0, valueCount), 0);
    return valueCount;
  }
}

export function createLivePreviewDiagnosticsSnapshot(): LivePreviewDiagnostics {
  return {
    editorEpoch: 0,
    documentRevision: 0,
    projectionGeneration: 0,
    decorationCount: 0,
    desiredWidgets: 0,
    mountedWidgets: 0,
    activeSourceRangeCount: 0,
    activeSourceRangesTruncated: false,
    fallbackCounts: emptyFallbackCounts(),
  };
}
import {
  isNonNegativeSafeInteger,
  isPositiveSafeInteger,
  sourceRangeIsValid,
} from "./live-preview-identity";
