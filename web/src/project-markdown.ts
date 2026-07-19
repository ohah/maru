import {
  maxLivePreviewFragments,
  maxLivePreviewProjectionCodeUnits,
  maxLivePreviewResultBytes,
  type ProjectedFragment,
  type ProjectionRange,
} from "./live-preview-protocol";
import { renderMarkdown } from "./markdown";

const maxFragmentSourceBytes = 64 * 1024;
const maxBlocksPerChunk = 16;

type BlockRange = Readonly<{ from: number; to: number; kind: string; forceSource?: boolean }>;
type ProjectionChunk = Readonly<{
  from: number;
  to: number;
  kind: string;
  blockCount: number;
  sourceBytes: number;
  sourcePreserving: boolean;
}>;

function utf8Length(value: string): number {
  return new TextEncoder().encode(value).byteLength;
}

function intersects(from: number, to: number, range: ProjectionRange): boolean {
  if (range.from === range.to) return range.from >= from && range.from <= to;
  return range.from < to && range.to > from;
}

function lineEnd(source: string, from: number, limit = source.length): number {
  for (let cursor = from; cursor < limit; cursor += 1) {
    if (source.charCodeAt(cursor) === 0x0a) return cursor + 1;
  }
  return limit;
}

function previousLineFrom(source: string, cursor: number, floor: number): number {
  for (let index = cursor - 2; index >= floor; index -= 1) {
    if (source.charCodeAt(index) === 0x0a) return index + 1;
  }
  return floor;
}

function isBlankLine(source: string, from: number, to: number): boolean {
  return /^[\t \r]*\n?$/.test(source.slice(from, to));
}

function blockKind(source: string, from: number, to: number): string {
  const first = source.slice(from, lineEnd(source, from, to)).trimStart();
  if (/^#{1,6}(?:\s|$)/.test(first)) return "heading";
  if (/^(?:```|~~~)/.test(first)) return "code";
  if (/^(?:[-+*]|\d+[.)])\s/.test(first)) return "list";
  if (/^>\s?/.test(first)) return "blockquote";
  if (/^[-*_](?:\s*[-*_]){2,}\s*$/.test(first)) return "thematicBreak";
  return to > from ? "paragraph" : "unknown";
}

/**
 * Builds a conservative top-level range index without parsing the full Markdown AST. Rendering still goes
 * through the existing sanitized Markdown pipeline, but Project requests only query these ranges and never
 * reparse the full source. Blank-line chunks and fenced blocks are sufficient for source-preserving fallback:
 * an ambiguous chunk may render less richly, but it cannot execute or corrupt the editable source.
 */
function indexBlocks(source: string, fromOffset: number, toOffset: number): readonly BlockRange[] {
  const blocks: BlockRange[] = [];
  let cursor = fromOffset;
  while (cursor < toOffset) {
    let end = lineEnd(source, cursor, toOffset);
    if (isBlankLine(source, cursor, end)) {
      cursor = end;
      continue;
    }
    const from = cursor;
    const first = source.slice(cursor, end).trimStart();
    const fence = /^(?<marker>`{3,}|~{3,})/.exec(first)?.groups?.marker;
    if (fence !== undefined) {
      cursor = end;
      const close = new RegExp(`^[\\t ]{0,3}${fence[0]}{${fence.length},}[\\t ]*$`);
      while (cursor < toOffset) {
        end = lineEnd(source, cursor, toOffset);
        const line = source.slice(cursor, end).replace(/[\r\n]+$/, "");
        cursor = end;
        if (close.test(line)) break;
      }
    } else {
      cursor = end;
      while (cursor < toOffset) {
        end = lineEnd(source, cursor, toOffset);
        if (isBlankLine(source, cursor, end)) break;
        cursor = end;
      }
    }
    const to = cursor;
    if (to > from) blocks.push({ from, to, kind: blockKind(source, from, to) });
  }
  return blocks;
}

function projectionWindow(
  source: string,
  range: ProjectionRange,
): Readonly<{ from: number; to: number; truncatedStart: boolean; truncatedEnd: boolean }> {
  const rangeFrom = Math.min(source.length, range.from);
  const rangeTo = Math.min(
    source.length,
    rangeFrom + Math.min(range.to - range.from, maxLivePreviewProjectionCodeUnits),
  );
  const backwardBudget = Math.floor(
    (maxLivePreviewProjectionCodeUnits - (rangeTo - rangeFrom)) / 2,
  );
  const floor = Math.max(0, rangeFrom - backwardBudget);
  let from = rangeFrom;
  let cursor = rangeFrom;
  while (cursor > floor) {
    const lineFrom = previousLineFrom(source, cursor, floor);
    if (isBlankLine(source, lineFrom, cursor)) {
      from = cursor;
      break;
    }
    from = lineFrom;
    cursor = lineFrom;
  }
  // No boundary within 64 KiB means the intersecting block cannot be rendered under the fragment source cap.
  // Start at the visible position so it remains source-preserving, then index later complete blocks normally.
  const truncatedStart = from === floor && floor > 0;
  if (truncatedStart) from = rangeFrom;

  const ceiling = Math.min(source.length, from + maxLivePreviewProjectionCodeUnits);
  let to = Math.max(from, Math.min(rangeTo, ceiling));
  cursor = to;
  let endedAtBoundary = false;
  while (cursor < ceiling) {
    const end = lineEnd(source, cursor, ceiling);
    to = end;
    if (isBlankLine(source, cursor, end)) {
      endedAtBoundary = true;
      break;
    }
    cursor = end;
  }
  return {
    from,
    to,
    truncatedStart,
    truncatedEnd:
      range.to > ceiling || (!endedAtBoundary && to >= ceiling && ceiling < source.length),
  };
}

function requiresSource(blockSource: string, blockBytes: number): boolean {
  return (
    /^(?: {0,3})(?:```|~~~)mermaid(?:\s|$)/i.test(blockSource) ||
    /!\[[^\]]*\]\([^)]*\)/.test(blockSource) ||
    blockBytes > maxFragmentSourceBytes
  );
}

/**
 * Inactive blocks share one renderer capability whenever possible. The first pass preserves the documented
 * 16-block scheduling boundary; if that would exceed the eight-widget hard cap, a second pass joins adjacent
 * inactive chunks up to the independent 64 KiB source cap. Source-preserving chunks are never crossed.
 */
function chunkBlocks(
  source: string,
  blocks: readonly BlockRange[],
  visibleRanges: readonly ProjectionRange[],
): ProjectionChunk[] {
  const chunks: ProjectionChunk[] = [];
  let pending: ProjectionChunk | undefined;
  const flush = () => {
    if (pending !== undefined) chunks.push(pending);
    pending = undefined;
  };

  for (const block of blocks) {
    if (!visibleRanges.some((range) => intersects(block.from, block.to, range))) continue;
    const active = visibleRanges.some(
      (range) => range.active && intersects(block.from, block.to, range),
    );
    if (active || block.forceSource === true) {
      flush();
      chunks.push({
        from: block.from,
        to: block.to,
        kind: block.kind,
        blockCount: 1,
        sourceBytes: maxFragmentSourceBytes + 1,
        sourcePreserving: true,
      });
      continue;
    }
    const blockSource = source.slice(block.from, block.to);
    const blockBytes = utf8Length(blockSource);
    if (requiresSource(blockSource, blockBytes)) {
      flush();
      chunks.push({
        from: block.from,
        to: block.to,
        kind: block.kind,
        blockCount: 1,
        sourceBytes: blockBytes,
        sourcePreserving: true,
      });
      continue;
    }

    if (pending === undefined) {
      pending = {
        from: block.from,
        to: block.to,
        kind: block.kind,
        blockCount: 1,
        sourceBytes: blockBytes,
        sourcePreserving: false,
      };
      continue;
    }

    const appendedBytes = utf8Length(source.slice(pending.to, block.to));
    const combinedBytes = pending.sourceBytes + appendedBytes;
    if (pending.blockCount === maxBlocksPerChunk || combinedBytes > maxFragmentSourceBytes) {
      flush();
      pending = {
        from: block.from,
        to: block.to,
        kind: block.kind,
        blockCount: 1,
        sourceBytes: blockBytes,
        sourcePreserving: false,
      };
      continue;
    }
    pending = {
      from: pending.from,
      to: block.to,
      kind: "chunk",
      blockCount: pending.blockCount + 1,
      sourceBytes: combinedBytes,
      sourcePreserving: false,
    };
  }
  flush();

  if (chunks.length <= maxLivePreviewFragments) return chunks;

  // A single left-to-right pass maximally packs each inactive run. This avoids repeatedly encoding or scanning
  // the same source while producing the minimum chunk count possible without crossing a source-preserving block.
  const compacted: ProjectionChunk[] = [];
  for (const chunk of chunks) {
    const previous = compacted.at(-1);
    if (previous === undefined || previous.sourcePreserving || chunk.sourcePreserving) {
      compacted.push(chunk);
      continue;
    }
    const gapBytes = utf8Length(source.slice(previous.to, chunk.from));
    const combinedBytes = previous.sourceBytes + gapBytes + chunk.sourceBytes;
    if (combinedBytes > maxFragmentSourceBytes) {
      compacted.push(chunk);
      continue;
    }
    compacted[compacted.length - 1] = {
      from: previous.from,
      to: chunk.to,
      kind: "chunk",
      blockCount: previous.blockCount + chunk.blockCount,
      sourceBytes: combinedBytes,
      sourcePreserving: false,
    };
  }
  return compacted;
}

export class MarkdownProjectionIndex {
  constructor(private readonly source: string) {}

  project(visibleRanges: readonly ProjectionRange[]): readonly ProjectedFragment[] {
    if (visibleRanges.length === 0) return [];
    const fragments: ProjectedFragment[] = [];
    let resultBytes = 0;
    // Block discovery belongs to exactly one bounded viewport. Selection ranges only mark blocks inside that
    // window active; Select All must never widen discovery to the full document.
    const viewport = visibleRanges.find((range) => !range.active);
    if (viewport === undefined) return [];
    const window = projectionWindow(this.source, viewport);
    const indexed = indexBlocks(this.source, window.from, window.to);
    const blocks = indexed.map((block, index) => ({
      ...block,
      forceSource:
        (index === 0 && window.truncatedStart) ||
        (index === indexed.length - 1 && window.truncatedEnd),
    }));
    for (const chunk of chunkBlocks(this.source, blocks, visibleRanges)) {
      const { from, to, kind } = chunk;
      const chunkSource = this.source.slice(from, to);
      let html: string | undefined;
      const metadataBytes = utf8Length(kind) + 32;
      if (resultBytes > maxLivePreviewResultBytes - metadataBytes) break;
      resultBytes += metadataBytes;
      if (!chunk.sourcePreserving) {
        const rendered = renderMarkdown(chunkSource);
        const renderedBytes = utf8Length(rendered);
        if (
          !rendered.includes("data-maru-asset-path") &&
          resultBytes <= maxLivePreviewResultBytes - renderedBytes
        ) {
          html = rendered;
          resultBytes += renderedBytes;
        }
      }
      fragments.push(html === undefined ? { from, to, kind } : { from, to, kind, html });
      if (fragments.length === maxLivePreviewFragments) break;
    }
    return fragments;
  }
}

export function projectMarkdown(
  source: string,
  visibleRanges: readonly ProjectionRange[],
): readonly ProjectedFragment[] {
  return new MarkdownProjectionIndex(source).project(visibleRanges);
}
