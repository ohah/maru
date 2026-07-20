import { EditorSelection, Transaction } from "@codemirror/state";
import type { EditorView } from "@codemirror/view";
import {
  interactionGuardRejection,
  type EditorInteractionGuard,
  type IntentResult,
  type LivePreviewIntent,
} from "./live-preview-intent";
import type { ProjectionEntry } from "./live-preview-projection";

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
}>;

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
    case "move-table-cell":
    case "append-table-row":
      return noEffect({ type: "rejected", reason: "invalid-intent" });
  }
}
