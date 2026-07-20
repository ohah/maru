import { syntaxTree } from "@codemirror/language";
import type { EditorState, SelectionRange } from "@codemirror/state";
import type { EditorView } from "@codemirror/view";
import {
  maxDiagnosticTestRanges,
  projectionFallbackReasons,
  type ProjectionFallbackCounts,
  type ProjectionFallbackReason,
} from "./live-preview-diagnostics";
import {
  compareProjectionEntries,
  maxLivePreviewProjectionEntries,
  maxLivePreviewSyntaxNodes,
  maxLivePreviewTableCells,
  type HiddenSyntaxRole,
  type ProjectionEntry,
  type StyleRole,
} from "./live-preview-projection";
import { maxLivePreviewProjectionCodeUnits } from "./live-preview-protocol";

export type EditableProjectionBudget = Readonly<{
  maxCodeUnits: number;
  maxSyntaxNodes: number;
  maxEntries: number;
}>;

export const editableProjectionBudget: EditableProjectionBudget = Object.freeze({
  maxCodeUnits: maxLivePreviewProjectionCodeUnits,
  maxSyntaxNodes: maxLivePreviewSyntaxNodes,
  maxEntries: maxLivePreviewProjectionEntries,
});

export type EditableProjectionMetrics = Readonly<{
  visitedCodeUnits: number;
  visitedSyntaxNodes: number;
  selectionRangeChecks: number;
  emittedEntries: number;
}>;

export type EditableProjection = Readonly<{
  window: Readonly<{ from: number; to: number }>;
  entries: readonly ProjectionEntry[];
  activeSourceRangeCount: number;
  activeSourceRanges: readonly Readonly<{ from: number; to: number }>[];
  fallbackCounts: Readonly<ProjectionFallbackCounts>;
  metrics: EditableProjectionMetrics;
}>;

type TreeCursorLike = {
  name: string;
  from: number;
  to: number;
  firstChild(): boolean;
  nextSibling(): boolean;
  parent(): boolean;
  node: SyntaxNodeLike;
};

type SyntaxNodeLike = {
  name: string;
  from: number;
  to: number;
  parent: SyntaxNodeLike | null;
  cursor(): TreeCursorLike;
};
type SyntaxNodeRefLike = Readonly<{
  name: string;
  from: number;
  to: number;
  type: Readonly<{ isSkipped: boolean }>;
  node: SyntaxNodeLike;
}>;

type DirectChild = Readonly<{ name: string; from: number; to: number; node: SyntaxNodeLike }>;

const projectionLimitReached = Object.freeze({ projectionLimitReached: true });

function emptyFallbackCounts(): ProjectionFallbackCounts {
  return Object.fromEntries(
    projectionFallbackReasons.map((reason) => [reason, 0]),
  ) as ProjectionFallbackCounts;
}

function validBudget(budget: EditableProjectionBudget): boolean {
  return (
    Number.isSafeInteger(budget.maxCodeUnits) &&
    budget.maxCodeUnits > 0 &&
    Number.isSafeInteger(budget.maxSyntaxNodes) &&
    budget.maxSyntaxNodes > 0 &&
    Number.isSafeInteger(budget.maxEntries) &&
    budget.maxEntries > 0
  );
}

/**
 * Computes the only discovery range used by render, diagnostics, and the performance probe. A large native
 * viewport may itself exceed the hard ceiling; in that case the caret-centered range wins and the rest remains
 * source text until it enters this bounded window.
 */
export function editableProjectionWindow(
  view: Pick<EditorView, "viewport" | "state">,
  maxCodeUnits = editableProjectionBudget.maxCodeUnits,
): Readonly<{ from: number; to: number }> {
  if (!Number.isSafeInteger(maxCodeUnits) || maxCodeUnits <= 0)
    throw new RangeError("invalid editable projection code-unit budget");
  const documentLength = view.state.doc.length;
  const viewportFrom = Math.max(0, Math.min(documentLength, view.viewport.from));
  const viewportTo = Math.max(viewportFrom, Math.min(documentLength, view.viewport.to));
  const viewportLength = Math.max(1, viewportTo - viewportFrom);
  const desiredFrom = Math.max(0, viewportFrom - viewportLength);
  const desiredTo = Math.min(documentLength, viewportTo + viewportLength);
  if (desiredTo - desiredFrom <= maxCodeUnits) return { from: desiredFrom, to: desiredTo };

  const anchor = Math.max(desiredFrom, Math.min(desiredTo, view.state.selection.main.head));
  const latestFrom = desiredTo - maxCodeUnits;
  const centeredFrom = anchor - Math.floor(maxCodeUnits / 2);
  const from = Math.max(desiredFrom, Math.min(latestFrom, centeredFrom));
  return { from, to: from + maxCodeUnits };
}

function rangeTouchesSelection(
  ranges: readonly SelectionRange[],
  from: number,
  to: number,
  checked: () => void,
): boolean {
  // CM6 normalizes selection ranges into source order. Locate the first range whose end can touch the owner,
  // then inspect only the boundary candidate(s), instead of multiplying every syntax owner by every cursor.
  let low = 0;
  let high = ranges.length;
  while (low < high) {
    const middle = low + Math.floor((high - low) / 2);
    const range = ranges[middle];
    checked();
    if (range !== undefined && range.to < from) low = middle + 1;
    else high = middle;
  }
  for (let index = low; index < ranges.length; index += 1) {
    const range = ranges[index];
    if (range === undefined) return false;
    checked();
    if (range.from > to) return false;
    if (range.empty ? range.head >= from && range.head <= to : range.from < to && range.to > from)
      return true;
  }
  return false;
}

function styleRoleForHeading(name: string): StyleRole | null {
  const match = /^(?:ATX|Setext)Heading([1-6])$/.exec(name);
  return match === null ? null : (`heading-${match[1]}` as StyleRole);
}

function atomicRoleForNode(name: string): "math" | null {
  return name === "InlineMath" || name === "BlockMath" || name === "Math" ? "math" : null;
}

function projectionOwnerNode(name: string): boolean {
  return (
    styleRoleForHeading(name) !== null ||
    name === "Emphasis" ||
    name === "StrongEmphasis" ||
    name === "Strikethrough" ||
    name === "InlineCode" ||
    name === "Blockquote" ||
    name === "ListItem" ||
    name === "HorizontalRule" ||
    name === "Escape" ||
    name === "TaskMarker" ||
    name === "Link" ||
    name === "Image" ||
    name === "FencedCode" ||
    name === "Table" ||
    atomicRoleForNode(name) !== null
  );
}

/**
 * Produces only closed source-coordinate facts. CSS classes, DOM nodes, HTML, and interaction callbacks belong
 * to the view adapter, so the CM6 incremental tree remains the sole syntax and geometry authority.
 */
export function buildEditableProjection(
  state: EditorState,
  window: Readonly<{ from: number; to: number }>,
  budget: EditableProjectionBudget = editableProjectionBudget,
): EditableProjection {
  if (!validBudget(budget)) throw new RangeError("invalid editable projection budget");
  if (
    !Number.isSafeInteger(window.from) ||
    !Number.isSafeInteger(window.to) ||
    window.from < 0 ||
    window.from > window.to ||
    window.to > state.doc.length
  ) {
    throw new RangeError("invalid editable projection window");
  }
  const boundedTo = Math.min(window.to, window.from + budget.maxCodeUnits);
  const boundedWindow = { from: window.from, to: boundedTo };
  const fallbackCounts = emptyFallbackCounts();
  const entries: ProjectionEntry[] = [];
  const activeSourceRanges: Array<{ from: number; to: number }> = [];
  let activeSourceRangeCount = 0;
  let lastActiveRange: { from: number; to: number } | null = null;
  let visitedSyntaxNodes = 0;
  let selectionRangeChecks = 0;

  const consumeSyntaxNode = () => {
    if (visitedSyntaxNodes >= budget.maxSyntaxNodes) throw projectionLimitReached;
    visitedSyntaxNodes += 1;
  };

  const directChildren = (node: SyntaxNodeLike): DirectChild[] => {
    const cursor = node.cursor();
    const children: DirectChild[] = [];
    if (!cursor.firstChild()) return children;
    do {
      consumeSyntaxNode();
      children.push({ name: cursor.name, from: cursor.from, to: cursor.to, node: cursor.node });
    } while (cursor.nextSibling());
    cursor.parent();
    return children;
  };

  const selectionTouches = (from: number, to: number): boolean =>
    rangeTouchesSelection(state.selection.ranges, from, to, () => {
      selectionRangeChecks += 1;
    });

  const recordSourceRange = (from: number, to: number) => {
    if (from >= to) return;
    if (lastActiveRange !== null && from <= lastActiveRange.to) {
      if (to > lastActiveRange.to) {
        lastActiveRange.to = to;
        const stored = activeSourceRanges.at(-1);
        if (stored === lastActiveRange) stored.to = to;
      }
      return;
    }
    activeSourceRangeCount += 1;
    lastActiveRange = { from, to };
    if (activeSourceRanges.length < maxDiagnosticTestRanges)
      activeSourceRanges.push(lastActiveRange);
  };

  const fallback = (reason: ProjectionFallbackReason, from: number, to: number) => {
    fallbackCounts[reason] += 1;
    recordSourceRange(Math.max(from, boundedWindow.from), Math.min(to, boundedWindow.to));
  };

  const emit = (entry: ProjectionEntry) => {
    if (entries.length >= budget.maxEntries) throw projectionLimitReached;
    entries.push(entry);
  };

  const hideMarkers = (
    node: SyntaxNodeRefLike,
    markerName: string,
    role: HiddenSyntaxRole,
  ): boolean => {
    const markers = directChildren(node.node).filter((child) => child.name === markerName);
    if (markers.length === 0) {
      fallback("ambiguous-syntax", node.from, node.to);
      return false;
    }
    if (selectionTouches(node.from, node.to)) {
      recordSourceRange(node.from, node.to);
      return true;
    }
    for (const marker of markers)
      emit({ type: "hidden-syntax", role, from: marker.from, to: marker.to });
    return true;
  };

  if (boundedWindow.from === boundedWindow.to) {
    return {
      window: boundedWindow,
      entries,
      activeSourceRangeCount,
      activeSourceRanges,
      fallbackCounts,
      metrics: {
        visitedCodeUnits: 0,
        visitedSyntaxNodes: 0,
        selectionRangeChecks: 0,
        emittedEntries: 0,
      },
    };
  }

  const tree = syntaxTree(state);
  if (tree.length < boundedWindow.to) {
    fallback("incomplete-tree", boundedWindow.from, boundedWindow.to);
    return {
      window: boundedWindow,
      entries,
      activeSourceRangeCount,
      activeSourceRanges,
      fallbackCounts,
      metrics: {
        visitedCodeUnits: boundedWindow.to - boundedWindow.from,
        visitedSyntaxNodes,
        selectionRangeChecks,
        emittedEntries: entries.length,
      },
    };
  }

  try {
    tree.iterate({
      from: boundedWindow.from,
      to: boundedWindow.to,
      enter(rawNode) {
        consumeSyntaxNode();
        const node = rawNode as unknown as SyntaxNodeRefLike;
        if (node.type.isSkipped) {
          fallback("incomplete-tree", node.from, node.to);
          return false;
        }
        if (node.name === "⚠") {
          fallback("ambiguous-syntax", node.from, node.to);
          return false;
        }
        if (
          projectionOwnerNode(node.name) &&
          (node.from < boundedWindow.from || node.to > boundedWindow.to)
        ) {
          fallback(
            node.name === "Table" ? "table-limit" : "projection-limit",
            Math.max(node.from, boundedWindow.from),
            Math.min(node.to, boundedWindow.to),
          );
          return false;
        }

        const headingRole = styleRoleForHeading(node.name);
        if (headingRole !== null) {
          if (hideMarkers(node, "HeaderMark", "heading-marker"))
            emit({ type: "style", role: headingRole, from: node.from, to: node.to });
          return;
        }

        if (node.name === "Emphasis" || node.name === "StrongEmphasis") {
          const strong = node.name === "StrongEmphasis";
          const markers = directChildren(node.node).filter(
            (child) => child.name === "EmphasisMark",
          );
          if (markers.length !== 2) {
            fallback("ambiguous-syntax", node.from, node.to);
            return false;
          }
          emit({
            type: "style",
            role: strong ? "strong" : "emphasis",
            from: node.from,
            to: node.to,
          });
          if (selectionTouches(node.from, node.to)) recordSourceRange(node.from, node.to);
          else
            for (const marker of markers)
              emit({
                type: "hidden-syntax",
                role: strong ? "strong-marker" : "emphasis-marker",
                from: marker.from,
                to: marker.to,
              });
          return;
        }

        if (node.name === "Strikethrough") {
          if (hideMarkers(node, "StrikethroughMark", "strike-marker"))
            emit({ type: "style", role: "strike", from: node.from, to: node.to });
          return;
        }

        if (node.name === "InlineCode") {
          const markers = directChildren(node.node).filter((child) => child.name === "CodeMark");
          if (markers.length !== 2) {
            fallback("ambiguous-syntax", node.from, node.to);
            return false;
          }
          emit({ type: "style", role: "inline-code", from: node.from, to: node.to });
          const contentFrom = markers[0]?.to ?? node.from;
          const contentTo = markers[1]?.from ?? node.to;
          if (selectionTouches(contentFrom, contentTo)) recordSourceRange(node.from, node.to);
          else
            for (const marker of markers)
              emit({ type: "hidden-syntax", role: "code-fence", from: marker.from, to: marker.to });
          return;
        }

        if (node.name === "Blockquote") {
          if (hideMarkers(node, "QuoteMark", "quote-marker"))
            emit({ type: "style", role: "quote", from: node.from, to: node.to });
          return;
        }

        if (node.name === "ListItem") {
          if (hideMarkers(node, "ListMark", "list-marker"))
            emit({ type: "style", role: "list", from: node.from, to: node.to });
          return;
        }

        if (node.name === "HorizontalRule") {
          emit({ type: "style", role: "thematic-break", from: node.from, to: node.to });
          recordSourceRange(node.from, node.to);
          return false;
        }

        if (node.name === "Escape") {
          if (selectionTouches(node.from, node.to)) recordSourceRange(node.from, node.to);
          else if (node.to - node.from >= 2)
            emit({ type: "hidden-syntax", role: "escape", from: node.from, to: node.from + 1 });
          else fallback("ambiguous-syntax", node.from, node.to);
          return false;
        }

        if (node.name === "TaskMarker") {
          const marker = state.sliceDoc(node.from, node.to);
          if (/^\[[ xX]\]$/.test(marker))
            emit({
              type: "task",
              checked: marker[1]?.toLowerCase() === "x",
              from: node.from,
              to: node.to,
            });
          else fallback("ambiguous-syntax", node.from, node.to);
          return false;
        }

        if (node.name === "Link") {
          const children = directChildren(node.node);
          const marks = children.filter((child) => child.name === "LinkMark");
          const destination = children.find((child) => child.name === "URL");
          if (marks.length !== 4 || destination === undefined) {
            fallback("ambiguous-syntax", node.from, node.to);
            return false;
          }
          const first = marks[0];
          const labelClose = marks[1];
          const destinationOpen = marks[2];
          const destinationClose = marks[3];
          if (
            first === undefined ||
            labelClose === undefined ||
            destinationOpen === undefined ||
            destinationClose === undefined ||
            first.to >= labelClose.from ||
            destinationOpen.to > destination.from ||
            destination.to > destinationClose.from
          ) {
            fallback("ambiguous-syntax", node.from, node.to);
            return false;
          }
          emit({
            type: "link",
            from: node.from,
            to: node.to,
            labelFrom: first.to,
            labelTo: labelClose.from,
            destinationFrom: destination.from,
            destinationTo: destination.to,
          });
          const destinationActive = selectionTouches(destinationOpen.from, destinationClose.to);
          const labelActive = selectionTouches(first.from, labelClose.to);
          if (destinationActive) recordSourceRange(node.from, node.to);
          else if (labelActive) {
            recordSourceRange(first.from, labelClose.to);
            emit({
              type: "hidden-syntax",
              role: "link-destination",
              from: destinationOpen.from,
              to: destinationClose.to,
            });
          } else {
            emit({ type: "hidden-syntax", role: "link-bracket", from: first.from, to: first.to });
            emit({
              type: "hidden-syntax",
              role: "link-destination",
              from: labelClose.from,
              to: destinationClose.to,
            });
          }
          return false;
        }

        if (node.name === "Image") {
          if (selectionTouches(node.from, node.to)) recordSourceRange(node.from, node.to);
          else emit({ type: "atomic", role: "image", from: node.from, to: node.to });
          return false;
        }

        if (node.name === "FencedCode") {
          const info = directChildren(node.node).find((child) => child.name === "CodeInfo");
          const isMermaid =
            info !== undefined &&
            info.to - info.from <= 64 &&
            state.sliceDoc(info.from, info.to).trim().toLowerCase() === "mermaid";
          if (selectionTouches(node.from, node.to)) recordSourceRange(node.from, node.to);
          else
            emit({
              type: "atomic",
              role: isMermaid ? "mermaid" : "fenced-code",
              from: node.from,
              to: node.to,
            });
          return false;
        }

        if (node.name === "Table") {
          type TableCellEntry = Extract<ProjectionEntry, { type: "table-cell" }>;
          const staged: Array<Omit<TableCellEntry, "rowCount">> = [];
          const tableChildren = directChildren(node.node);
          const rows = tableChildren.filter(
            (child) => child.name === "TableHeader" || child.name === "TableRow",
          );
          let columnCount: number | null = null;
          if (rows.length === 0) {
            fallback("ambiguous-syntax", node.from, node.to);
            return false;
          }
          const lastDataRow = rows.findLast((row) => row.name === "TableRow");
          const lastPhysicalLine = state.doc.lineAt(Math.max(node.from, node.to - 1));
          const appendAnchor =
            lastDataRow ??
            tableChildren.find(
              (child) =>
                child.name === "TableDelimiter" &&
                child.from >= lastPhysicalLine.from &&
                child.to <= lastPhysicalLine.to,
            );
          if (appendAnchor === undefined) {
            fallback("ambiguous-syntax", node.from, node.to);
            return false;
          }
          const appendLine = state.doc.lineAt(appendAnchor.from);
          const appendPrefixFrom = appendLine.from;
          const appendPrefixTo = appendAnchor.from;
          for (const [row, rowNode] of rows.entries()) {
            const children = directChildren(rowNode.node);
            const delimiters = children.filter((child) => child.name === "TableDelimiter");
            if (
              delimiters.length < 1 ||
              delimiters.some(
                (delimiter, index) =>
                  delimiter.to - delimiter.from !== 1 ||
                  state.sliceDoc(delimiter.from, delimiter.to) !== "|" ||
                  (index > 0 && (delimiters[index - 1]?.to ?? delimiter.from) > delimiter.from),
              )
            ) {
              fallback("ambiguous-syntax", node.from, node.to);
              return false;
            }
            const hasLeadingDelimiter = delimiters[0]?.from === rowNode.from;
            const hasTrailingDelimiter = delimiters.at(-1)?.to === rowNode.to;
            const currentColumnCount =
              delimiters.length + 1 - Number(hasLeadingDelimiter) - Number(hasTrailingDelimiter);
            if (currentColumnCount <= 0) {
              fallback("ambiguous-syntax", node.from, node.to);
              return false;
            }
            if (columnCount === null) columnCount = currentColumnCount;
            else if (columnCount !== currentColumnCount) {
              // A rectangular TableProjection is required before key navigation can own this table. Keeping the
              // whole table as source avoids inventing a row/column mapping for ragged GFM input.
              fallback("ambiguous-syntax", node.from, node.to);
              return false;
            }
            const ranges: Array<Readonly<{ from: number; to: number }>> = [];
            for (let column = 0; column < currentColumnCount; column += 1) {
              if (staged.length >= maxLivePreviewTableCells) {
                fallback("table-limit", node.from, node.to);
                return false;
              }
              const from = hasLeadingDelimiter
                ? (delimiters[column]?.to ?? rowNode.to)
                : column === 0
                  ? rowNode.from
                  : (delimiters[column - 1]?.to ?? rowNode.to);
              const to = hasLeadingDelimiter
                ? (delimiters[column + 1]?.from ?? rowNode.to)
                : (delimiters[column]?.from ?? rowNode.to);
              if (from > to || from < rowNode.from || to > rowNode.to) {
                fallback("ambiguous-syntax", node.from, node.to);
                return false;
              }
              ranges.push({ from, to });
              staged.push({
                type: "table-cell",
                tableFrom: node.from,
                tableTo: node.to,
                appendPrefixFrom,
                appendPrefixTo,
                from,
                to,
                row,
                column,
                columnCount: currentColumnCount,
              });
            }
            const syntaxCells = children.filter((child) => child.name === "TableCell");
            if (
              syntaxCells.some(
                (cell) => !ranges.some((range) => range.from <= cell.from && cell.to <= range.to),
              )
            ) {
              fallback("ambiguous-syntax", node.from, node.to);
              return false;
            }
          }
          for (const cell of staged) emit({ ...cell, rowCount: rows.length });
          return false;
        }

        const mathRole = atomicRoleForNode(node.name);
        if (mathRole !== null) {
          if (selectionTouches(node.from, node.to)) recordSourceRange(node.from, node.to);
          else emit({ type: "atomic", role: mathRole, from: node.from, to: node.to });
          return false;
        }
      },
    });
  } catch (error) {
    if (error !== projectionLimitReached) throw error;
    entries.length = 0;
    activeSourceRanges.length = 0;
    activeSourceRangeCount = 0;
    lastActiveRange = null;
    for (const reason of projectionFallbackReasons) fallbackCounts[reason] = 0;
    fallback("projection-limit", boundedWindow.from, boundedWindow.to);
  }

  entries.sort(compareProjectionEntries);
  return {
    window: boundedWindow,
    entries,
    activeSourceRangeCount,
    activeSourceRanges,
    fallbackCounts,
    metrics: {
      visitedCodeUnits: boundedWindow.to - boundedWindow.from,
      visitedSyntaxNodes,
      selectionRangeChecks,
      emittedEntries: entries.length,
    },
  };
}

export function editableProjectionsEqual(
  left: readonly ProjectionEntry[],
  right: readonly ProjectionEntry[],
): boolean {
  if (left.length !== right.length) return false;
  for (let index = 0; index < left.length; index += 1) {
    const leftEntry = left[index];
    const rightEntry = right[index];
    if (leftEntry === undefined || rightEntry === undefined) return false;
    if (compareProjectionEntries(leftEntry, rightEntry) !== 0) return false;
  }
  return true;
}
