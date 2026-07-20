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
  type DiagnosticsCommit,
  type LivePreviewDiagnostics,
} from "./live-preview-diagnostics";
import {
  compareProjectionEntries,
  maxLivePreviewTableCells,
  type ProjectionEntry,
} from "./live-preview-projection";
import type { EditorRevisionClock } from "./live-preview-state";
import type { AtomicWidgetMetrics } from "./live-preview-diagnostics";
import type { LivePreviewIntent } from "./live-preview-intent";
import { atomicProjectionTransaction } from "./live-preview-editor";
import { maxAtomicProjectionRequests } from "./atomic-projection";

type AtomicEntry = Extract<ProjectionEntry, { type: "atomic" }>;

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
  interactionRangeChecks: number;
  projectionRecordCount: number;
  tableCellRecordCount: number;
  tableGroupBuildRecordChecks: number;
  tableGroupCellArraysCreated: number;
}>;

export type EditableProjectionControllerState = "running" | "disabled";

export type EditableProjectionInteractionContext = Readonly<{
  currentEntry: ProjectionEntry | null;
  currentTableCells: readonly Extract<ProjectionEntry, { type: "table-cell" }>[];
}>;

type TableCellEntry = Extract<ProjectionEntry, { type: "table-cell" }>;

type TableInteractionGroup = Readonly<{
  tableFrom: number;
  tableTo: number;
  cells: readonly TableCellEntry[];
}>;

export type ProjectionCommit = Readonly<{
  state: EditableProjectionControllerState;
  metrics: EditableProjectionControllerMetrics;
  atomicEntries: readonly Extract<ProjectionEntry, { type: "atomic" }>[];
}>;

type IntentSink = (intent: LivePreviewIntent) => void;

export type LivePreviewTableKeyIntent =
  | Readonly<{ type: "move-table-cell"; direction: "forward" | "backward" | "down" }>
  | Readonly<{ type: "append-table-row" }>;

export type LivePreviewTableKeyCapture =
  | Readonly<{ owned: false; intent: null }>
  | Readonly<{ owned: true; intent: LivePreviewIntent | null }>;

export function livePreviewTableKeyIntent(
  entry: Extract<ProjectionEntry, { type: "table-cell" }>,
  event: Readonly<{
    key: string;
    metaKey: boolean;
    ctrlKey: boolean;
    altKey: boolean;
    shiftKey: boolean;
  }>,
): LivePreviewTableKeyIntent | null {
  if (
    (event.key !== "Tab" && event.key !== "Enter") ||
    event.metaKey ||
    event.ctrlKey ||
    event.altKey ||
    (event.key === "Enter" && event.shiftKey)
  ) {
    return null;
  }
  if (event.key === "Tab")
    return { type: "move-table-cell", direction: event.shiftKey ? "backward" : "forward" };
  return entry.row === entry.rowCount - 1
    ? { type: "append-table-row" }
    : { type: "move-table-cell", direction: "down" };
}

export function livePreviewGestureCaptureAllowed(
  trusted: boolean,
  composing: boolean,
  repeat = false,
): boolean {
  return trusted && !composing && !repeat;
}

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
  tableEntriesChanged: boolean;
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
  let tableEntriesChanged = false;

  const create = (entry: ProjectionEntry) => {
    if (entry.type === "table-cell") tableEntriesChanged = true;
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
      if (oldRecord.entry.type === "table-cell") tableEntriesChanged = true;
      if (oldRecord.decoration !== null) remove.add(oldRecord.decoration);
      previousIndex += 1;
    } else {
      create(newEntry);
      nextIndex += 1;
    }
  }
  for (; previousIndex < previous.length; previousIndex += 1) {
    const oldRecord = previous[previousIndex];
    if (oldRecord?.entry.type === "table-cell") tableEntriesChanged = true;
    if (oldRecord?.decoration !== null && oldRecord?.decoration !== undefined)
      remove.add(oldRecord.decoration);
  }
  for (; nextIndex < next.length; nextIndex += 1) {
    const newEntry = next[nextIndex];
    if (newEntry !== undefined) create(newEntry);
  }
  return { records, remove, add, comparisons, createdDecorations, tableEntriesChanged };
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
  if (entry.type === "table-cell") {
    const mapped: ProjectionEntry = {
      ...entry,
      from,
      to,
      tableFrom: changes.mapPos(entry.tableFrom, 1),
      tableTo: changes.mapPos(entry.tableTo, -1),
      appendPrefixFrom: changes.mapPos(entry.appendPrefixFrom, 1),
      appendPrefixTo: changes.mapPos(entry.appendPrefixTo, -1),
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

type TableInteractionGroupBuild = Readonly<{
  groups: readonly TableInteractionGroup[];
  recordChecks: number;
  cellArraysCreated: number;
  cellCount: number;
}>;

function buildTableInteractionGroups(
  records: readonly EditableProjectionDecorationRecord[],
): TableInteractionGroupBuild {
  const groups: Array<{ tableFrom: number; tableTo: number; cells: TableCellEntry[] }> = [];
  let recordChecks = 0;
  let cellArraysCreated = 0;
  let cellCount = 0;
  for (const { entry } of records) {
    recordChecks += 1;
    if (entry.type !== "table-cell") continue;
    const previous = groups.at(-1);
    if (previous?.tableFrom === entry.tableFrom && previous.tableTo === entry.tableTo) {
      if (previous.cells.length >= maxLivePreviewTableCells)
        return { groups: [], recordChecks, cellArraysCreated, cellCount: 0 };
      previous.cells.push(entry);
      cellCount += 1;
      continue;
    }
    groups.push({ tableFrom: entry.tableFrom, tableTo: entry.tableTo, cells: [entry] });
    cellArraysCreated += 1;
    cellCount += 1;
  }
  return { groups, recordChecks, cellArraysCreated, cellCount };
}

/** Owns projection scheduling and the single CM6 decoration commit. */
export class EditableProjectionController {
  private readonly diagnostics: LivePreviewDiagnosticsStore;
  private enabled = false;
  private destroyed = false;
  private deferredComposition = false;
  private records: readonly EditableProjectionDecorationRecord[] = [];
  private tableGroups: readonly TableInteractionGroup[] = [];
  private visitedCodeUnits = 0;
  private visitedSyntaxNodes = 0;
  private selectionRangeChecks = 0;
  private emittedDecorations = 0;
  private diffedDecorations = 0;
  private projectionTransactions = 0;
  private interactionRangeChecks = 0;
  private tableCellRecordCount = 0;
  private tableGroupBuildRecordChecks = 0;
  private tableGroupCellArraysCreated = 0;
  private documentRevision = 0;
  private projectionGeneration = 0;
  private nextGestureNonce = 1;
  private lastDiagnosticsCommit: DiagnosticsCommit | null = null;
  private atomicDesiredWidgets = 0;
  private atomicMountedWidgets = 0;
  private atomicRichSourceLimit = 0;
  private atomicRendererUnavailable = 0;
  private atomicStaleCapability = 0;

  private identityForIntent() {
    return {
      editorEpoch: this.editorEpoch,
      documentRevision: this.documentRevision,
      projectionGeneration: this.projectionGeneration,
    } as const;
  }

  private nextTrustedGestureNonce(): number | null {
    const nonce = this.nextGestureNonce;
    if (!Number.isSafeInteger(nonce) || nonce <= 0) return null;
    this.nextGestureNonce += 1;
    return nonce;
  }

  private findInteractionEntry(owns: (entry: ProjectionEntry) => boolean): ProjectionEntry | null {
    for (const { entry } of this.records) {
      this.interactionRangeChecks += 1;
      if (owns(entry)) return entry;
    }
    return null;
  }

  private entryAtDomTarget(target: EventTarget | null): ProjectionEntry | null {
    const elementConstructor = this.view.dom.ownerDocument.defaultView?.Element;
    if (elementConstructor === undefined || !(target instanceof elementConstructor)) return null;
    const element = target as Element;
    if (!this.view.dom.contains(element)) return null;
    const task = element.closest(".maru-projection-task, .maru-projection-task-checked");
    const link = element.closest(".maru-projection-link");
    const owner = task ?? link;
    if (owner === null) return null;
    const position = this.view.posAtDOM(owner, 0);
    return this.findInteractionEntry((entry) => {
      if (task !== null)
        return entry.type === "task" && entry.from <= position && position < entry.to;
      return entry.type === "link" && entry.labelFrom <= position && position < entry.labelTo;
    });
  }

  private entryAtSelection(): ProjectionEntry | null {
    if (this.view.state.selection.ranges.length !== 1) return null;
    const position = this.view.state.selection.main.head;
    return this.findInteractionEntry((entry) => {
      if (entry.type === "task") return entry.from <= position && position < entry.to;
      if (entry.type === "link") return entry.labelFrom <= position && position < entry.labelTo;
      return false;
    });
  }

  private tableGroupAt(position: number): TableInteractionGroup | null {
    let low = 0;
    let high = this.tableGroups.length;
    while (low < high) {
      const middle = low + Math.floor((high - low) / 2);
      const group = this.tableGroups[middle];
      this.interactionRangeChecks += 1;
      if (group !== undefined && group.tableFrom <= position) low = middle + 1;
      else high = middle;
    }
    const group = this.tableGroups[low - 1];
    return group !== undefined && position <= group.tableTo ? group : null;
  }

  private tableCellAt(group: TableInteractionGroup, position: number): TableCellEntry | null {
    let low = 0;
    let high = group.cells.length;
    while (low < high) {
      const middle = low + Math.floor((high - low) / 2);
      const cell = group.cells[middle];
      this.interactionRangeChecks += 1;
      if (cell !== undefined && cell.from <= position) low = middle + 1;
      else high = middle;
    }
    const cell = group.cells[low - 1];
    return cell !== undefined && position <= cell.to ? cell : null;
  }

  private tableEntryAtSelection(): TableCellEntry | null {
    if (this.view.state.selection.ranges.length !== 1) return null;
    const position = this.view.state.selection.main.head;
    const group = this.tableGroupAt(position);
    return group === null ? null : this.tableCellAt(group, position);
  }

  private readonly pointerPressed = (event: MouseEvent) => {
    if (!this.enabled || this.destroyed || event.button !== 0) return;
    const entry = this.entryAtDomTarget(event.target);
    if (entry === null) return;
    const ownsTask =
      entry.type === "task" && !event.metaKey && !event.ctrlKey && !event.altKey && !event.shiftKey;
    const ownsLink = entry.type === "link" && event.metaKey && !event.ctrlKey && !event.altKey;
    if (!ownsTask && !ownsLink) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    if (
      !livePreviewGestureCaptureAllowed(
        event.isTrusted,
        this.view.composing || this.deferredComposition,
      )
    )
      return;
    if (ownsTask && entry.type === "task") {
      // This exact projected gesture belongs to the closed intent dispatcher. Stopping it here also keeps a
      // synthetic event from falling through to CM6's generic pointer selection before the trust gate rejects it.
      this.onIntent({
        type: "toggle-task",
        ...this.identityForIntent(),
        from: entry.from,
        to: entry.to,
        trusted: event.isTrusted,
        input: "pointer",
        gestureNonce: null,
      });
      return;
    }
    if (entry.type !== "link") return;
    const nonce = this.nextTrustedGestureNonce();
    if (nonce === null) return;
    this.onIntent({
      type: "activate-link",
      ...this.identityForIntent(),
      from: entry.from,
      to: entry.to,
      trusted: event.isTrusted,
      disposition: event.shiftKey ? "command-shift-pointer" : "command-pointer",
      gestureNonce: nonce,
    });
  };

  private readonly keyPressed = (event: KeyboardEvent) => {
    if (this.enabled && !this.destroyed && (event.key === "Tab" || event.key === "Enter")) {
      const capture = this.tableKeyCapture({
        key: event.key,
        metaKey: event.metaKey,
        ctrlKey: event.ctrlKey,
        altKey: event.altKey,
        shiftKey: event.shiftKey,
        trusted: event.isTrusted,
        composing: event.isComposing || this.view.composing || this.deferredComposition,
        repeat: event.repeat,
      });
      if (capture.owned) {
        event.preventDefault();
        event.stopImmediatePropagation();
        if (capture.intent !== null) this.onIntent(capture.intent);
        return;
      }
    }
    if (
      !this.enabled ||
      this.destroyed ||
      event.key !== "Enter" ||
      !event.metaKey ||
      event.ctrlKey ||
      event.altKey ||
      event.shiftKey
    ) {
      return;
    }
    const entry = this.entryAtSelection();
    if (entry === null) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    if (
      !livePreviewGestureCaptureAllowed(
        event.isTrusted,
        event.isComposing || this.view.composing || this.deferredComposition,
        event.repeat,
      )
    ) {
      return;
    }
    if (entry.type === "task") {
      this.onIntent({
        type: "toggle-task",
        ...this.identityForIntent(),
        from: entry.from,
        to: entry.to,
        trusted: event.isTrusted,
        input: "keyboard",
        gestureNonce: null,
      });
      return;
    }
    if (entry.type !== "link") return;
    const nonce = this.nextTrustedGestureNonce();
    if (nonce === null) return;
    this.onIntent({
      type: "activate-link",
      ...this.identityForIntent(),
      from: entry.from,
      to: entry.to,
      trusted: event.isTrusted,
      disposition: "keyboard",
      gestureNonce: nonce,
    });
  };

  private readonly compositionEnded = () => {
    if (!this.enabled || this.destroyed || !this.deferredComposition) return;
    this.deferredComposition = false;
    this.project();
  };

  constructor(
    private readonly view: EditorView,
    private readonly editorEpoch: number,
    private readonly revisions: EditorRevisionClock,
    private readonly onCommit: (commit: ProjectionCommit) => void = () => {},
    private readonly onIntent: IntentSink = () => {},
  ) {
    this.diagnostics = new LivePreviewDiagnosticsStore(editorEpoch);
    this.view.contentDOM.addEventListener("compositionend", this.compositionEnded);
    this.view.dom.addEventListener("mousedown", this.pointerPressed, true);
    this.view.dom.addEventListener("keydown", this.keyPressed, true);
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
    this.documentRevision = projection.documentRevision;
    this.projectionGeneration = projection.projectionGeneration;
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
    this.tableGroups = [];
    this.tableCellRecordCount = 0;
    this.atomicDesiredWidgets = 0;
    this.atomicMountedWidgets = 0;
    this.atomicRichSourceLimit = 0;
    this.atomicRendererUnavailable = 0;
    this.atomicStaleCapability = 0;
    this.lastDiagnosticsCommit = {
      documentRevision: projection.documentRevision,
      projectionGeneration: projection.projectionGeneration,
      decorationCount: 0,
      desiredWidgets: 0,
      mountedWidgets: 0,
      activeSourceRangeCount: 0,
      activeSourceRanges: [],
    };
    this.commitDiagnostics();
    this.publish("disabled");
  }

  destroy(): void {
    if (this.destroyed) return;
    this.disable();
    this.destroyed = true;
    this.view.contentDOM.removeEventListener("compositionend", this.compositionEnded);
    this.view.dom.removeEventListener("mousedown", this.pointerPressed, true);
    this.view.dom.removeEventListener("keydown", this.keyPressed, true);
  }

  handleUpdate(update: ViewUpdate): void {
    if (
      this.destroyed ||
      update.transactions.some(
        (transaction) =>
          transaction.annotation(editableProjectionTransaction) === true ||
          transaction.annotation(atomicProjectionTransaction) === true,
      )
    ) {
      return;
    }
    if (!this.enabled) return;
    if (update.docChanged) this.records = mapDecorationRecords(this.records, update.changes);
    const compositionDeferred =
      update.view.composing ||
      update.transactions.some((transaction) => transaction.isUserEvent("input.type.compose"));
    if (compositionDeferred) {
      // Projection commit is deferred for the full IME lifetime, but the mapped index still has to own Tab/Enter
      // so those keys cannot fall through to generic CM6 input while composition is active.
      if (update.docChanged) this.rebuildTableInteractionGroups();
      this.deferredComposition = true;
      return;
    }
    this.deferredComposition = false;
    this.project(update.docChanged);
  }

  metrics(): EditableProjectionControllerMetrics {
    return {
      visitedCodeUnits: this.visitedCodeUnits,
      visitedSyntaxNodes: this.visitedSyntaxNodes,
      selectionRangeChecks: this.selectionRangeChecks,
      emittedDecorations: this.emittedDecorations,
      diffedDecorations: this.diffedDecorations,
      projectionTransactions: this.projectionTransactions,
      interactionRangeChecks: this.interactionRangeChecks,
      projectionRecordCount: this.records.length,
      tableCellRecordCount: this.tableCellRecordCount,
      tableGroupBuildRecordChecks: this.tableGroupBuildRecordChecks,
      tableGroupCellArraysCreated: this.tableGroupCellArraysCreated,
    };
  }

  writeDiagnostics(target: LivePreviewDiagnostics): void {
    this.diagnostics.writeSnapshot(target);
  }

  updateAtomicDiagnostics(metrics: AtomicWidgetMetrics): void {
    if (
      metrics.editorEpoch !== this.editorEpoch ||
      metrics.documentRevision !== this.documentRevision ||
      metrics.projectionGeneration !== this.projectionGeneration
    )
      return;
    this.atomicDesiredWidgets = metrics.desired;
    this.atomicMountedWidgets = metrics.mounted;
    this.atomicRichSourceLimit = metrics.richSourceLimit;
    this.atomicRendererUnavailable = metrics.rendererUnavailable;
    this.atomicStaleCapability = metrics.staleCapability;
    this.commitDiagnostics();
  }

  interactionIdentity(): Readonly<{
    editorEpoch: number;
    documentRevision: number;
    projectionGeneration: number;
  }> {
    return {
      editorEpoch: this.editorEpoch,
      documentRevision: this.documentRevision,
      projectionGeneration: this.projectionGeneration,
    };
  }

  tableKeyCapture(
    event: Readonly<{
      key: string;
      metaKey: boolean;
      ctrlKey: boolean;
      altKey: boolean;
      shiftKey: boolean;
      trusted: boolean;
      composing: boolean;
      repeat: boolean;
    }>,
  ): LivePreviewTableKeyCapture {
    if (!this.enabled || this.destroyed) return { owned: false, intent: null };
    const tableCell = this.tableEntryAtSelection();
    if (tableCell === null) return { owned: false, intent: null };
    const descriptor = livePreviewTableKeyIntent(tableCell, event);
    if (descriptor === null) return { owned: false, intent: null };
    if (!livePreviewGestureCaptureAllowed(event.trusted, event.composing, event.repeat))
      return { owned: true, intent: null };
    const common = {
      ...this.identityForIntent(),
      from: tableCell.from,
      to: tableCell.to,
      trusted: event.trusted,
      input: "keyboard" as const,
      gestureNonce: null,
    };
    return {
      owned: true,
      intent:
        descriptor.type === "append-table-row"
          ? { type: descriptor.type, ...common }
          : { type: descriptor.type, direction: descriptor.direction, ...common },
    };
  }

  entryForIntent(intent: LivePreviewIntent): ProjectionEntry | null {
    return this.findInteractionEntry(
      (entry) =>
        entry.from === intent.from &&
        entry.to === intent.to &&
        ((intent.type === "toggle-task" && entry.type === "task") ||
          (intent.type === "activate-link" && entry.type === "link") ||
          (intent.type === "select-atomic" && entry.type === "atomic") ||
          ((intent.type === "move-table-cell" || intent.type === "append-table-row") &&
            entry.type === "table-cell")),
    );
  }

  interactionContextForIntent(intent: LivePreviewIntent): EditableProjectionInteractionContext {
    if (intent.type !== "move-table-cell" && intent.type !== "append-table-row") {
      return { currentEntry: this.entryForIntent(intent), currentTableCells: [] };
    }
    const group = this.tableGroupAt(intent.from);
    if (group === null) return { currentEntry: null, currentTableCells: [] };
    const currentEntry = this.tableCellAt(group, intent.from);
    if (
      currentEntry === null ||
      currentEntry.from !== intent.from ||
      currentEntry.to !== intent.to
    ) {
      return { currentEntry: null, currentTableCells: [] };
    }
    return { currentEntry, currentTableCells: group.cells };
  }

  private rebuildTableInteractionGroups(): void {
    const build = buildTableInteractionGroups(this.records);
    this.tableGroups = build.groups;
    this.tableCellRecordCount = build.cellCount;
    this.tableGroupBuildRecordChecks += build.recordChecks;
    this.tableGroupCellArraysCreated += build.cellArraysCreated;
  }

  private project(forceTableGroupRebuild = false): void {
    if (!this.enabled || this.destroyed) return;
    if (this.view.composing) {
      this.deferredComposition = true;
      return;
    }
    const identity = this.revisions.nextProjection();
    this.documentRevision = identity.documentRevision;
    this.projectionGeneration = identity.projectionGeneration;
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
    if (forceTableGroupRebuild || reconciliation.tableEntriesChanged)
      this.rebuildTableInteractionGroups();

    const decorationCount = reconciliation.records.reduce(
      (count, record) => count + Number(record.decoration !== null),
      0,
    );
    this.lastDiagnosticsCommit = {
      documentRevision: identity.documentRevision,
      projectionGeneration: identity.projectionGeneration,
      decorationCount,
      desiredWidgets: 0,
      mountedWidgets: 0,
      activeSourceRangeCount: projection.activeSourceRangeCount,
      activeSourceRanges: projection.activeSourceRanges,
      fallbackCounts: projection.fallbackCounts,
    };
    this.commitDiagnostics();
    this.publish("running");
  }

  private commitDiagnostics(): void {
    const commit = this.lastDiagnosticsCommit;
    if (commit === null) return;
    this.diagnostics.commit({
      ...commit,
      desiredWidgets: this.atomicDesiredWidgets,
      mountedWidgets: this.atomicMountedWidgets,
      fallbackCounts: {
        ...commit.fallbackCounts,
        "rich-source-limit":
          (commit.fallbackCounts?.["rich-source-limit"] ?? 0) + this.atomicRichSourceLimit,
        "renderer-unavailable":
          (commit.fallbackCounts?.["renderer-unavailable"] ?? 0) + this.atomicRendererUnavailable,
        "stale-capability":
          (commit.fallbackCounts?.["stale-capability"] ?? 0) + this.atomicStaleCapability,
      },
    });
  }

  private publish(state: EditableProjectionControllerState): void {
    const atomicEntries: AtomicEntry[] = [];
    if (state === "running") {
      for (const { entry } of this.records) {
        if (entry.type === "atomic") atomicEntries.push(entry);
        if (atomicEntries.length === maxAtomicProjectionRequests) break;
      }
    }
    this.onCommit({
      state,
      metrics: this.metrics(),
      atomicEntries,
    });
  }
}
