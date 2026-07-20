import {
  Annotation,
  StateEffect,
  StateField,
  type ChangeDesc,
  type Extension,
  type Range,
} from "@codemirror/state";
import { Decoration, EditorView, type DecorationSet, type ViewUpdate } from "@codemirror/view";
import { buildEditableProjection, editableProjectionWindow } from "./editable-projection";
import {
  LivePreviewDiagnosticsStore,
  type LivePreviewDiagnostics,
} from "./live-preview-diagnostics";
import { compareProjectionEntries, type ProjectionEntry } from "./live-preview-projection";
import type { EditorRevisionClock } from "./live-preview-state";

type DecorationPatch = Readonly<{
  remove: ReadonlySet<Decoration>;
  add: readonly Range<Decoration>[];
}>;

const patchEditableProjectionDecorations = StateEffect.define<DecorationPatch>();
export const editableProjectionTransaction = Annotation.define<boolean>();

const editableProjectionDecorationField = StateField.define<DecorationSet>({
  create: () => Decoration.none,
  update(value, transaction) {
    if (transaction.docChanged) value = value.map(transaction.changes);
    for (const effect of transaction.effects) {
      if (!effect.is(patchEditableProjectionDecorations)) continue;
      value = value.update({
        filter: (_from, _to, decoration) => !effect.value.remove.has(decoration),
        add: effect.value.add,
        sort: true,
      });
    }
    return value;
  },
  provide: (field) => EditorView.decorations.from(field),
});

export const editableProjectionExtension: Extension = editableProjectionDecorationField;

export type EditableProjectionControllerMetrics = Readonly<{
  visitedCodeUnits: number;
  visitedSyntaxNodes: number;
  selectionRangeChecks: number;
  emittedDecorations: number;
  diffedDecorations: number;
  projectionTransactions: number;
}>;

export type EditableProjectionControllerState = "running" | "disabled";

type ProjectionCommit = Readonly<{
  state: EditableProjectionControllerState;
  metrics: EditableProjectionControllerMetrics;
}>;

function styleClass(entry: Extract<ProjectionEntry, { type: "style" }>): string {
  switch (entry.role) {
    case "heading-1":
    case "heading-2":
    case "heading-3":
    case "heading-4":
    case "heading-5":
    case "heading-6":
      return `maru-projection-${entry.role}`;
    case "emphasis":
      return "maru-projection-emphasis";
    case "strong":
      return "maru-projection-strong";
    case "strike":
      return "maru-projection-strike";
    case "inline-code":
      return "maru-projection-inline-code";
    case "quote":
      return "maru-projection-quote";
    case "list":
      return "maru-projection-list";
    case "thematic-break":
      return "maru-projection-thematic-break";
  }
}

function decorationForEntry(entry: ProjectionEntry): Decoration | null {
  switch (entry.type) {
    case "style":
      return Decoration.mark({ class: styleClass(entry) });
    case "hidden-syntax":
      return Decoration.replace({});
    case "task":
      return Decoration.mark({
        class: entry.checked ? "maru-projection-task-checked" : "maru-projection-task",
      });
    case "link":
      return Decoration.mark({ class: "maru-projection-link" });
    case "table-cell":
      return Decoration.mark({ class: "maru-projection-table-cell" });
    case "atomic":
      // FP11b admits the exact CM6 range but keeps source visible until FP11e supplies an isolated renderer.
      return null;
  }
}

function decorationBounds(entry: ProjectionEntry): Readonly<{ from: number; to: number }> {
  return entry.type === "link"
    ? { from: entry.labelFrom, to: entry.labelTo }
    : { from: entry.from, to: entry.to };
}

export type EditableProjectionDecorationRecord = Readonly<{
  entry: ProjectionEntry;
  decoration: Decoration | null;
}>;

export type EditableProjectionReconciliation = Readonly<{
  records: readonly EditableProjectionDecorationRecord[];
  remove: ReadonlySet<Decoration>;
  add: readonly Range<Decoration>[];
  comparisons: number;
  createdDecorations: number;
}>;

/** Canonical O(N+M) merge; equal entries retain the exact Decoration identity. */
export function reconcileEditableProjectionDecorations(
  previous: readonly EditableProjectionDecorationRecord[],
  next: readonly ProjectionEntry[],
): EditableProjectionReconciliation {
  const records: EditableProjectionDecorationRecord[] = [];
  const remove = new Set<Decoration>();
  const add: Range<Decoration>[] = [];
  let previousIndex = 0;
  let nextIndex = 0;
  let comparisons = 0;
  let createdDecorations = 0;

  const create = (entry: ProjectionEntry) => {
    const bounds = decorationBounds(entry);
    const decoration = bounds.from < bounds.to ? decorationForEntry(entry) : null;
    records.push({ entry, decoration });
    if (decoration !== null) {
      add.push(decoration.range(bounds.from, bounds.to));
      createdDecorations += 1;
    }
  };

  while (previousIndex < previous.length && nextIndex < next.length) {
    const oldRecord = previous[previousIndex];
    const newEntry = next[nextIndex];
    if (oldRecord === undefined || newEntry === undefined) break;
    comparisons += 1;
    const order = compareProjectionEntries(oldRecord.entry, newEntry);
    if (order === 0) {
      records.push(oldRecord);
      previousIndex += 1;
      nextIndex += 1;
    } else if (order < 0) {
      if (oldRecord.decoration !== null) remove.add(oldRecord.decoration);
      previousIndex += 1;
    } else {
      create(newEntry);
      nextIndex += 1;
    }
  }
  for (; previousIndex < previous.length; previousIndex += 1) {
    const oldRecord = previous[previousIndex];
    if (oldRecord?.decoration !== null && oldRecord?.decoration !== undefined)
      remove.add(oldRecord.decoration);
  }
  for (; nextIndex < next.length; nextIndex += 1) {
    const newEntry = next[nextIndex];
    if (newEntry !== undefined) create(newEntry);
  }
  return { records, remove, add, comparisons, createdDecorations };
}

function mapProjectionEntry(entry: ProjectionEntry, changes: ChangeDesc): ProjectionEntry {
  const from = changes.mapPos(entry.from, 1);
  const to = changes.mapPos(entry.to, -1);
  if (entry.type === "link") {
    const mapped: ProjectionEntry = {
      ...entry,
      from,
      to,
      labelFrom: changes.mapPos(entry.labelFrom, 1),
      labelTo: changes.mapPos(entry.labelTo, -1),
      destinationFrom: changes.mapPos(entry.destinationFrom, 1),
      destinationTo: changes.mapPos(entry.destinationTo, -1),
    };
    return compareProjectionEntries(entry, mapped) === 0 ? entry : mapped;
  }
  if (from === entry.from && to === entry.to) return entry;
  return { ...entry, from, to };
}

function mapDecorationRecords(
  records: readonly EditableProjectionDecorationRecord[],
  changes: ChangeDesc,
): readonly EditableProjectionDecorationRecord[] {
  let changed = false;
  const mapped = records.map((record) => {
    const entry = mapProjectionEntry(record.entry, changes);
    if (entry === record.entry) return record;
    changed = true;
    return { entry, decoration: record.decoration };
  });
  return changed ? mapped : records;
}

/** Owns projection scheduling and the single CM6 decoration commit. */
export class EditableProjectionController {
  private readonly diagnostics: LivePreviewDiagnosticsStore;
  private enabled = false;
  private destroyed = false;
  private deferredComposition = false;
  private records: readonly EditableProjectionDecorationRecord[] = [];
  private visitedCodeUnits = 0;
  private visitedSyntaxNodes = 0;
  private selectionRangeChecks = 0;
  private emittedDecorations = 0;
  private diffedDecorations = 0;
  private projectionTransactions = 0;

  private readonly compositionEnded = () => {
    if (!this.enabled || this.destroyed || !this.deferredComposition) return;
    this.deferredComposition = false;
    this.project();
  };

  constructor(
    private readonly view: EditorView,
    editorEpoch: number,
    private readonly revisions: EditorRevisionClock,
    private readonly onCommit: (commit: ProjectionCommit) => void = () => {},
  ) {
    this.diagnostics = new LivePreviewDiagnosticsStore(editorEpoch);
    this.view.contentDOM.addEventListener("compositionend", this.compositionEnded);
  }

  enable(): void {
    if (this.destroyed) return;
    if (this.enabled) return;
    this.enabled = true;
    this.project();
  }

  disable(): void {
    if (!this.enabled || this.destroyed) return;
    this.enabled = false;
    this.deferredComposition = false;
    const projection = this.revisions.nextProjection();
    const remove = new Set<Decoration>();
    for (const record of this.records) {
      if (record.decoration !== null) remove.add(record.decoration);
    }
    if (remove.size > 0) {
      this.view.dispatch({
        effects: patchEditableProjectionDecorations.of({ remove, add: [] }),
        annotations: editableProjectionTransaction.of(true),
      });
      this.projectionTransactions += 1;
    }
    this.records = [];
    this.diagnostics.commit({
      documentRevision: projection.documentRevision,
      projectionGeneration: projection.projectionGeneration,
      decorationCount: 0,
      desiredWidgets: 0,
      mountedWidgets: 0,
      activeSourceRangeCount: 0,
      activeSourceRanges: [],
    });
    this.publish("disabled");
  }

  destroy(): void {
    if (this.destroyed) return;
    this.disable();
    this.destroyed = true;
    this.view.contentDOM.removeEventListener("compositionend", this.compositionEnded);
  }

  handleUpdate(update: ViewUpdate): void {
    if (
      this.destroyed ||
      update.transactions.some(
        (transaction) => transaction.annotation(editableProjectionTransaction) === true,
      )
    ) {
      return;
    }
    if (!this.enabled) return;
    if (update.docChanged) this.records = mapDecorationRecords(this.records, update.changes);
    if (
      update.view.composing ||
      update.transactions.some((transaction) => transaction.isUserEvent("input.type.compose"))
    ) {
      this.deferredComposition = true;
      return;
    }
    this.deferredComposition = false;
    this.project();
  }

  metrics(): EditableProjectionControllerMetrics {
    return {
      visitedCodeUnits: this.visitedCodeUnits,
      visitedSyntaxNodes: this.visitedSyntaxNodes,
      selectionRangeChecks: this.selectionRangeChecks,
      emittedDecorations: this.emittedDecorations,
      diffedDecorations: this.diffedDecorations,
      projectionTransactions: this.projectionTransactions,
    };
  }

  writeDiagnostics(target: LivePreviewDiagnostics): void {
    this.diagnostics.writeSnapshot(target);
  }

  private project(): void {
    if (!this.enabled || this.destroyed) return;
    if (this.view.composing) {
      this.deferredComposition = true;
      return;
    }
    const identity = this.revisions.nextProjection();
    const projection = buildEditableProjection(
      this.view.state,
      editableProjectionWindow(this.view),
    );
    this.visitedCodeUnits += projection.metrics.visitedCodeUnits;
    this.visitedSyntaxNodes += projection.metrics.visitedSyntaxNodes;
    this.selectionRangeChecks += projection.metrics.selectionRangeChecks;

    const reconciliation = reconcileEditableProjectionDecorations(this.records, projection.entries);
    this.diffedDecorations += reconciliation.comparisons;
    this.emittedDecorations += reconciliation.createdDecorations;
    if (reconciliation.remove.size > 0 || reconciliation.add.length > 0) {
      this.view.dispatch({
        effects: patchEditableProjectionDecorations.of({
          remove: reconciliation.remove,
          add: reconciliation.add,
        }),
        annotations: editableProjectionTransaction.of(true),
      });
      this.projectionTransactions += 1;
    }
    this.records = reconciliation.records;

    const decorationCount = reconciliation.records.reduce(
      (count, record) => count + Number(record.decoration !== null),
      0,
    );
    this.diagnostics.commit({
      documentRevision: identity.documentRevision,
      projectionGeneration: identity.projectionGeneration,
      decorationCount,
      desiredWidgets: 0,
      mountedWidgets: 0,
      activeSourceRangeCount: projection.activeSourceRangeCount,
      activeSourceRanges: projection.activeSourceRanges,
      fallbackCounts: projection.fallbackCounts,
    });
    this.publish("running");
  }

  private publish(state: EditableProjectionControllerState): void {
    this.onCommit({ state, metrics: this.metrics() });
  }
}
