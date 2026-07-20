import {
  Annotation,
  StateEffect,
  StateField,
  type ChangeDesc,
  type Extension,
} from "@codemirror/state";
import {
  Decoration,
  EditorView,
  WidgetType,
  type DecorationSet,
  type ViewUpdate,
} from "@codemirror/view";
import type { EditorRevisionClock } from "./live-preview-state";
import {
  isProjectionResult,
  maxLivePreviewProjectionCodeUnits,
  type ProjectionRange,
  type ProjectionResult,
} from "./live-preview-protocol";
import {
  capabilitiesEqual,
  fragmentChannel,
  fragmentMessageMatches,
  isFragmentReady,
  isFragmentRendered,
  type RendererCapability,
} from "./renderer-capability";
import {
  LivePreviewWorkerClient,
  type LivePreviewWorkerState,
  type WorkerPort,
} from "./live-preview-worker-client";

const setLivePreviewDecorations = StateEffect.define<DecorationSet>();
const livePreviewDecorationTransaction = Annotation.define<boolean>();

const livePreviewDecorationField = StateField.define<DecorationSet>({
  create: () => Decoration.none,
  update(value, transaction) {
    if (transaction.docChanged) value = value.map(transaction.changes);
    for (const effect of transaction.effects) {
      if (effect.is(setLivePreviewDecorations)) value = effect.value;
    }
    return value;
  },
  provide: (field) => EditorView.decorations.from(field),
});

export const livePreviewEditorExtension: Extension = livePreviewDecorationField;

type FragmentRecord = Readonly<{
  capability: RendererCapability;
  fragment: Readonly<{ from: number; to: number; kind: string }>;
  widget: FragmentWidget;
}>;

export function mapLivePreviewRange(
  range: Readonly<{ from: number; to: number }>,
  changes: ChangeDesc,
  documentLength: number,
): Readonly<{ from: number; to: number }> {
  const from = Math.min(documentLength, changes.mapPos(range.from, -1));
  const to = Math.min(documentLength, changes.mapPos(range.to, 1));
  return { from: Math.min(from, to), to: Math.max(from, to) };
}

export function reconcileFragmentBatch<T>(
  current: readonly T[],
  desired: readonly T[],
  equal: (left: T, right: T) => boolean,
): Readonly<{ next: T[]; removed: number; added: number }> {
  const removals = current
    .filter((record) => !desired.some((item) => equal(record, item)))
    .slice(0, 2);
  let next = current.filter((record) => !removals.some((item) => equal(record, item)));
  const additions =
    removals.length === 0
      ? desired.filter((record) => !current.some((item) => equal(record, item))).slice(0, 2)
      : [];
  next = next.concat(additions);
  return { next, removed: removals.length, added: additions.length };
}

export function fragmentRecordCanBeReused(
  capability: RendererCapability,
  result: Readonly<{ documentRevision: number; projectionGeneration: number }>,
  currentRange: Readonly<{ from: number; to: number }>,
  nextRange: Readonly<{ from: number; to: number }>,
): boolean {
  return (
    capability.documentRevision === result.documentRevision &&
    capability.projectionGeneration === result.projectionGeneration &&
    currentRange.from === nextRange.from &&
    currentRange.to === nextRange.to
  );
}

let nextWidgetId = 0;
let nextWidgetGeneration = 0;
let nextRendererInstance = Math.max(1, Date.now() % 1_000_000_000);

function nextIdentity(counter: "widget" | "generation" | "renderer"): number {
  if (counter === "widget") {
    if (nextWidgetId >= Number.MAX_SAFE_INTEGER) throw new RangeError("widget identity exhausted");
    return (nextWidgetId += 1);
  }
  if (counter === "generation") {
    if (nextWidgetGeneration >= Number.MAX_SAFE_INTEGER)
      throw new RangeError("widget generation exhausted");
    return (nextWidgetGeneration += 1);
  }
  if (nextRendererInstance >= Number.MAX_SAFE_INTEGER)
    throw new RangeError("renderer identity exhausted");
  return (nextRendererInstance += 1);
}

function projectionRanges(view: EditorView): ProjectionRange[] {
  const ranges: ProjectionRange[] = [];
  const viewportLength = Math.max(1, view.viewport.to - view.viewport.from);
  const overscan = viewportLength * 2;
  const desiredFrom = Math.max(0, view.viewport.from - overscan);
  const desiredTo = Math.min(view.state.doc.length, view.viewport.to + overscan);
  const anchor = view.state.selection.main.head;
  const maxFrom = Math.max(desiredFrom, desiredTo - maxLivePreviewProjectionCodeUnits);
  const centeredFrom = Math.max(
    desiredFrom,
    anchor - Math.floor(maxLivePreviewProjectionCodeUnits / 2),
  );
  const viewportFrom = Math.min(maxFrom, centeredFrom);
  ranges.push({
    from: viewportFrom,
    to: Math.min(desiredTo, viewportFrom + maxLivePreviewProjectionCodeUnits),
    active: false,
  });
  for (const range of view.state.selection.ranges.slice(0, 15)) {
    ranges.push({ from: range.from, to: range.to, active: true });
  }
  return ranges;
}

class BrowserWorkerPort implements WorkerPort {
  constructor(private readonly worker: Worker) {}

  postMessage(message: Parameters<Worker["postMessage"]>[0]): void {
    this.worker.postMessage(message);
  }

  terminate(): void {
    this.worker.terminate();
  }

  get onmessage(): ((event: MessageEvent<unknown>) => void) | null {
    return this.worker.onmessage as ((event: MessageEvent<unknown>) => void) | null;
  }

  set onmessage(value: ((event: MessageEvent<unknown>) => void) | null) {
    this.worker.onmessage = value as ((this: Worker, event: MessageEvent) => unknown) | null;
  }

  get onerror(): ((event: Event) => void) | null {
    return this.worker.onerror as ((event: Event) => void) | null;
  }

  set onerror(value: ((event: Event) => void) | null) {
    this.worker.onerror = value as ((this: AbstractWorker, event: ErrorEvent) => unknown) | null;
  }

  get onmessageerror(): ((event: MessageEvent<unknown>) => void) | null {
    return this.worker.onmessageerror as ((event: MessageEvent<unknown>) => void) | null;
  }

  set onmessageerror(value: ((event: MessageEvent<unknown>) => void) | null) {
    this.worker.onmessageerror = value as ((this: Worker, event: MessageEvent) => unknown) | null;
  }
}

class FragmentWidget extends WidgetType {
  private port: MessagePort | null = null;
  private deadline: ReturnType<typeof setTimeout> | null = null;
  private ready = false;
  private rendered = false;
  private revoked = false;

  constructor(
    readonly capability: RendererCapability,
    private html: string,
    private readonly isCurrent: (capability: RendererCapability) => boolean,
    private readonly onFailure: (capability: RendererCapability) => void,
  ) {
    super();
  }

  eq(other: FragmentWidget): boolean {
    return capabilitiesEqual(this.capability, other.capability) && this.html === other.html;
  }

  toDOM(view: EditorView): HTMLElement {
    const document = view.dom.ownerDocument;
    const container = document.createElement("div");
    container.className = "maru-live-fragment";
    const iframe = document.createElement("iframe");
    iframe.className = "maru-live-fragment-frame";
    iframe.title = "Markdown 라이브 프리뷰 조각";
    iframe.setAttribute("sandbox", "allow-scripts allow-same-origin");
    iframe.setAttribute("tabindex", "-1");

    const channel = new MessageChannel();
    this.port = channel.port1;
    this.port.onmessage = (event) => {
      if (!this.isCurrent(this.capability)) return;
      if (isFragmentReady(event.data) && fragmentMessageMatches(event.data, this.capability)) {
        if (this.ready) return;
        this.ready = true;
        this.port?.postMessage({
          channel: fragmentChannel,
          type: "fragment-render",
          capability: this.capability,
          html: this.html,
        });
        // structured clone는 postMessage 반환 전에 끝난다. 이후 parent가 raw HTML을 보유할 이유가 없다.
        this.html = "";
        return;
      }
      if (isFragmentRendered(event.data) && fragmentMessageMatches(event.data, this.capability)) {
        if (!this.ready || this.rendered) return;
        this.rendered = true;
        this.clearDeadline();
        iframe.style.height = `${Math.ceil(event.data.height)}px`;
        iframe.dataset.fragmentRendered = "true";
        view.requestMeasure();
        this.port?.close();
        this.port = null;
      }
    };
    this.port.start();
    iframe.addEventListener(
      "load",
      () => {
        if (!this.isCurrent(this.capability)) return;
        iframe.contentWindow?.postMessage(
          { channel: fragmentChannel, type: "fragment-init", capability: this.capability },
          "*",
          [channel.port2],
        );
      },
      { once: true },
    );
    // Install the load listener and capability port before assigning src/attaching. A cached custom-scheme
    // renderer can otherwise complete while the iframe is still detached and lose its only init capability.
    iframe.src = "maru-app://render/render.html";
    container.append(iframe);
    this.deadline = setTimeout(() => this.onFailure(this.capability), 2_000);
    return container;
  }

  destroy(): void {
    this.revoke();
  }

  revoke(): void {
    this.revoked = true;
    this.clearDeadline();
    this.html = "";
    this.port?.close();
    this.port = null;
  }

  canReuse(): boolean {
    return !this.revoked;
  }

  private clearDeadline(): void {
    if (this.deadline !== null) clearTimeout(this.deadline);
    this.deadline = null;
  }
}

export class LivePreviewEditorController {
  private client: LivePreviewWorkerClient | null = null;
  private enabled = false;
  private records: FragmentRecord[] = [];
  private desiredRecords: FragmentRecord[] = [];
  private reconcileScheduled = false;
  private reconcileGeneration = 0;
  private reconcileAnimationFrame: number | null = null;
  private reconcileWatchdog: number | null = null;
  private state: LivePreviewWorkerState = "running";
  constructor(
    private readonly view: EditorView,
    private readonly editorEpoch: number,
    private readonly revisions: EditorRevisionClock,
    private readonly workerConstructor: typeof Worker | null,
    private readonly onState: (state: LivePreviewWorkerState, reason?: string) => void = () => {},
    private readonly onFragments: (desired: number, mounted: number) => void = () => {},
  ) {}

  enable(): void {
    if (this.enabled) {
      this.project();
      return;
    }
    this.enabled = true;
    if (this.workerConstructor === null) {
      this.state = "disabled";
      this.onState(this.state);
      return;
    }
    this.client = new LivePreviewWorkerClient(
      () =>
        new BrowserWorkerPort(
          // WebKit custom schemes do not reliably instantiate module workers. zntc emits one self-contained
          // bundle with no import graph, so a classic same-origin worker preserves the exact CSP/URL boundary.
          new this.workerConstructor("maru-app://app/live-preview-worker.js"),
        ),
      () => ({
        documentRevision: this.revisions.documentRevision,
        projectionGeneration: this.revisions.projectionGeneration,
        source: this.view.state.doc.toString(),
        visibleRanges: projectionRanges(this.view),
      }),
      (result) => this.applyProjection(result),
      (state, reason) => {
        this.state = state;
        this.onState(state, reason);
        if (state === "recovering" || state === "disabled") this.clear();
      },
    );
    const projection = this.revisions.nextProjection();
    this.client.start();
    this.client.submitProjection(
      projection.documentRevision,
      projection.projectionGeneration,
      projectionRanges(this.view),
    );
  }

  disable(): void {
    if (!this.enabled) return;
    this.enabled = false;
    this.client?.dispose();
    this.client = null;
    this.clear();
  }

  destroy(): void {
    this.enabled = false;
    this.client?.dispose();
    this.client = null;
    this.cancelReconcile();
    for (const record of [...this.records, ...this.desiredRecords]) record.widget.revoke();
    this.records = [];
    this.desiredRecords = [];
    try {
      this.view.dispatch({
        effects: setLivePreviewDecorations.of(Decoration.none),
        annotations: livePreviewDecorationTransaction.of(true),
      });
    } catch {
      // The owner may already have destroyed EditorView during page teardown.
    }
  }

  handleUpdate(update: ViewUpdate, baseRevision: number, targetRevision: number): void {
    if (
      update.transactions.some(
        (transaction) => transaction.annotation(livePreviewDecorationTransaction) === true,
      )
    ) {
      return;
    }
    if (update.docChanged) {
      this.records = this.records.map((record) => ({
        ...record,
        fragment: {
          ...record.fragment,
          ...mapLivePreviewRange(record.fragment, update.changes, update.state.doc.length),
        },
      }));
    }
    if (!this.enabled || this.client === null) return;
    if (update.docChanged) {
      this.setDesiredRecords([]);
      const projection = this.revisions.nextProjection();
      this.client.submitChanges(
        baseRevision,
        targetRevision,
        update.changes,
        projection.projectionGeneration,
        projectionRanges(update.view),
      );
      return;
    }
    if (update.selectionSet || update.viewportChanged) this.project();
  }

  resync(): void {
    if (!this.enabled) return;
    this.client?.dispose();
    this.client = null;
    this.enabled = false;
    this.clear();
    this.enable();
  }

  private project(): void {
    if (!this.enabled || this.client === null) return;
    const projection = this.revisions.nextProjection();
    this.client.submitProjection(
      projection.documentRevision,
      projection.projectionGeneration,
      projectionRanges(this.view),
    );
  }

  private applyProjection(result: ProjectionResult): void {
    if (
      !this.enabled ||
      this.view.composing ||
      !isProjectionResult(result) ||
      result.documentRevision !== this.revisions.documentRevision ||
      result.projectionGeneration !== this.revisions.projectionGeneration
    ) {
      return;
    }
    const records: FragmentRecord[] = [];
    const reusable = [...this.desiredRecords, ...this.records];
    for (const fragment of result.fragments) {
      if (
        typeof fragment.html !== "string" ||
        fragment.from < 0 ||
        fragment.from >= fragment.to ||
        fragment.to > this.view.state.doc.length
      ) {
        continue;
      }
      const existing = reusable.find(
        (record) =>
          fragmentRecordCanBeReused(record.capability, result, record.fragment, fragment) &&
          record.widget.canReuse() &&
          !records.some(({ capability }) => capabilitiesEqual(capability, record.capability)),
      );
      if (existing !== undefined) {
        records.push(existing);
        continue;
      }
      const capability: RendererCapability = {
        editorEpoch: this.editorEpoch,
        documentRevision: result.documentRevision,
        projectionGeneration: result.projectionGeneration,
        widgetId: nextIdentity("widget"),
        widgetGeneration: nextIdentity("generation"),
        rendererInstance: nextIdentity("renderer"),
      };
      const widget = new FragmentWidget(
        capability,
        fragment.html,
        (candidate) =>
          this.desiredRecords.some(({ capability: current }) =>
            capabilitiesEqual(candidate, current),
          ),
        (failed) => this.removeFailed(failed),
      );
      records.push({
        capability,
        fragment: { from: fragment.from, to: fragment.to, kind: fragment.kind },
        widget,
      });
    }
    this.setDesiredRecords(records);
  }

  private removeFailed(failed: RendererCapability): void {
    if (!this.enabled) return;
    this.desiredRecords = this.desiredRecords.filter(
      ({ capability }) => !capabilitiesEqual(capability, failed),
    );
    this.scheduleReconcile();
  }

  private clear(): void {
    this.setDesiredRecords([]);
  }

  private setDesiredRecords(records: FragmentRecord[]): void {
    for (const record of [...this.desiredRecords, ...this.records]) {
      if (!records.some(({ capability }) => capabilitiesEqual(capability, record.capability))) {
        record.widget.revoke();
      }
    }
    this.desiredRecords = records;
    this.onFragments(this.desiredRecords.length, this.records.length);
    this.scheduleReconcile();
  }

  private scheduleReconcile(): void {
    if (this.reconcileScheduled) return;
    this.reconcileScheduled = true;
    const targetWindow = this.view.dom.ownerDocument.defaultView;
    const generation = (this.reconcileGeneration += 1);
    const run = () => {
      if (!this.reconcileScheduled || generation !== this.reconcileGeneration) return;
      this.cancelScheduledHandles(targetWindow);
      this.reconcileScheduled = false;
      this.reconcileFrame();
    };
    this.reconcileAnimationFrame = targetWindow?.requestAnimationFrame?.(run) ?? null;
    // WKWebView may suspend RAF while AppKit is starting or occluding a panel. The watchdog drains one capped
    // batch only when no animation frame arrived; the later RAF becomes a no-op through reconcileScheduled.
    this.reconcileWatchdog = (targetWindow?.setTimeout.bind(targetWindow) ?? setTimeout)(run, 100);
  }

  private reconcileFrame(): void {
    const desired = (record: FragmentRecord) =>
      this.desiredRecords.some(({ capability }) =>
        capabilitiesEqual(record.capability, capability),
      );
    const mounted = (record: FragmentRecord) =>
      this.records.some(({ capability }) => capabilitiesEqual(record.capability, capability));

    const batch = reconcileFragmentBatch(this.records, this.desiredRecords, (left, right) =>
      capabilitiesEqual(left.capability, right.capability),
    );
    const next = batch.next;

    if (batch.removed > 0 || batch.added > 0) {
      try {
        const decorations = Decoration.set(
          next.map(({ fragment, widget }) =>
            Decoration.replace({ widget, block: true }).range(fragment.from, fragment.to),
          ),
          true,
        );
        this.view.dispatch({
          effects: setLivePreviewDecorations.of(decorations),
          annotations: livePreviewDecorationTransaction.of(true),
        });
        this.records = next;
        this.onFragments(this.desiredRecords.length, this.records.length);
      } catch (error) {
        for (const record of [...this.records, ...this.desiredRecords]) record.widget.revoke();
        this.desiredRecords = [];
        this.records = [];
        try {
          this.view.dispatch({
            effects: setLivePreviewDecorations.of(Decoration.none),
            annotations: livePreviewDecorationTransaction.of(true),
          });
        } catch {
          // Preserve the original failure diagnostic below.
        }
        this.state = "disabled";
        this.client?.dispose();
        this.client = null;
        const reason = error instanceof Error ? error.message : "unknown decoration error";
        this.onState(this.state, `fragment-decoration:${reason}`);
        return;
      }
    }
    if (
      this.records.some((record) => !desired(record)) ||
      this.desiredRecords.some((r) => !mounted(r))
    ) {
      this.scheduleReconcile();
    }
  }

  private cancelScheduledHandles(targetWindow: Window | null): void {
    if (this.reconcileAnimationFrame !== null) {
      targetWindow?.cancelAnimationFrame?.(this.reconcileAnimationFrame);
      this.reconcileAnimationFrame = null;
    }
    if (this.reconcileWatchdog !== null) {
      (targetWindow?.clearTimeout.bind(targetWindow) ?? clearTimeout)(this.reconcileWatchdog);
      this.reconcileWatchdog = null;
    }
  }

  private cancelReconcile(): void {
    this.reconcileGeneration += 1;
    this.reconcileScheduled = false;
    this.cancelScheduledHandles(this.view.dom.ownerDocument.defaultView);
  }
}
