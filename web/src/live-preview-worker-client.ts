import { ChangeSet } from "@codemirror/state";
import {
  isProjectionResult,
  maxLivePreviewChanges,
  maxLivePreviewSourceBytes,
  projectionResultIsCurrent,
  utf8Length,
  type ApplyRequest,
  type LivePreviewRequest,
  type LivePreviewResponse,
  type ProjectionResult,
  type SourceChange,
} from "./live-preview-protocol";
import type { AtomicProjectionRequest } from "./atomic-projection";

export type LivePreviewSnapshot = Readonly<{
  editorEpoch: number;
  documentRevision: number;
  projectionGeneration: number;
  source: string;
  requests: readonly AtomicProjectionRequest[];
}>;

export type LivePreviewWorkerState = "running" | "recovering" | "disabled" | "disposed";

export type WorkerPort = {
  postMessage(message: LivePreviewRequest): void;
  terminate(): void;
  onmessage: ((event: MessageEvent<unknown>) => void) | null;
  onerror: ((event: Event) => void) | null;
  onmessageerror: ((event: MessageEvent<unknown>) => void) | null;
};

type Scheduler = Readonly<{
  now: () => number;
  schedule: (callback: () => void, milliseconds: number) => ReturnType<typeof setTimeout>;
  cancel: (handle: ReturnType<typeof setTimeout>) => void;
}>;

type InFlight = Readonly<{
  type: LivePreviewRequest["type"];
  documentRevision: number;
  projectionGeneration: number;
}>;

type PendingApply = {
  type: "apply";
  editorEpoch: number;
  baseRevision: number;
  targetRevision: number;
  changes: ChangeSet;
  insertedByteCount: number;
  projectionGeneration: number;
  requests: readonly AtomicProjectionRequest[];
};

type PendingProject = Readonly<{
  type: "project";
  editorEpoch: number;
  documentRevision: number;
  projectionGeneration: number;
  requests: readonly AtomicProjectionRequest[];
}>;

type Pending = PendingApply | PendingProject;
const maxChangeMetadataBytes = 64 * 1024;
const conservativeChangeMetadataBytes = 64;
const maxChangesPerRequest = Math.min(
  maxLivePreviewChanges,
  maxChangeMetadataBytes / conservativeChangeMetadataBytes,
);

const defaultScheduler: Scheduler = {
  now: () => Date.now(),
  schedule: (callback, milliseconds) => setTimeout(callback, milliseconds),
  cancel: (handle) => clearTimeout(handle),
};

function serializeChanges(changes: ChangeSet): SourceChange[] {
  const serialized: SourceChange[] = [];
  changes.iterChanges((fromA, toA, _fromB, _toB, inserted) => {
    serialized.push({ from: fromA, to: toA, insert: inserted.toString() });
  });
  return serialized;
}

function measureChanges(
  changes: ChangeSet,
): Readonly<{ count: number; insertedBytes: number }> | null {
  let count = 0;
  let bytes = 0;
  let overflow = false;
  changes.iterChanges((_fromA, _toA, _fromB, _toB, inserted) => {
    if (overflow) return;
    count += 1;
    if (count > maxChangesPerRequest) {
      overflow = true;
      return;
    }
    const next = new TextEncoder().encode(inserted.toString()).byteLength;
    if (bytes > maxLivePreviewSourceBytes - next) {
      overflow = true;
      return;
    }
    bytes += next;
  });
  return overflow ? null : { count, insertedBytes: bytes };
}

export class LivePreviewWorkerClient {
  private worker: WorkerPort | null = null;
  private inFlight: InFlight | null = null;
  private pending: Pending | null = null;
  private resyncRequired = false;
  private timeout: ReturnType<typeof setTimeout> | null = null;
  private restart: ReturnType<typeof setTimeout> | null = null;
  private failureTimes: number[] = [];
  private currentDocumentRevision = 0;
  private currentProjectionGeneration = 0;
  private currentEditorEpoch = 0;
  private state: LivePreviewWorkerState = "running";
  private workerEpoch = 0;

  constructor(
    private readonly createWorker: () => WorkerPort,
    private readonly snapshot: () => LivePreviewSnapshot,
    private readonly onProjection: (result: ProjectionResult) => void,
    private readonly onState: (state: LivePreviewWorkerState, reason?: string) => void = () => {},
    private readonly scheduler: Scheduler = defaultScheduler,
    private readonly responseTimeoutMs = 5_000,
    private readonly restartDelayMs = 250,
  ) {}

  start(): void {
    if (this.worker !== null || this.state === "disabled" || this.state === "disposed") return;
    this.createAndSeed();
  }

  submitChanges(
    baseRevision: number,
    targetRevision: number,
    changes: ChangeSet,
    projectionGeneration: number,
    requests: readonly AtomicProjectionRequest[],
  ): void {
    if (this.state === "disabled" || this.state === "disposed") return;
    const previousDocumentRevision = this.currentDocumentRevision;
    this.currentDocumentRevision = targetRevision;
    this.currentProjectionGeneration = projectionGeneration;
    const measurement = measureChanges(changes);
    const expectedBase =
      this.pending?.type === "apply"
        ? this.pending.targetRevision
        : (this.inFlight?.documentRevision ?? previousDocumentRevision);
    if (targetRevision <= baseRevision || baseRevision !== expectedBase || measurement === null) {
      this.requireResync();
      return;
    }
    if (this.pending?.type === "apply") {
      if (this.pending.insertedByteCount > maxLivePreviewSourceBytes - measurement.insertedBytes) {
        this.requireResync();
        return;
      }
      try {
        this.pending.changes = this.pending.changes.compose(changes);
      } catch {
        this.requireResync();
        return;
      }
      const composed = measureChanges(this.pending.changes);
      if (composed === null) {
        this.requireResync();
        return;
      }
      this.pending.targetRevision = targetRevision;
      this.pending.insertedByteCount = composed.insertedBytes;
      this.pending.projectionGeneration = projectionGeneration;
      this.pending.requests = requests;
      return;
    }
    const apply: PendingApply = {
      type: "apply",
      editorEpoch: this.currentEditorEpoch,
      baseRevision,
      targetRevision,
      changes,
      insertedByteCount: measurement.insertedBytes,
      projectionGeneration,
      requests,
    };
    if (this.inFlight === null && this.worker !== null) this.sendApply(apply);
    else this.pending = apply;
  }

  submitProjection(
    documentRevision: number,
    projectionGeneration: number,
    requests: readonly AtomicProjectionRequest[],
  ): void {
    if (this.state === "disabled" || this.state === "disposed") return;
    this.currentDocumentRevision = documentRevision;
    this.currentProjectionGeneration = projectionGeneration;
    if (this.pending?.type === "apply") {
      this.pending.projectionGeneration = projectionGeneration;
      this.pending.requests = requests;
      return;
    }
    // A selection-only generation whose settled atomic records are reusable needs no worker roundtrip. Updating
    // the current identity is sufficient to make an older in-flight result stale at the client boundary.
    if (requests.length === 0) {
      this.pending = null;
      return;
    }
    const project: PendingProject = {
      type: "project",
      editorEpoch: this.currentEditorEpoch,
      documentRevision,
      projectionGeneration,
      requests,
    };
    if (this.inFlight === null && this.worker !== null) this.send(project);
    else this.pending = project;
  }

  dispose(): void {
    if (this.state === "disposed") return;
    this.state = "disposed";
    this.clearTimers();
    this.retireWorker();
    this.worker = null;
    this.inFlight = null;
    this.pending = null;
    this.onState(this.state);
  }

  private createAndSeed(): void {
    const snapshot = this.snapshot();
    if (utf8Length(snapshot.source) > maxLivePreviewSourceBytes) {
      this.disableForSourceCap();
      return;
    }
    this.currentDocumentRevision = snapshot.documentRevision;
    this.currentProjectionGeneration = snapshot.projectionGeneration;
    this.currentEditorEpoch = snapshot.editorEpoch;
    this.state = "running";
    this.onState(this.state);
    let worker: WorkerPort;
    try {
      worker = this.createWorker();
    } catch (error) {
      const reason = error instanceof Error ? error.message : "unknown";
      this.fail(`worker-create:${reason}`);
      return;
    }
    const epoch = (this.workerEpoch += 1);
    worker.onmessage = (event) => {
      if (this.isCurrentWorker(worker, epoch)) this.receive(event.data);
    };
    worker.onerror = (event) => {
      if (this.isCurrentWorker(worker, epoch))
        this.fail(event instanceof ErrorEvent ? `worker-error:${event.message}` : "worker-error");
    };
    worker.onmessageerror = () => {
      if (this.isCurrentWorker(worker, epoch)) this.fail("worker-message-error");
    };
    this.worker = worker;
    this.pending = {
      type: "project",
      editorEpoch: snapshot.editorEpoch,
      documentRevision: snapshot.documentRevision,
      projectionGeneration: snapshot.projectionGeneration,
      requests: snapshot.requests,
    };
    this.send({
      type: "seed",
      editorEpoch: snapshot.editorEpoch,
      documentRevision: snapshot.documentRevision,
      source: snapshot.source,
    });
  }

  private receive(value: unknown): void {
    if (this.inFlight === null || this.state !== "running") return;
    if (
      typeof value === "object" &&
      value !== null &&
      "type" in value &&
      (value as LivePreviewResponse).type === "failure"
    ) {
      this.fail("worker-failure");
      return;
    }
    if (!isProjectionResult(value)) {
      this.fail("invalid-worker-result");
      return;
    }
    if (
      value.documentRevision !== this.inFlight.documentRevision ||
      value.projectionGeneration !== this.inFlight.projectionGeneration
    ) {
      return;
    }
    this.clearResponseTimeout();
    this.inFlight = null;
    if (
      projectionResultIsCurrent(
        value,
        this.currentEditorEpoch,
        this.currentDocumentRevision,
        this.currentProjectionGeneration,
      )
    ) {
      this.onProjection(value);
    }
    this.sendNext();
  }

  private sendNext(): void {
    if (this.worker === null || this.inFlight !== null) return;
    if (this.resyncRequired) {
      this.resyncRequired = false;
      const snapshot = this.snapshot();
      if (utf8Length(snapshot.source) > maxLivePreviewSourceBytes) {
        this.disableForSourceCap();
        return;
      }
      this.pending = {
        type: "project",
        editorEpoch: snapshot.editorEpoch,
        documentRevision: snapshot.documentRevision,
        projectionGeneration: snapshot.projectionGeneration,
        requests: snapshot.requests,
      };
      this.currentEditorEpoch = snapshot.editorEpoch;
      this.send({
        type: "seed",
        editorEpoch: snapshot.editorEpoch,
        documentRevision: snapshot.documentRevision,
        source: snapshot.source,
      });
      return;
    }
    const pending = this.pending;
    this.pending = null;
    if (pending?.type === "apply") this.sendApply(pending);
    else if (pending !== null) this.send(pending);
  }

  private sendApply(pending: PendingApply): void {
    const request: ApplyRequest = {
      type: "apply",
      baseRevision: pending.baseRevision,
      targetRevision: pending.targetRevision,
      changes: serializeChanges(pending.changes),
      editorEpoch: pending.editorEpoch,
      projectionGeneration: pending.projectionGeneration,
      requests: pending.requests,
    };
    this.send(request);
  }

  private send(request: LivePreviewRequest): void {
    const worker = this.worker;
    if (worker === null || this.inFlight !== null) return;
    const documentRevision =
      request.type === "apply" ? request.targetRevision : request.documentRevision;
    const projectionGeneration = request.type === "seed" ? 0 : request.projectionGeneration;
    this.inFlight = { type: request.type, documentRevision, projectionGeneration };
    try {
      worker.postMessage(request);
    } catch (error) {
      const reason = error instanceof Error ? error.message : "unknown";
      this.fail(`worker-post:${reason}`);
      return;
    }
    const epoch = this.workerEpoch;
    this.timeout = this.scheduler.schedule(() => {
      if (this.isCurrentWorker(worker, epoch)) this.fail("worker-timeout");
    }, this.responseTimeoutMs);
  }

  private requireResync(): void {
    this.pending = null;
    this.resyncRequired = true;
    if (this.inFlight === null) this.sendNext();
  }

  private fail(reason: string): void {
    if (this.state === "disabled" || this.state === "disposed") return;
    this.clearResponseTimeout();
    this.retireWorker();
    this.worker = null;
    this.inFlight = null;
    this.pending = null;
    this.resyncRequired = false;
    const now = this.scheduler.now();
    this.failureTimes = this.failureTimes.filter((time) => now - time < 60_000);
    this.failureTimes.push(now);
    if (this.failureTimes.length >= 3) {
      this.state = "disabled";
      this.onState(this.state, reason.slice(0, 256));
      return;
    }
    this.state = "recovering";
    this.onState(this.state, reason.slice(0, 256));
    this.restart = this.scheduler.schedule(() => {
      this.restart = null;
      if (this.state === "recovering") this.createAndSeed();
    }, this.restartDelayMs);
  }

  private clearResponseTimeout(): void {
    if (this.timeout !== null) this.scheduler.cancel(this.timeout);
    this.timeout = null;
  }

  private clearTimers(): void {
    this.clearResponseTimeout();
    if (this.restart !== null) this.scheduler.cancel(this.restart);
    this.restart = null;
  }

  private disableForSourceCap(): void {
    this.clearTimers();
    this.retireWorker();
    this.worker = null;
    this.inFlight = null;
    this.pending = null;
    this.resyncRequired = false;
    this.state = "disabled";
    this.onState(this.state, "source-cap-exceeded");
  }

  private isCurrentWorker(worker: WorkerPort, epoch: number): boolean {
    return this.worker === worker && this.workerEpoch === epoch;
  }

  private retireWorker(): void {
    const worker = this.worker;
    if (worker === null) return;
    worker.onmessage = null;
    worker.onerror = null;
    worker.onmessageerror = null;
    worker.terminate();
  }
}
