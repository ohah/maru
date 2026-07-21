import {
  Annotation,
  StateEffect,
  StateField,
  type ChangeSet,
  type Extension,
} from "@codemirror/state";
import {
  Decoration,
  EditorView,
  WidgetType,
  type DecorationSet,
  type ViewUpdate,
} from "@codemirror/view";
import {
  maxAtomicProjectionRequests,
  type AssetGrant,
  type AtomicProjectionRequest,
} from "./atomic-projection";
import type { LivePreviewIntent } from "./live-preview-intent";
import type { AtomicWidgetMetrics } from "./live-preview-diagnostics";
import type { ProjectionEntry } from "./live-preview-projection";
import { editableProjectionWindow } from "./editable-projection";
import type { EditorRevisionClock } from "./live-preview-state";
import { isProjectionResult, type ProjectionResult } from "./live-preview-protocol";
import {
  atomicRendererChannel,
  atomicRendererMessageMatches,
  capabilitiesEqual,
  isAtomicRendererReady,
  isAtomicRendererRendered,
  type AtomicRenderAsset,
  type RendererCapability,
} from "./renderer-capability";
import {
  LivePreviewWorkerClient,
  type LivePreviewWorkerState,
  type WorkerPort,
} from "./live-preview-worker-client";

const setAtomicDecorations = StateEffect.define<DecorationSet>();
export const atomicProjectionTransaction = Annotation.define<boolean>();
export const maxConsumedAtomicAssetNonces = 64;

const atomicDecorationField = StateField.define<DecorationSet>({
  create: () => Decoration.none,
  update(value, transaction) {
    if (transaction.docChanged) value = value.map(transaction.changes);
    for (const effect of transaction.effects) {
      if (effect.is(setAtomicDecorations)) value = effect.value;
    }
    return value;
  },
  provide: (field) => EditorView.decorations.from(field),
});

export const livePreviewEditorExtension: Extension = atomicDecorationField;
export const maxCachedMermaidEntries = maxAtomicProjectionRequests;
export const maxCachedMermaidSvgCodeUnits = 512 * 1024;

export function mermaidSvgWithinCacheLimit(svg: string): boolean {
  return svg.length <= maxCachedMermaidSvgCodeUnits;
}

export type MermaidCacheMetrics = Readonly<{
  entries: number;
  sourceBytes: number;
  svgCodeUnits: number;
  pending: number;
}>;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

type AtomicEntry = Extract<ProjectionEntry, { type: "atomic" }>;

type AtomicRecord = Readonly<{
  capability: RendererCapability;
  request: AtomicProjectionRequest;
  widget: AtomicWidget;
}>;

export function reconcileAtomicBatch<T>(
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

export function atomicRecordCanBeReused(
  capability: RendererCapability,
  request: AtomicProjectionRequest,
  candidate: AtomicProjectionRequest,
): boolean {
  return (
    capability.editorEpoch === candidate.editorEpoch &&
    capability.documentRevision === candidate.documentRevision &&
    request.editorEpoch === candidate.editorEpoch &&
    request.documentRevision === candidate.documentRevision &&
    request.kind === candidate.kind &&
    request.from === candidate.from &&
    request.to === candidate.to
  );
}

export function atomicRangeRetained(
  range: Readonly<{ from: number; to: number }>,
  discovery: Readonly<{ from: number; to: number }>,
  viewport: Readonly<{ from: number; to: number }>,
  documentLength: number,
): boolean {
  const viewportLength = Math.max(1, viewport.to - viewport.from);
  const retentionFrom = Math.max(0, viewport.from - viewportLength * 2);
  const retentionTo = Math.min(documentLength, viewport.to + viewportLength * 2);
  return (
    (range.to <= discovery.from || range.from >= discovery.to) &&
    range.to > retentionFrom &&
    range.from < retentionTo
  );
}

let nextWidgetId = 0;
let nextWidgetGeneration = 0;
let nextRendererInstance = Math.max(1, Date.now() % 1_000_000_000);

function nextIdentity(counter: "widget" | "generation" | "renderer"): number {
  if (counter === "widget") return (nextWidgetId += 1);
  if (counter === "generation") return (nextWidgetGeneration += 1);
  return (nextRendererInstance += 1);
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

class AtomicWidget extends WidgetType {
  private port: MessagePort | null = null;
  private transferPort: MessagePort | null = null;
  private deadline: ReturnType<typeof setTimeout> | null = null;
  private revoked = false;
  private ready = false;
  private rendered = false;
  private hostWindow: Window | null = null;
  private initListener: ((event: MessageEvent<unknown>) => void) | null = null;

  constructor(
    readonly capability: RendererCapability,
    private payload: string,
    private assets: readonly AtomicRenderAsset[],
    private readonly isCurrent: (capability: RendererCapability) => boolean,
    private readonly onFailure: (capability: RendererCapability) => void,
    private readonly onSelect: (trusted: boolean) => void,
  ) {
    super();
  }

  eq(other: AtomicWidget): boolean {
    return capabilitiesEqual(this.capability, other.capability);
  }

  isRendered(): boolean {
    return this.rendered && !this.revoked;
  }

  toDOM(view: EditorView): HTMLElement {
    const document = view.dom.ownerDocument;
    const container = document.createElement("div");
    container.className = "maru-live-atomic";
    container.addEventListener("mousedown", (event) => {
      if (event.button !== 0 || this.revoked) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      this.onSelect(event.isTrusted);
    });
    const iframe = document.createElement("iframe");
    iframe.className = "maru-live-atomic-frame";
    iframe.title = "Markdown 라이브 프리뷰 원자 블록";
    iframe.setAttribute("sandbox", "allow-scripts allow-same-origin");
    iframe.setAttribute("tabindex", "-1");
    iframe.style.pointerEvents = "none";

    const channel = new MessageChannel();
    this.port = channel.port1;
    this.transferPort = channel.port2;
    this.port.onmessage = (event) => {
      if (!this.isCurrent(this.capability)) return;
      if (
        isAtomicRendererReady(event.data) &&
        atomicRendererMessageMatches(event.data, this.capability)
      ) {
        if (this.ready) return;
        this.ready = true;
        this.port?.postMessage({
          channel: atomicRendererChannel,
          type: "atomic-render",
          capability: this.capability,
          payload: this.payload,
          assets: this.assets,
        });
        this.payload = "";
        this.assets = [];
        return;
      }
      if (
        isAtomicRendererRendered(event.data) &&
        atomicRendererMessageMatches(event.data, this.capability)
      ) {
        if (!this.ready || this.rendered) return;
        this.rendered = true;
        this.clearDeadline();
        iframe.style.height = `${Math.ceil(event.data.height)}px`;
        iframe.dataset.atomicRendered = "true";
        view.requestMeasure();
        this.port?.close();
        this.port = null;
      }
    };
    this.port.start();
    const hostWindow = document.defaultView;
    this.hostWindow = hostWindow;
    this.initListener = (event) => {
      const contentWindow = iframe.contentWindow;
      if (
        event.source !== contentWindow ||
        !isRecord(event.data) ||
        Object.keys(event.data).length !== 2 ||
        event.data.channel !== atomicRendererChannel ||
        event.data.type !== "atomic-boot" ||
        !this.isCurrent(this.capability)
      )
        return;
      const transferPort = this.transferPort;
      if (transferPort === null || contentWindow === null) return;
      contentWindow.postMessage(
        { channel: atomicRendererChannel, type: "atomic-init", capability: this.capability },
        "*",
        [transferPort],
      );
      this.transferPort = null;
      if (this.hostWindow !== null && this.initListener !== null)
        this.hostWindow.removeEventListener("message", this.initListener);
      this.initListener = null;
      this.hostWindow = null;
    };
    hostWindow?.addEventListener("message", this.initListener);
    iframe.src = "maru-app://render/render.html?atomic=1";
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
    this.payload = "";
    this.assets = [];
    this.port?.close();
    this.port = null;
    this.transferPort?.close();
    this.transferPort = null;
    if (this.hostWindow !== null && this.initListener !== null)
      this.hostWindow.removeEventListener("message", this.initListener);
    this.initListener = null;
    this.hostWindow = null;
  }

  private clearDeadline(): void {
    if (this.deadline !== null) clearTimeout(this.deadline);
    this.deadline = null;
  }
}

export class AtomicProjectionController {
  private client: LivePreviewWorkerClient | null = null;
  private enabled = false;
  private destroyed = false;
  private entries: readonly AtomicEntry[] = [];
  private requests: readonly AtomicProjectionRequest[] = [];
  private records: AtomicRecord[] = [];
  private desiredRecords: AtomicRecord[] = [];
  private pendingUpdate: Readonly<{
    baseRevision: number;
    targetRevision: number;
    changes: ChangeSet;
  }> | null = null;
  private applyingProjection = false;
  private pendingProjection: ProjectionResult | null = null;
  private nextRequestNonce = 1;
  private reconcileScheduled = false;
  private reconcileGeneration = 0;
  private reconcileAnimationFrame: number | null = null;
  private reconcileWatchdog: number | null = null;
  private richSourceLimit = 0;
  private rendererUnavailable = 0;
  private staleCapability = 0;
  private staleCapabilityTotal = 0;
  private lifecycleToken = 0;
  private metricsDocumentRevision = 0;
  private metricsProjectionGeneration = 1;
  private readonly consumedAssetNonces = new Set<number>();
  private readonly mermaidCache = new Map<string, Readonly<{ source: string; svg: string }>>();
  private readonly pendingMermaid = new Map<number, RendererCapability>();
  // 각 in-flight renderMermaid의 취소 핸들. 수명 전환(disable/destroy/replacement)에서 원 mailbox
  // (Promise·listener·hidden node)를 정확히 한 번 회수해, 응답 없는 render의 stuck await로 applyingProjection이
  // 고착되고 이후 projection 적용이 멈추는 것을 막는다.
  private readonly pendingMermaidAborts = new Map<number, AbortController>();

  constructor(
    private readonly view: EditorView,
    private readonly editorEpoch: number,
    private readonly revisions: EditorRevisionClock,
    private readonly workerConstructor: typeof Worker | null,
    private readonly loadAsset: (grant: AssetGrant) => Promise<string | null>,
    private readonly onState: (state: LivePreviewWorkerState, reason?: string) => void = () => {},
    private readonly onWidgets: (metrics: AtomicWidgetMetrics) => void = () => {},
    private readonly onIntent: (intent: LivePreviewIntent) => void = () => {},
    private readonly renderMermaid: (
      capability: RendererCapability,
      fenceId: number,
      sourceHash: string,
      source: string,
      signal?: AbortSignal,
    ) => Promise<string | null> = async () => null,
    private readonly revokeMermaid: (capability: RendererCapability) => void = () => {},
  ) {}

  enable(): void {
    if (this.destroyed || this.enabled) return;
    this.lifecycleToken += 1;
    this.enabled = true;
    this.requests = this.requestsForEntries(
      this.metricsDocumentRevision,
      this.metricsProjectionGeneration,
      this.entries,
    );
    if (this.workerConstructor === null) {
      this.onState("disabled", "worker-unavailable");
      this.publishMetrics();
      return;
    }
    // zntc가 `new this.workerConstructor(...)` member-expression을 `new this.workerConstructor()(... )`로
    // 잘못 낮추지 않게 검증된 constructor를 local binding으로 고정한다(WebKit 실제 smoke가 이 경계를 검증한다).
    const WorkerConstructor = this.workerConstructor;
    this.client = new LivePreviewWorkerClient(
      () =>
        new BrowserWorkerPort(
          new WorkerConstructor("maru-app://app/live-preview-worker.js", { type: "classic" }),
        ),
      () => ({
        editorEpoch: this.editorEpoch,
        documentRevision: this.revisions.documentRevision,
        projectionGeneration: this.revisions.projectionGeneration,
        source: this.view.state.doc.toString(),
        requests: this.requests,
      }),
      (result) => this.enqueueProjection(result),
      (state, reason) => {
        this.onState(state, reason);
        if (state === "running") {
          this.publishMetrics();
        }
        if (state === "recovering" || state === "disabled") {
          this.requests = this.requestsForEntries(
            this.metricsDocumentRevision,
            this.metricsProjectionGeneration,
            this.entries,
          );
          this.clear();
        }
      },
    );
    this.client.start();
    this.submitCurrentProjection();
  }

  disable(): void {
    if (!this.enabled) return;
    this.enabled = false;
    this.pendingUpdate = null;
    this.pendingProjection = null;
    this.client?.dispose();
    this.client = null;
    this.clear();
    // clear()는 desired를 []로 두고 rAF reconcile(프레임당 위젯 2개씩 제거)에 위임할 뿐이라, source/read 전환이나
    // budget suspend 직후에도 `Decoration.replace({widget, block:true})` 블록 위젯이 CM6에 남는다. offscreen
    // throttling으로 rAF가 지연되면 그대로 고착돼 소스 모드에서 본문이 위젯에 가려지고 라인 높이가 phantom으로 커진다
    // (source-preserving 즉시 성립 실패). destroy와 같은 동기 purge로 atomic decoration을 지금 비운다. iframe/mermaid
    // revoke는 clear()가 이미 처리했고, ≤2/frame은 정상 reconcile 정책이라 mode-leave 전체 teardown에는 적용하지 않는다.
    this.cancelReconcile();
    // block widget을 지워도 CM6 height map은 그 라인들의 측정 높이(widget 높이)를 유지해, 소스 모드에서 라인 간격이
    // 들쭉날쭉하고 첫 줄이 phantom 높이만큼 밀린다. 위젯 제거 DOM reflow 뒤 측정이 필요하므로 재측정을 강제한다.
    this.view.requestMeasure();
    // Cache lifetime follows the app-global applied worker budget. Hidden/source/read panels keep their
    // WKWebView alive, so retaining per-editor SVG here would bypass the global memory bound.
    this.mermaidCache.clear();
  }

  destroy(): void {
    if (this.destroyed) return;
    this.disable();
    this.mermaidCache.clear();
    this.destroyed = true;
    this.cancelReconcile();
  }

  /** Deterministic perf/test snapshot; product policy continues to be owned by the private bounded maps. */
  mermaidCacheMetrics(): MermaidCacheMetrics {
    let sourceBytes = 0;
    let svgCodeUnits = 0;
    const encoder = new TextEncoder();
    for (const value of this.mermaidCache.values()) {
      sourceBytes += encoder.encode(value.source).byteLength;
      svgCodeUnits += value.svg.length;
    }
    return {
      entries: this.mermaidCache.size,
      sourceBytes,
      svgCodeUnits,
      pending: this.pendingMermaid.size,
    };
  }

  handleUpdate(update: ViewUpdate, baseRevision: number, targetRevision: number): void {
    if (
      this.destroyed ||
      update.transactions.some(
        (transaction) => transaction.annotation(atomicProjectionTransaction) === true,
      )
    ) {
      return;
    }
    if (update.docChanged) {
      const pending = this.pendingUpdate;
      if (pending !== null && pending.targetRevision === baseRevision) {
        try {
          this.pendingUpdate = {
            baseRevision: pending.baseRevision,
            targetRevision,
            changes: pending.changes.compose(update.changes),
          };
        } catch {
          // A malformed or oversized composition deliberately falls back to the client's bounded full resync.
          this.pendingUpdate = { baseRevision, targetRevision, changes: update.changes };
        }
      } else this.pendingUpdate = { baseRevision, targetRevision, changes: update.changes };
      this.clear();
    }
  }

  submitEntries(
    documentRevision: number,
    projectionGeneration: number,
    entries: readonly AtomicEntry[],
  ): void {
    // submitEntries replaces the exact worker request batch. Any helper promise for the previous batch is
    // already stale even if its source range happens to be identical.
    this.revokePendingMermaid();
    this.metricsDocumentRevision = documentRevision;
    this.metricsProjectionGeneration = projectionGeneration;
    this.richSourceLimit = 0;
    this.rendererUnavailable = 0;
    this.staleCapability = 0;
    this.entries = entries.slice(0, maxAtomicProjectionRequests);
    const discovery = editableProjectionWindow(this.view);
    const available = [...this.desiredRecords, ...this.records].filter(
      (record, index, records) =>
        records.findIndex(({ capability }) => capabilitiesEqual(capability, record.capability)) ===
        index,
    );
    const reused: AtomicRecord[] = [];
    const pendingEntries: AtomicEntry[] = [];
    for (const entry of this.entries) {
      const candidateRequest: AtomicProjectionRequest = {
        editorEpoch: this.editorEpoch,
        documentRevision,
        projectionGeneration,
        requestNonce: 1,
        kind: entry.role,
        from: entry.from,
        to: entry.to,
      };
      const candidate = available.find(
        (record) =>
          record.widget.isRendered() &&
          !reused.includes(record) &&
          atomicRecordCanBeReused(record.capability, record.request, candidateRequest),
      );
      if (candidate === undefined) pendingEntries.push(entry);
      else reused.push(candidate);
    }
    const retained: AtomicRecord[] = [];
    for (const record of available) {
      const range = record.request;
      const stillDiscovered = this.entries.some(
        (entry) => entry.role === range.kind && entry.from === range.from && entry.to === range.to,
      );
      if (
        record.widget.isRendered() &&
        !stillDiscovered &&
        atomicRangeRetained(range, discovery, this.view.viewport, this.view.state.doc.length) &&
        range.documentRevision === documentRevision &&
        retained.length < maxAtomicProjectionRequests - this.entries.length &&
        !retained.some(({ capability }) => capabilitiesEqual(capability, record.capability))
      ) {
        retained.push(record);
      }
    }
    this.requests = this.requestsForEntries(documentRevision, projectionGeneration, pendingEntries);
    this.setDesiredRecords([...reused, ...retained]);
    if (!this.enabled || this.client === null) {
      this.publishMetrics();
      return;
    }
    const pending = this.pendingUpdate;
    this.pendingUpdate = null;
    if (pending !== null && pending.targetRevision === documentRevision) {
      this.client.submitChanges(
        pending.baseRevision,
        pending.targetRevision,
        pending.changes,
        projectionGeneration,
        this.requests,
      );
    } else this.client.submitProjection(documentRevision, projectionGeneration, this.requests);
    this.publishMetrics();
  }

  private submitCurrentProjection(): void {
    if (!this.enabled || this.client === null) return;
    this.client.submitProjection(
      this.revisions.documentRevision,
      this.revisions.projectionGeneration,
      this.requests,
    );
  }

  private nextNonce(): number {
    const nonce = this.nextRequestNonce;
    if (!Number.isSafeInteger(nonce) || nonce <= 0) throw new RangeError("atomic nonce exhausted");
    this.nextRequestNonce += 1;
    return nonce;
  }

  private requestsForEntries(
    documentRevision: number,
    projectionGeneration: number,
    entries: readonly AtomicEntry[],
  ): AtomicProjectionRequest[] {
    // Replay state belongs to the current exact request batch. Request nonces are monotonic, so an older result
    // cannot become current after this reset, while successful future image projections do not accumulate into
    // an editor-lifetime admission limit.
    this.consumedAssetNonces.clear();
    return entries.map((entry) => ({
      editorEpoch: this.editorEpoch,
      documentRevision,
      projectionGeneration,
      requestNonce: this.nextNonce(),
      kind: entry.role,
      from: entry.from,
      to: entry.to,
    }));
  }

  private enqueueProjection(result: ProjectionResult): void {
    if (this.applyingProjection) {
      this.pendingProjection = result;
      return;
    }
    this.applyingProjection = true;
    void this.drainProjectionQueue(result);
  }

  private async drainProjectionQueue(first: ProjectionResult): Promise<void> {
    let current: ProjectionResult | null = first;
    try {
      while (current !== null) {
        try {
          await this.applyProjection(current);
        } catch {
          // A rejected bridge promise or unexpected renderer adapter failure is range-local. Keep draining the
          // latest-only slot so an older failed result cannot strand or reorder a newer current projection.
          this.rendererUnavailable += 1;
          this.publishMetrics();
        }
        current = this.pendingProjection;
        this.pendingProjection = null;
      }
    } finally {
      this.applyingProjection = false;
    }
  }

  private async applyProjection(result: ProjectionResult): Promise<void> {
    const lifecycleToken = this.lifecycleToken;
    if (
      !this.enabled ||
      this.destroyed ||
      this.view.composing ||
      !isProjectionResult(result) ||
      result.editorEpoch !== this.editorEpoch ||
      result.documentRevision !== this.revisions.documentRevision ||
      result.projectionGeneration !== this.revisions.projectionGeneration
    ) {
      this.staleCapabilityTotal += 1;
      this.publishMetrics();
      return;
    }
    const expectedNonces = new Set(this.requests.map(({ requestNonce }) => requestNonce));
    const terminalNonces = [
      ...result.results.map(({ request }) => request.requestNonce),
      ...result.rejected.map(({ requestNonce }) => requestNonce),
    ];
    if (
      terminalNonces.length !== expectedNonces.size ||
      new Set(terminalNonces).size !== expectedNonces.size ||
      terminalNonces.some((nonce) => !expectedNonces.has(nonce))
    ) {
      this.staleCapability += Math.max(1, expectedNonces.size);
      this.staleCapabilityTotal += Math.max(1, expectedNonces.size);
      this.publishMetrics();
      return;
    }
    this.richSourceLimit = result.rejected.filter(
      ({ reason }) => reason === "rich-source-limit",
    ).length;
    this.rendererUnavailable = result.rejected.filter(
      ({ reason }) => reason === "renderer-unavailable" || reason === "invalid-request",
    ).length;
    const resultAssetNonces = result.results.flatMap(({ assetGrants }) =>
      assetGrants.map(({ assetNonce }) => assetNonce),
    );
    if (
      new Set(resultAssetNonces).size !== resultAssetNonces.length ||
      resultAssetNonces.some((nonce) => this.consumedAssetNonces.has(nonce)) ||
      this.consumedAssetNonces.size > maxConsumedAtomicAssetNonces - resultAssetNonces.length
    ) {
      if (this.consumedAssetNonces.size > maxConsumedAtomicAssetNonces - resultAssetNonces.length)
        this.rendererUnavailable += Math.max(1, resultAssetNonces.length);
      else {
        this.staleCapability += 1;
        this.staleCapabilityTotal += 1;
      }
      this.publishMetrics();
      return;
    }
    const records: AtomicRecord[] = [...this.desiredRecords];
    for (const projected of result.results) {
      const currentRequest = this.requests.find(
        ({ requestNonce }) => requestNonce === projected.request.requestNonce,
      );
      if (
        currentRequest === undefined ||
        currentRequest.editorEpoch !== projected.request.editorEpoch ||
        currentRequest.documentRevision !== projected.request.documentRevision ||
        currentRequest.projectionGeneration !== projected.request.projectionGeneration ||
        currentRequest.kind !== projected.request.kind ||
        currentRequest.from !== projected.request.from ||
        currentRequest.to !== projected.request.to
      ) {
        this.staleCapability += 1;
        this.staleCapabilityTotal += 1;
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
      let payload = projected.sanitizedPayload;
      if (currentRequest.kind === "mermaid") {
        const source = projected.mermaidSource;
        let svg: string | null = null;
        let renderedFresh = false;
        if (source !== null) {
          const cached = this.mermaidCache.get(projected.sourceHash);
          if (cached?.source === source) svg = cached.svg;
          else {
            this.pendingMermaid.set(capability.widgetId, capability);
            const abort = new AbortController();
            this.pendingMermaidAborts.set(capability.widgetId, abort);
            try {
              svg = await this.renderMermaid(
                capability,
                currentRequest.requestNonce,
                projected.sourceHash,
                source,
                abort.signal,
              );
              renderedFresh = svg !== null;
            } catch {
              svg = null;
            } finally {
              if (this.pendingMermaid.get(capability.widgetId) === capability)
                this.pendingMermaid.delete(capability.widgetId);
              if (this.pendingMermaidAborts.get(capability.widgetId) === abort)
                this.pendingMermaidAborts.delete(capability.widgetId);
            }
          }
        }
        if (
          !this.enabled ||
          lifecycleToken !== this.lifecycleToken ||
          result.documentRevision !== this.revisions.documentRevision ||
          result.projectionGeneration !== this.revisions.projectionGeneration ||
          !this.requests.includes(currentRequest)
        ) {
          this.staleCapabilityTotal += 1;
          this.publishMetrics();
          return;
        }
        if (svg === null || !mermaidSvgWithinCacheLimit(svg)) {
          this.rendererUnavailable += 1;
          continue;
        }
        if (renderedFresh) {
          if (
            !this.mermaidCache.has(projected.sourceHash) &&
            this.mermaidCache.size >= maxCachedMermaidEntries
          ) {
            const oldest = this.mermaidCache.keys().next().value;
            if (oldest !== undefined) this.mermaidCache.delete(oldest);
          }
          // SHA-256는 lookup key일 뿐이다. exact source까지 같을 때만 재사용해 collision이 다른
          // diagram의 trusted helper 결과를 선택하는 SSOT 분기를 만들지 않는다.
          this.mermaidCache.set(projected.sourceHash, { source, svg });
        }
        payload = svg;
      }
      const assets: AtomicRenderAsset[] = [];
      let assetFailure = false;
      for (const grant of projected.assetGrants) {
        this.consumedAssetNonces.add(grant.assetNonce);
        let dataUrl: string | null = null;
        try {
          dataUrl = await this.loadAsset(grant);
        } catch {
          // Bridge timeout/mailbox failure has the same terminal policy as a rejected asset: preserve source and
          // expose renderer-unavailable without rejecting the controller's fire-and-forget drain.
          dataUrl = null;
        }
        if (
          !this.enabled ||
          lifecycleToken !== this.lifecycleToken ||
          result.documentRevision !== this.revisions.documentRevision ||
          result.projectionGeneration !== this.revisions.projectionGeneration ||
          !this.requests.includes(currentRequest)
        ) {
          this.staleCapabilityTotal += 1;
          this.publishMetrics();
          return;
        }
        if (dataUrl === null) {
          assetFailure = true;
          this.rendererUnavailable += 1;
          break;
        }
        assets.push({ opaqueId: grant.opaqueId, dataUrl });
      }
      if (assetFailure) {
        continue;
      }
      const request = projected.request;
      const widget = new AtomicWidget(
        capability,
        payload,
        assets,
        (candidate) =>
          this.desiredRecords.some(({ capability: current }) =>
            capabilitiesEqual(candidate, current),
          ),
        (failed) => this.removeFailed(failed),
        (trusted) => {
          if (!trusted) return;
          this.onIntent({
            type: "select-atomic",
            editorEpoch: this.editorEpoch,
            documentRevision: this.revisions.documentRevision,
            projectionGeneration: this.revisions.projectionGeneration,
            from: request.from,
            to: request.to,
            trusted,
            input: "pointer",
            gestureNonce: null,
          });
        },
      );
      records.push({ capability, request, widget });
    }
    this.setDesiredRecords(records);
  }

  private removeFailed(failed: RendererCapability): void {
    this.rendererUnavailable += 1;
    this.desiredRecords = this.desiredRecords.filter(
      ({ capability }) => !capabilitiesEqual(capability, failed),
    );
    this.scheduleReconcile();
    this.publishMetrics();
  }

  private clear(): void {
    this.lifecycleToken += 1;
    this.revokePendingMermaid();
    this.setDesiredRecords([]);
  }

  private revokePendingMermaid(): void {
    // 응답 없는 원 render mailbox를 먼저 로컬에서 abort(정확히 한 번)해 stuck await를 풀고 applyingProjection
    // 고착을 해소한 뒤, native에 revoke를 통지한다. abort는 별도 2.5s revoke 요청과 무관하게 즉시 회수한다.
    for (const abort of this.pendingMermaidAborts.values()) abort.abort();
    this.pendingMermaidAborts.clear();
    for (const capability of this.pendingMermaid.values()) this.revokeMermaid(capability);
    this.pendingMermaid.clear();
  }

  private setDesiredRecords(records: AtomicRecord[]): void {
    for (const record of [...this.desiredRecords, ...this.records]) {
      if (!records.some(({ capability }) => capabilitiesEqual(capability, record.capability)))
        record.widget.revoke();
    }
    this.desiredRecords = records;
    this.publishMetrics();
    this.scheduleReconcile();
  }

  private publishMetrics(): void {
    this.onWidgets({
      editorEpoch: this.editorEpoch,
      documentRevision: this.metricsDocumentRevision,
      projectionGeneration: this.metricsProjectionGeneration,
      desired: this.enabled ? Math.min(maxAtomicProjectionRequests, this.desiredRecords.length) : 0,
      mounted: this.records.length,
      richSourceLimit: this.richSourceLimit,
      rendererUnavailable: this.rendererUnavailable,
      staleCapability: this.staleCapability,
      staleCapabilityTotal: this.staleCapabilityTotal,
    });
  }

  private scheduleReconcile(): void {
    if (this.reconcileScheduled || this.destroyed) return;
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
    this.reconcileWatchdog = (targetWindow?.setTimeout.bind(targetWindow) ?? setTimeout)(run, 100);
  }

  private reconcileFrame(): void {
    const batch = reconcileAtomicBatch(this.records, this.desiredRecords, (left, right) =>
      capabilitiesEqual(left.capability, right.capability),
    );
    if (batch.removed > 0 || batch.added > 0) {
      try {
        const decorations = Decoration.set(
          batch.next.map(({ request, widget }) =>
            Decoration.replace({ widget, block: true }).range(request.from, request.to),
          ),
          true,
        );
        this.view.dispatch({
          effects: setAtomicDecorations.of(decorations),
          annotations: atomicProjectionTransaction.of(true),
        });
        this.records = batch.next;
        this.publishMetrics();
      } catch (error) {
        this.clear();
        this.client?.dispose();
        this.client = null;
        const reason = error instanceof Error ? error.message : "unknown decoration error";
        this.onState("disabled", `atomic-decoration:${reason}`);
        return;
      }
    }
    const desired = new Set(this.desiredRecords.map(({ capability }) => capability));
    if (
      this.records.some(({ capability }) => !desired.has(capability)) ||
      this.desiredRecords.some(
        ({ capability }) =>
          !this.records.some((record) => capabilitiesEqual(record.capability, capability)),
      )
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
    for (const record of [...this.records, ...this.desiredRecords]) record.widget.revoke();
    this.records = [];
    this.desiredRecords = [];
    try {
      this.view.dispatch({
        effects: setAtomicDecorations.of(Decoration.none),
        annotations: atomicProjectionTransaction.of(true),
      });
    } catch {
      // EditorView may already be destroyed by page teardown.
    }
  }
}
