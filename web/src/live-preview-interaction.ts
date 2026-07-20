import { EditorSelection, Transaction } from "@codemirror/state";
import type { EditorView } from "@codemirror/view";
import {
  interactionGuardRejection,
  type EditorInteractionGuard,
  type IntentResult,
  type LivePreviewIntent,
} from "./live-preview-intent";
import type { ProjectionEntry } from "./live-preview-projection";
import { maxLivePreviewTableCells, projectionEntriesEqual } from "./live-preview-projection";
import { maxLivePreviewProjectionCodeUnits } from "./live-preview-protocol";

export const maxRetainedLivePreviewIntents = 8;

export type LivePreviewExternalAction = Readonly<{
  type: "open-link";
  href: string;
  forceSystem: boolean;
}>;

export type LivePreviewDispatchResult = Readonly<{
  result: IntentResult;
  externalAction: LivePreviewExternalAction | null;
  cm6Transactions: 0 | 1;
  externalActions: 0 | 1;
}>;

export class GestureNonceLedger {
  private lastConsumed = 0;

  isFresh(nonce: number): boolean {
    return Number.isSafeInteger(nonce) && nonce > this.lastConsumed;
  }

  consume(nonce: number): boolean {
    if (!this.isFresh(nonce)) return false;
    this.lastConsumed = nonce;
    return true;
  }
}

export type LivePreviewIntentQueueMetrics = Readonly<{
  retained: number;
  maxRetained: number;
  dropped: number;
  completed: number;
}>;

/**
 * Keeps at most one intent executing and a fixed total of running plus pending intents. The runner may await a
 * native bridge without occupying the caller's document mutation queue; subsequent intents remain plain bounded
 * data until the current runner completes.
 */
export class BoundedLivePreviewIntentQueue {
  private readonly pending: LivePreviewIntent[] = [];
  private running = false;
  private destroyed = false;
  private maxRetained = 0;
  private dropped = 0;
  private completed = 0;

  constructor(
    private readonly runner: (intent: LivePreviewIntent) => Promise<void>,
    private readonly onError: (error: unknown) => void = () => {},
    private readonly onMetricsChanged: (metrics: LivePreviewIntentQueueMetrics) => void = () => {},
  ) {}

  enqueue(intent: LivePreviewIntent): boolean {
    if (this.destroyed || this.retainedCount() >= maxRetainedLivePreviewIntents) {
      this.dropped += 1;
      this.publishMetrics();
      return false;
    }
    this.pending.push(intent);
    if (!this.running) {
      this.running = true;
      void this.drain();
    }
    this.maxRetained = Math.max(this.maxRetained, this.retainedCount());
    this.publishMetrics();
    return true;
  }

  clearPending(): number {
    const cleared = this.pending.length;
    this.pending.length = 0;
    this.publishMetrics();
    return cleared;
  }

  destroy(): void {
    this.destroyed = true;
    this.clearPending();
  }

  metrics(): LivePreviewIntentQueueMetrics {
    return {
      retained: this.retainedCount(),
      maxRetained: this.maxRetained,
      dropped: this.dropped,
      completed: this.completed,
    };
  }

  private retainedCount(): number {
    return this.pending.length + Number(this.running);
  }

  private publishMetrics(): void {
    try {
      this.onMetricsChanged(this.metrics());
    } catch {
      // Diagnostics must never alter queue admission or recovery.
    }
  }

  private async drain(): Promise<void> {
    while (!this.destroyed) {
      const intent = this.pending.shift();
      if (intent === undefined) break;
      // `running` now represents this shifted intent. Publish after removing it from pending so a stalled next
      // runner cannot leave diagnostics one retained item above the actual queue.
      this.publishMetrics();
      try {
        await this.runner(intent);
      } catch (error) {
        try {
          this.onError(error);
        } catch {
          // Error presentation is not part of the queue state machine.
        }
      } finally {
        this.completed += 1;
      }
    }
    this.running = false;
    this.publishMetrics();
  }
}

export type LivePreviewIntentContext = Readonly<{
  view: EditorView;
  guard: EditorInteractionGuard;
  currentEntry: ProjectionEntry | null;
  currentTableCells: readonly TableCellProjection[];
}>;

export type TableCellProjection = Extract<ProjectionEntry, { type: "table-cell" }>;

export type LivePreviewIntentCoordinatorOptions = Readonly<{
  scheduleDocumentOperation: <T>(operation: () => T) => Promise<T>;
  currentContext: (intent: LivePreviewIntent) => LivePreviewIntentContext | null;
  hrefAllowed: (href: string) => boolean;
  openExternalAction: (
    intent: Extract<LivePreviewIntent, { type: "activate-link" }>,
    action: LivePreviewExternalAction,
  ) => Promise<void>;
  onDispatch?: (result: LivePreviewDispatchResult) => void;
  onError?: (error: unknown) => void;
  onMetricsChanged?: (metrics: LivePreviewIntentQueueMetrics) => void;
}>;

/** Product coordinator for the exact queue -> current context -> dispatcher -> external bridge boundary. */
export class LivePreviewIntentCoordinator {
  private readonly gestureNonces = new GestureNonceLedger();
  private readonly queue: BoundedLivePreviewIntentQueue;

  constructor(private readonly options: LivePreviewIntentCoordinatorOptions) {
    this.queue = new BoundedLivePreviewIntentQueue(
      async (intent) => {
        const dispatch = await this.options.scheduleDocumentOperation(() => {
          const context = this.options.currentContext(intent);
          if (context === null) return null;
          const result = dispatchLivePreviewIntent(
            context.view,
            intent,
            context.guard,
            context.currentEntry,
            this.gestureNonces,
            this.options.hrefAllowed,
            context.currentTableCells,
          );
          this.options.onDispatch?.(result);
          return result;
        });
        if (
          dispatch === null ||
          dispatch.externalAction === null ||
          intent.type !== "activate-link"
        )
          return;
        await this.options.openExternalAction(intent, dispatch.externalAction);
      },
      this.options.onError,
      this.options.onMetricsChanged,
    );
  }

  enqueue(intent: LivePreviewIntent): boolean {
    return this.queue.enqueue(intent);
  }

  clearPending(): number {
    return this.queue.clearPending();
  }

  destroy(): void {
    this.queue.destroy();
  }

  metrics(): LivePreviewIntentQueueMetrics {
    return this.queue.metrics();
  }
}

function blocked(reason: NonNullable<ReturnType<typeof interactionGuardRejection>>): IntentResult {
  switch (reason) {
    case "close-locked":
    case "readonly":
    case "composing":
    case "untrusted-event":
    case "duplicate-gesture":
      return { type: "consumed-no-change", reason };
    default:
      return { type: "rejected", reason };
  }
}

function noEffect(result: IntentResult): LivePreviewDispatchResult {
  return { result, externalAction: null, cm6Transactions: 0, externalActions: 0 };
}

function entryOwnsIntent(entry: ProjectionEntry | null, intent: LivePreviewIntent): boolean {
  if (intent.type === "place-caret") return entry === null;
  if (entry === null || entry.from !== intent.from || entry.to !== intent.to) return false;
  switch (intent.type) {
    case "toggle-task":
      return entry.type === "task";
    case "activate-link":
      return entry.type === "link";
    case "select-atomic":
      return entry.type === "atomic";
    case "move-table-cell":
    case "append-table-row":
      return entry.type === "table-cell";
    case "place-caret":
      return false;
  }
}

function validatedTableCellIndex(
  view: EditorView,
  currentEntry: ProjectionEntry | null,
  cells: readonly TableCellProjection[],
): number | null {
  if (
    currentEntry?.type !== "table-cell" ||
    cells.length === 0 ||
    cells.length > maxLivePreviewTableCells ||
    currentEntry.tableFrom < 0 ||
    currentEntry.tableFrom >= currentEntry.tableTo ||
    currentEntry.tableTo > view.state.doc.length ||
    currentEntry.tableTo - currentEntry.tableFrom > maxLivePreviewProjectionCodeUnits ||
    currentEntry.appendPrefixFrom < 0 ||
    currentEntry.appendPrefixFrom > currentEntry.appendPrefixTo ||
    currentEntry.appendPrefixTo > currentEntry.tableTo ||
    currentEntry.rowCount <= 0 ||
    currentEntry.columnCount <= 0 ||
    !Number.isSafeInteger(currentEntry.rowCount) ||
    !Number.isSafeInteger(currentEntry.columnCount) ||
    currentEntry.rowCount * currentEntry.columnCount !== cells.length ||
    view.state.selection.ranges.length !== 1
  ) {
    return null;
  }
  const head = view.state.selection.main.head;
  if (head < currentEntry.from || head > currentEntry.to) return null;

  for (let index = 0; index < cells.length; index += 1) {
    const cell = cells[index];
    if (
      cell === undefined ||
      cell.tableFrom !== currentEntry.tableFrom ||
      cell.tableTo !== currentEntry.tableTo ||
      cell.appendPrefixFrom !== currentEntry.appendPrefixFrom ||
      cell.appendPrefixTo !== currentEntry.appendPrefixTo ||
      cell.rowCount !== currentEntry.rowCount ||
      cell.columnCount !== currentEntry.columnCount ||
      cell.row !== Math.floor(index / currentEntry.columnCount) ||
      cell.column !== index % currentEntry.columnCount ||
      cell.from < cell.tableFrom ||
      cell.from > cell.to ||
      cell.to > cell.tableTo
    ) {
      return null;
    }
  }
  const index = currentEntry.row * currentEntry.columnCount + currentEntry.column;
  const indexed = cells[index];
  return indexed !== undefined && projectionEntriesEqual(indexed, currentEntry) ? index : null;
}

function appendEmptyTableRow(
  view: EditorView,
  current: TableCellProjection,
  targetColumn: number,
): LivePreviewDispatchResult {
  if (
    current.row !== current.rowCount - 1 ||
    targetColumn < 0 ||
    targetColumn >= current.columnCount ||
    (current.rowCount + 1) * current.columnCount > maxLivePreviewTableCells
  ) {
    return noEffect({ type: "rejected", reason: "invalid-intent" });
  }
  // Only the new row receives canonical spacing. Existing pipes, alignment markers, and whitespace are never
  // rewritten, so entering live preview and table navigation are byte-preserving until this explicit edit.
  const emptyCell = "   ";
  const prefixLength = current.appendPrefixTo - current.appendPrefixFrom;
  const rowLength = current.columnCount * (emptyCell.length + 1) + 1;
  const insertedLength = 1 + prefixLength + rowLength;
  if (
    !Number.isSafeInteger(insertedLength) ||
    current.tableTo - current.tableFrom + insertedLength > maxLivePreviewProjectionCodeUnits
  )
    return noEffect({ type: "rejected", reason: "invalid-intent" });
  const prefix = view.state.sliceDoc(current.appendPrefixFrom, current.appendPrefixTo);
  if (prefix.length !== prefixLength || /[\r\n]/.test(prefix))
    return noEffect({ type: "rejected", reason: "invalid-intent" });
  const inserted = `\n${prefix}|${Array.from({ length: current.columnCount }, () => emptyCell).join("|")}|`;
  const rowFrom = current.tableTo + 1 + prefixLength;
  const selection = rowFrom + 2 + targetColumn * (emptyCell.length + 1);
  view.dispatch({
    changes: { from: current.tableTo, insert: inserted },
    selection: EditorSelection.cursor(selection),
    annotations: Transaction.userEvent.of("input"),
  });
  return {
    result: { type: "committed" },
    externalAction: null,
    cm6Transactions: 1,
    externalActions: 0,
  };
}

/**
 * Revalidates one closed intent against the current CM6 state and commits either one CM6 transaction or one
 * external action. It never performs both, so save/close can serialize the returned action in their own queue.
 */
export function dispatchLivePreviewIntent(
  view: EditorView,
  intent: LivePreviewIntent,
  guard: EditorInteractionGuard,
  currentEntry: ProjectionEntry | null,
  gestureNonces: GestureNonceLedger,
  hrefAllowed: (href: string) => boolean,
  currentTableCells: readonly TableCellProjection[],
): LivePreviewDispatchResult {
  const rejection = interactionGuardRejection(
    intent,
    guard,
    view.state.doc.length,
    intent.type !== "activate-link" || gestureNonces.isFresh(intent.gestureNonce),
  );
  if (rejection !== null) return noEffect(blocked(rejection));
  if (!entryOwnsIntent(currentEntry, intent))
    return noEffect({ type: "rejected", reason: "stale-range" });

  switch (intent.type) {
    case "place-caret":
      view.dispatch({ selection: EditorSelection.cursor(intent.from) });
      return {
        result: { type: "committed" },
        externalAction: null,
        cm6Transactions: 1,
        externalActions: 0,
      };
    case "toggle-task": {
      const marker = view.state.sliceDoc(intent.from, intent.to);
      if (!/^\[[ xX]\]$/.test(marker)) return noEffect({ type: "rejected", reason: "stale-range" });
      view.dispatch({
        changes: {
          from: intent.from + 1,
          to: intent.from + 2,
          insert: marker[1]?.toLowerCase() === "x" ? " " : "x",
        },
        annotations: Transaction.userEvent.of("input"),
      });
      return {
        result: { type: "committed" },
        externalAction: null,
        cm6Transactions: 1,
        externalActions: 0,
      };
    }
    case "activate-link": {
      if (currentEntry?.type !== "link")
        return noEffect({ type: "rejected", reason: "stale-range" });
      if (!gestureNonces.consume(intent.gestureNonce))
        return noEffect({ type: "consumed-no-change", reason: "duplicate-gesture" });
      const destinationLength = currentEntry.destinationTo - currentEntry.destinationFrom;
      if (
        !Number.isSafeInteger(destinationLength) ||
        destinationLength <= 0 ||
        destinationLength > 4_096 ||
        currentEntry.destinationFrom < currentEntry.from ||
        currentEntry.destinationTo > currentEntry.to ||
        currentEntry.destinationTo > view.state.doc.length
      ) {
        return noEffect({ type: "rejected", reason: "invalid-intent" });
      }
      const href = view.state.sliceDoc(currentEntry.destinationFrom, currentEntry.destinationTo);
      if (href.length === 0 || href.length > 4_096 || !hrefAllowed(href))
        return noEffect({ type: "rejected", reason: "invalid-intent" });
      if (intent.disposition === "primary-pointer")
        return noEffect({ type: "consumed-no-change", reason: "invalid-intent" });
      return {
        result: { type: "committed" },
        externalAction: {
          type: "open-link",
          href,
          forceSystem: intent.disposition === "command-shift-pointer",
        },
        cm6Transactions: 0,
        externalActions: 1,
      };
    }
    case "select-atomic":
      view.dispatch({ selection: EditorSelection.range(intent.from, intent.to) });
      return {
        result: { type: "committed" },
        externalAction: null,
        cm6Transactions: 1,
        externalActions: 0,
      };
    case "move-table-cell": {
      const index = validatedTableCellIndex(view, currentEntry, currentTableCells);
      if (index === null || currentEntry?.type !== "table-cell")
        return noEffect({ type: "rejected", reason: "invalid-intent" });
      let targetIndex: number;
      switch (intent.direction) {
        case "forward":
          if (index === currentTableCells.length - 1)
            return appendEmptyTableRow(view, currentEntry, 0);
          targetIndex = index + 1;
          break;
        case "backward":
          if (index === 0)
            return noEffect({ type: "consumed-no-change", reason: "invalid-intent" });
          targetIndex = index - 1;
          break;
        case "down":
          targetIndex = index + currentEntry.columnCount;
          if (targetIndex >= currentTableCells.length)
            return noEffect({ type: "rejected", reason: "invalid-intent" });
          break;
      }
      const target = currentTableCells[targetIndex];
      if (target === undefined) return noEffect({ type: "rejected", reason: "invalid-intent" });
      view.dispatch({ selection: EditorSelection.cursor(target.from) });
      return {
        result: { type: "committed" },
        externalAction: null,
        cm6Transactions: 1,
        externalActions: 0,
      };
    }
    case "append-table-row": {
      const index = validatedTableCellIndex(view, currentEntry, currentTableCells);
      if (index === null || currentEntry?.type !== "table-cell")
        return noEffect({ type: "rejected", reason: "invalid-intent" });
      return appendEmptyTableRow(view, currentEntry, currentEntry.column);
    }
  }
}
