import { EditorSelection, Text } from "@codemirror/state";
import { forceParsing } from "@codemirror/language";
import type { ViewUpdate } from "@codemirror/view";
import { JSDOM } from "jsdom";
import { createMarkdownEditor } from "../src/editor";
import { EditableProjectionController } from "../src/editable-projection-view";
import {
  createLivePreviewDiagnosticsSnapshot,
  projectionFallbackReasons,
} from "../src/live-preview-diagnostics";
import { maxLivePreviewProjectionCodeUnits } from "../src/live-preview-protocol";
import {
  maxLivePreviewProjectionEntries,
  maxLivePreviewTableCells,
} from "../src/live-preview-projection";
import { startMathDelimiterScanProbe } from "../src/markdown-language";
import { EditorRevisionClock } from "../src/live-preview-state";
import type { LivePreviewPerfCounters } from "./live-preview-perf-model";
import { buildEditableProjection } from "../src/editable-projection";
import {
  LivePreviewIntentCoordinator,
  maxRetainedLivePreviewIntents,
  type LivePreviewDispatchResult,
} from "../src/live-preview-interaction";
import type { EditorInteractionGuard, LivePreviewIntent } from "../src/live-preview-intent";
import { isLinkActivation, requestFileBridge, viewerChannel } from "../src/viewer";
import {
  maxAtomicProjectionRequests,
  maxAtomicSourceBytes,
  startAtomicSourceHashProbe,
} from "../src/atomic-projection";
import { projectAtomicRequests } from "../src/project-atomic";
import { AtomicProjectionController } from "../src/live-preview-editor";
import {
  applySourceChangesBounded,
  utf8Length,
  type LivePreviewRequest,
  type ProjectionResult,
} from "../src/live-preview-protocol";
import { atomicRendererChannel } from "../src/renderer-capability";

type CopyProbe = Readonly<{ stop: () => number }>;

function runAtomicProjectionProbe() {
  const sources = [
    { kind: "image" as const, source: "![x](image.png)" },
    { kind: "math" as const, source: "$x^2$" },
    {
      kind: "fenced-code" as const,
      source: `\`\`\`\n${"x".repeat(maxAtomicSourceBytes["fenced-code"] - 8)}\n\`\`\``,
    },
    { kind: "mermaid" as const, source: "```mermaid\nflowchart TD\n  A --> B\n```" },
  ];
  let results = 0;
  let assetGrants = 0;
  let hashedBytesMax = 0;
  let resultPayloadBytes = 0;
  for (const [index, candidate] of sources.entries()) {
    const request = {
      editorEpoch: 1,
      documentRevision: 0,
      projectionGeneration: 1,
      requestNonce: index + 1,
      kind: candidate.kind,
      from: 0,
      to: candidate.source.length,
    } as const;
    const batch = projectAtomicRequests(candidate.source, [request]);
    results += batch.results.length;
    assetGrants += batch.results.reduce((sum, result) => sum + result.assetGrants.length, 0);
    hashedBytesMax = Math.max(hashedBytesMax, batch.hashedBytes);
    resultPayloadBytes += batch.results.reduce(
      (sum, result) => sum + new TextEncoder().encode(result.sanitizedPayload).byteLength,
      0,
    );
  }
  const over = `${sources[2]!.source}x`;
  const overBatch = projectAtomicRequests(over, [
    {
      editorEpoch: 1,
      documentRevision: 0,
      projectionGeneration: 1,
      requestNonce: 4,
      kind: "fenced-code",
      from: 0,
      to: over.length,
    },
  ]);
  const mermaid = sources[3]!;
  const mermaidRequest = {
    editorEpoch: 1,
    documentRevision: 0,
    projectionGeneration: 1,
    requestNonce: 5,
    kind: "mermaid" as const,
    from: 0,
    to: mermaid.source.length,
  };
  const mermaidBatch = projectAtomicRequests(mermaid.source, [mermaidRequest]);
  const oversizedMermaid = "x".repeat(maxAtomicSourceBytes.mermaid + 1);
  const oversizedMermaidBatch = projectAtomicRequests(oversizedMermaid, [
    { ...mermaidRequest, requestNonce: 6, to: oversizedMermaid.length },
  ]);
  const batchParts = Array.from(
    { length: maxAtomicProjectionRequests },
    (_, index) =>
      `\`\`\`\n${String(index).repeat(maxAtomicSourceBytes["fenced-code"] - 8)}\n\`\`\``,
  );
  const batchSource = batchParts.join("\n");
  let offset = 0;
  const batchRequests = batchParts.map((part, index) => {
    const request = {
      editorEpoch: 1,
      documentRevision: 0,
      projectionGeneration: 1,
      requestNonce: index + 10,
      kind: "fenced-code" as const,
      from: offset,
      to: offset + part.length,
    };
    offset += part.length + 1;
    return request;
  });
  const exactBatch = projectAtomicRequests(batchSource, batchRequests);
  if (exactBatch.results.length + exactBatch.rejected.length !== maxAtomicProjectionRequests)
    throw new Error("atomic batch probe did not produce one terminal outcome per request");
  return {
    atomic_requests: sources.length,
    atomic_results: results,
    atomic_asset_grants: assetGrants,
    atomic_worker_hashed_bytes_max: hashedBytesMax,
    atomic_worker_hashed_bytes_batch_max: exactBatch.hashedBytes,
    atomic_result_payload_bytes: resultPayloadBytes,
    atomic_cap_plus_one_hashed_bytes: overBatch.hashedBytes,
    mermaid_requests: mermaidBatch.results.length,
    mermaid_worker_hashed_bytes: mermaidBatch.hashedBytes,
    mermaid_cap_plus_one_hashed_bytes: oversizedMermaidBatch.hashedBytes,
  };
}

class PerfAtomicWorker {
  static latest: PerfAtomicWorker | null = null;
  static instances: PerfAtomicWorker[] = [];
  static projectedRequests = 0;
  readonly sent: LivePreviewRequest[] = [];
  onmessage: ((event: MessageEvent<unknown>) => void) | null = null;
  onerror: ((event: Event) => void) | null = null;
  onmessageerror: ((event: MessageEvent<unknown>) => void) | null = null;
  private source = "";
  private sourceBytes = 0;
  private documentRevision = 0;

  constructor(_url: string) {
    PerfAtomicWorker.latest = this;
    PerfAtomicWorker.instances.push(this);
  }

  static reset(): void {
    PerfAtomicWorker.latest = null;
    PerfAtomicWorker.instances = [];
    PerfAtomicWorker.projectedRequests = 0;
  }

  postMessage(message: LivePreviewRequest): void {
    this.sent.push(message);
    // The fake executes in the test realm, unlike a real Worker. Snapshot its Seed before the main-thread input
    // probe starts so worker-owned UTF-8 accounting is not misattributed to the shell hot path.
    if (message.type === "seed") {
      this.source = message.source;
      this.sourceBytes = utf8Length(this.source);
      this.documentRevision = message.documentRevision;
    }
    queueMicrotask(() => {
      let result: ProjectionResult;
      if (message.type === "seed") {
        result = {
          type: "result",
          editorEpoch: message.editorEpoch,
          documentRevision: message.documentRevision,
          projectionGeneration: 0,
          results: [],
          rejected: [],
        };
      } else {
        if (message.type === "apply") {
          const next = applySourceChangesBounded(this.source, this.sourceBytes, message.changes);
          if (next === null) throw new Error("atomic perf probe received an invalid Apply");
          this.source = next.source;
          this.sourceBytes = next.sourceBytes;
          this.documentRevision = message.targetRevision;
        }
        PerfAtomicWorker.projectedRequests += message.requests.length;
        const batch = projectAtomicRequests(this.source, message.requests);
        result = {
          type: "result",
          editorEpoch: message.editorEpoch,
          documentRevision: this.documentRevision,
          projectionGeneration: message.projectionGeneration,
          results: batch.results,
          rejected: batch.rejected,
        };
      }
      this.onmessage?.({ data: result } as MessageEvent<unknown>);
    });
  }

  terminate(): void {}
}

class ManualAtomicWorker {
  static latest: ManualAtomicWorker | null = null;
  readonly sent: LivePreviewRequest[] = [];
  onmessage: ((event: MessageEvent<unknown>) => void) | null = null;
  onerror: ((event: Event) => void) | null = null;
  onmessageerror: ((event: MessageEvent<unknown>) => void) | null = null;

  constructor(_url: string) {
    ManualAtomicWorker.latest = this;
  }

  postMessage(message: LivePreviewRequest): void {
    this.sent.push(message);
  }

  reply(result: ProjectionResult): void {
    this.onmessage?.({ data: result } as MessageEvent<unknown>);
  }

  terminate(): void {}
}

async function settleMicrotasks(): Promise<void> {
  for (let turn = 0; turn < 8; turn += 1) await Promise.resolve();
}

async function runMermaidControllerProbe(dom: JSDOM) {
  ManualAtomicWorker.latest = null;
  const host = dom.window.document.createElement("aside");
  dom.window.document.body.append(host);
  const fence = "```mermaid\nflowchart TD\n  A --> B\n```";
  const initialSource = `${fence}\n\nplain`;
  const entry = { type: "atomic" as const, role: "mermaid" as const, from: 0, to: fence.length };
  const revisions = new EditorRevisionClock();
  let controller: AtomicProjectionController | null = null;
  let nativeRequests = 0;
  let mainReceivedSourceBytes = 0;
  const editor = createMarkdownEditor(
    host,
    initialSource,
    (update) => {
      const baseRevision = revisions.documentRevision;
      if (update.docChanged) revisions.documentChanged();
      controller?.handleUpdate(update, baseRevision, revisions.documentRevision);
    },
    () => {},
  );
  controller = new AtomicProjectionController(
    editor,
    93,
    revisions,
    ManualAtomicWorker as unknown as typeof Worker,
    async () => null,
    () => {},
    () => {},
    () => {},
    async (_capability, _fenceId, _sourceHash, source) => {
      nativeRequests += 1;
      mainReceivedSourceBytes += new TextEncoder().encode(source).byteLength;
      return '<svg xmlns="http://www.w3.org/2000/svg"><text>mermaid</text></svg>';
    },
  );
  try {
    let identity = revisions.nextProjection();
    controller.submitEntries(identity.documentRevision, identity.projectionGeneration, [entry]);
    controller.enable();
    const worker = ManualAtomicWorker.latest;
    if (worker === null) throw new Error("Mermaid perf worker was not created");
    worker.reply({
      type: "result",
      editorEpoch: 93,
      documentRevision: 0,
      projectionGeneration: 0,
      results: [],
      rejected: [],
    });
    const project = worker.sent.at(-1);
    if (project?.type !== "project" || project.requests[0] === undefined)
      throw new Error("Mermaid perf initial project was not sent");
    const sourceHash = "d".repeat(64);
    const mainHashProbe = startAtomicSourceHashProbe();
    worker.reply({
      type: "result",
      editorEpoch: 93,
      documentRevision: 0,
      projectionGeneration: identity.projectionGeneration,
      results: [
        {
          request: project.requests[0],
          sourceHash,
          sanitizedPayload: "",
          assetGrants: [],
          mermaidSource: fence,
        },
      ],
      rejected: [],
    });
    await settleMicrotasks();
    const firstMetrics = controller.mermaidCacheMetrics();

    editor.dispatch({ changes: { from: editor.state.doc.length, insert: "!" } });
    identity = revisions.nextProjection();
    controller.submitEntries(identity.documentRevision, identity.projectionGeneration, [entry]);
    const apply = worker.sent.at(-1);
    if (apply?.type !== "apply" || apply.requests[0] === undefined)
      throw new Error("Mermaid perf unrelated edit did not use Apply");
    worker.reply({
      type: "result",
      editorEpoch: 93,
      documentRevision: identity.documentRevision,
      projectionGeneration: identity.projectionGeneration,
      results: [
        {
          request: apply.requests[0],
          sourceHash,
          sanitizedPayload: "",
          assetGrants: [],
          mermaidSource: fence,
        },
      ],
      rejected: [],
    });
    await settleMicrotasks();
    const secondMetrics = controller.mermaidCacheMetrics();
    const mermaidMainHashedBytes = mainHashProbe.stop();
    controller.disable();
    const disabledMetrics = controller.mermaidCacheMetrics();
    return {
      mermaid_main_hashed_bytes: mermaidMainHashedBytes,
      mermaid_main_received_source_bytes: mainReceivedSourceBytes,
      mermaid_native_requests: nativeRequests,
      mermaid_native_requests_after_unrelated_edit: nativeRequests,
      mermaid_cache_entries_max: Math.max(firstMetrics.entries, secondMetrics.entries),
      mermaid_cache_source_bytes_max: Math.max(firstMetrics.sourceBytes, secondMetrics.sourceBytes),
      mermaid_cache_svg_code_units_max: Math.max(
        firstMetrics.svgCodeUnits,
        secondMetrics.svgCodeUnits,
      ),
      mermaid_cache_entries_after_disable: disabledMetrics.entries,
      mermaid_cache_svg_code_units_after_disable: disabledMetrics.svgCodeUnits,
    };
  } finally {
    controller.destroy();
    editor.destroy();
    host.remove();
  }
}

async function settleAtomicFrames(dom: JSDOM, editor: ReturnType<typeof createMarkdownEditor>) {
  const frames = [...editor.dom.querySelectorAll<HTMLIFrameElement>(".maru-live-atomic-frame")];
  for (const frame of frames) {
    if (frame.dataset.atomicRendered === "true") continue;
    let rendererPort: MessagePort | null = null;
    let capability: unknown = null;
    if (frame.contentWindow !== null) {
      frame.contentWindow.postMessage = ((
        message: unknown,
        _target: string,
        ports?: Transferable[],
      ) => {
        capability = (message as { capability?: unknown }).capability;
        rendererPort = (ports?.[0] as MessagePort | undefined) ?? null;
      }) as typeof frame.contentWindow.postMessage;
    }
    dom.window.dispatchEvent(
      new dom.window.MessageEvent("message", {
        source: frame.contentWindow,
        data: { channel: atomicRendererChannel, type: "atomic-boot" },
      }),
    );
    if (rendererPort === null)
      throw new Error("atomic perf iframe did not receive a renderer port");
    rendererPort.onmessage = (event) => {
      if ((event.data as { type?: string }).type !== "atomic-render") return;
      rendererPort?.postMessage({
        channel: atomicRendererChannel,
        type: "atomic-rendered",
        capability,
        height: 32,
      });
      rendererPort?.close();
    };
    rendererPort.start();
    rendererPort.postMessage({
      channel: atomicRendererChannel,
      type: "atomic-ready",
      capability,
    });
  }
  for (
    let turn = 0;
    turn < 10 && frames.some((frame) => frame.dataset.atomicRendered !== "true");
    turn += 1
  )
    await new Promise((resolve) => dom.window.setTimeout(resolve, 0));
  if (frames.some((frame) => frame.dataset.atomicRendered !== "true"))
    throw new Error("atomic perf iframe did not reach terminal rendered state");
}

async function runAtomicControllerProbe(dom: JSDOM) {
  PerfAtomicWorker.reset();
  const host = dom.window.document.createElement("aside");
  dom.window.document.body.append(host);
  const sources = Array.from(
    { length: maxAtomicProjectionRequests * 2 },
    (_, index) => `![image-${index}](image-${index}.png)`,
  );
  const source = sources.join("\n\n");
  const entries = sources.map((item, index) => {
    const from = sources.slice(0, index).reduce((sum, value) => sum + value.length + 2, 0);
    return { type: "atomic" as const, role: "image" as const, from, to: from + item.length };
  });
  const editor = createMarkdownEditor(
    host,
    source,
    () => {},
    () => {},
  );
  const revisions = new EditorRevisionClock();
  const identity = revisions.nextProjection();
  let assetReads = 0;
  const controller = new AtomicProjectionController(
    editor,
    91,
    revisions,
    PerfAtomicWorker as unknown as typeof Worker,
    async () => {
      assetReads += 1;
      return "data:image/png;base64,iVBORw0KGgo=";
    },
  );
  let pendingCreated = 0;
  let pendingDestroyed = 0;
  const observer = new dom.window.MutationObserver((records) => {
    for (const record of records) {
      for (const node of record.addedNodes) pendingCreated += countIframesInNode(dom, node);
      for (const node of record.removedNodes) pendingDestroyed += countIframesInNode(dom, node);
    }
  });
  observer.observe(editor.dom, { childList: true, subtree: true });
  let createMax = 0;
  let destroyMax = 0;
  let mountedMax = 0;
  const sampleFrame = async () => {
    await new Promise<void>((resolve) => dom.window.requestAnimationFrame(() => resolve()));
    await Promise.resolve();
    createMax = Math.max(createMax, pendingCreated);
    destroyMax = Math.max(destroyMax, pendingDestroyed);
    pendingCreated = 0;
    pendingDestroyed = 0;
    mountedMax = Math.max(
      mountedMax,
      editor.dom.querySelectorAll(".maru-live-atomic-frame").length,
    );
  };
  try {
    controller.submitEntries(
      identity.documentRevision,
      identity.projectionGeneration,
      entries.slice(0, 8),
    );
    controller.enable();
    for (let frame = 0; frame < 12; frame += 1) await sampleFrame();
    await settleAtomicFrames(dom, editor);
    const initialFrames = [...editor.dom.querySelectorAll(".maru-live-atomic-frame")];
    const workerMessages = PerfAtomicWorker.latest?.sent.length ?? 0;
    const initialAssetReads = assetReads;
    for (let selection = 0; selection < 100; selection += 1) {
      const next = revisions.nextProjection();
      controller.submitEntries(
        next.documentRevision,
        next.projectionGeneration,
        entries.slice(0, 8),
      );
    }
    await sampleFrame();
    if (
      (PerfAtomicWorker.latest?.sent.length ?? 0) !== workerMessages ||
      assetReads !== initialAssetReads ||
      initialFrames.some((frame) => !editor.dom.contains(frame))
    )
      throw new Error("selection-only projection churned a sealed atomic widget");

    const replacement = revisions.nextProjection();
    controller.submitEntries(
      replacement.documentRevision,
      replacement.projectionGeneration,
      entries.slice(8, 16),
    );
    for (let frame = 0; frame < 12; frame += 1) await sampleFrame();
    if (createMax > 2 || destroyMax > 2 || mountedMax > maxAtomicProjectionRequests)
      throw new Error("atomic controller exceeded its per-frame iframe budget");
    return {
      atomic_mounted_max: mountedMax,
      atomic_iframe_create_max_per_frame: createMax,
      atomic_iframe_destroy_max_per_frame: destroyMax,
    };
  } finally {
    observer.disconnect();
    controller.destroy();
    editor.destroy();
    host.remove();
  }
}

async function waitAtomicTurns(dom: JSDOM, turns = 8): Promise<void> {
  for (let turn = 0; turn < turns; turn += 1) {
    await Promise.resolve();
    await new Promise<void>((resolve) => dom.window.requestAnimationFrame(() => resolve()));
  }
}

async function runAtomicFacadeRetentionProbe(dom: JSDOM) {
  PerfAtomicWorker.reset();
  const host = dom.window.document.createElement("aside");
  dom.window.document.body.append(host);
  const source = `![near](near.png)\n\n${"plain text\n".repeat(180)}\n![far](far.png)`;
  const revisions = new EditorRevisionClock();
  let editable: EditableProjectionController | null = null;
  let atomic: AtomicProjectionController | null = null;
  let viewport = { from: 0, to: 100 };
  let assetReads = 0;
  const editor = createMarkdownEditor(
    host,
    source,
    (update) => {
      const baseRevision = revisions.documentRevision;
      if (update.docChanged) revisions.documentChanged();
      atomic?.handleUpdate(update, baseRevision, revisions.documentRevision);
      editable?.handleUpdate(update);
    },
    () => {},
  );
  Object.defineProperty(editor, "viewport", {
    configurable: true,
    get: () => viewport,
  });
  editor.dispatch({ selection: EditorSelection.cursor(30) });
  atomic = new AtomicProjectionController(
    editor,
    92,
    revisions,
    PerfAtomicWorker as unknown as typeof Worker,
    async () => {
      assetReads += 1;
      return "data:image/png;base64,iVBORw0KGgo=";
    },
  );
  editable = new EditableProjectionController(editor, 92, revisions, ({ atomicEntries }) => {
    const identity = editable?.interactionIdentity();
    if (identity !== undefined)
      atomic?.submitEntries(
        identity.documentRevision,
        identity.projectionGeneration,
        atomicEntries,
      );
  });
  try {
    atomic.enable();
    editable.enable();
    await waitAtomicTurns(dom);
    await settleAtomicFrames(dom, editor);
    const initialFrame = editor.dom.querySelector<HTMLIFrameElement>(".maru-live-atomic-frame");
    if (initialFrame === null) throw new Error("atomic facade did not mount its visible image");
    const initialMessages = PerfAtomicWorker.instances.reduce(
      (sum, worker) => sum + worker.sent.length,
      0,
    );
    const initialAssetReads = assetReads;
    for (let selection = 0; selection < 100; selection += 1) {
      editor.dispatch({ selection: EditorSelection.cursor(30 + (selection % 2)) });
    }
    await waitAtomicTurns(dom, 2);
    const afterSelectionMessages = PerfAtomicWorker.instances.reduce(
      (sum, worker) => sum + worker.sent.length,
      0,
    );
    if (
      afterSelectionMessages !== initialMessages ||
      assetReads !== initialAssetReads ||
      !editor.dom.contains(initialFrame)
    )
      throw new Error("product selection path churned a sealed atomic widget");

    // The deterministic viewport getter stands in for WebKit layout while the actual CM6 scroll transaction and
    // both product controllers own discovery, retention, worker admission, and decoration lifetime.
    viewport = { from: 150, to: 250 };
    editor.dispatch({ selection: EditorSelection.cursor(200), scrollIntoView: true });
    await waitAtomicTurns(dom, 2);
    if (!editor.dom.contains(initialFrame))
      throw new Error("atomic widget was not retained inside the two-viewport hysteresis");

    const generatedBeforeOutsideMove = PerfAtomicWorker.projectedRequests;
    viewport = { from: 700, to: 800 };
    editor.dispatch({ selection: EditorSelection.cursor(750), scrollIntoView: true });
    await waitAtomicTurns(dom, 4);
    const generatedOutsideRetention =
      PerfAtomicWorker.projectedRequests - generatedBeforeOutsideMove;
    if (generatedOutsideRetention !== 0)
      throw new Error("atomic payload was generated outside the retention window");
    if (editor.dom.contains(initialFrame))
      throw new Error("atomic widget survived outside the retention window");

    viewport = { from: 0, to: 100 };
    editor.dispatch({ selection: EditorSelection.cursor(30), scrollIntoView: true });
    await waitAtomicTurns(dom, 4);
    const regeneratedAfterReentry = PerfAtomicWorker.projectedRequests - generatedBeforeOutsideMove;
    if (regeneratedAfterReentry <= 0 || regeneratedAfterReentry > maxAtomicProjectionRequests)
      throw new Error(
        `atomic widget regeneration was not bounded: count=${regeneratedAfterReentry}`,
      );
    return { atomic_generated_outside_retention: generatedOutsideRetention };
  } finally {
    editable.destroy();
    atomic.destroy();
    editor.destroy();
    host.remove();
  }
}

function countIframesInNode(dom: JSDOM, node: Node): number {
  if (!(node instanceof dom.window.Element)) return 0;
  return Number(node.matches("iframe")) + node.querySelectorAll("iframe").length;
}

/** Counts only document-scale copies; bounded inserted text and viewport slices are intentionally excluded. */
export function startDocumentCopyProbe(): CopyProbe {
  const prototype = Text.prototype as Text & {
    toString: () => string;
    sliceString: (from?: number, to?: number, lineSep?: string) => string;
  };
  const originalToString = prototype.toString;
  const originalSliceString = prototype.sliceString;
  const originalEncode = TextEncoder.prototype.encode;
  let copiedBytes = 0;
  prototype.toString = function (this: Text) {
    if (this.length > maxLivePreviewProjectionCodeUnits) copiedBytes += this.length * 2;
    return originalToString.call(this);
  };
  prototype.sliceString = function (this: Text, from = 0, to = this.length, lineSep?: string) {
    if (to - from > maxLivePreviewProjectionCodeUnits) copiedBytes += (to - from) * 2;
    return originalSliceString.call(this, from, to, lineSep);
  };
  TextEncoder.prototype.encode = function (input = "") {
    if (input.length > maxLivePreviewProjectionCodeUnits) copiedBytes += input.length * 2;
    return originalEncode.call(this, input);
  };
  return {
    stop: () => {
      prototype.toString = originalToString;
      prototype.sliceString = originalSliceString;
      TextEncoder.prototype.encode = originalEncode;
      return copiedBytes;
    },
  };
}

function installDom(dom: JSDOM): () => void {
  const rangePrototype = dom.window.Range.prototype as Range & {
    getClientRects?: () => DOMRectList;
    getBoundingClientRect?: () => DOMRect;
  };
  if (rangePrototype.getClientRects === undefined)
    rangePrototype.getClientRects = () => [] as unknown as DOMRectList;
  if (rangePrototype.getBoundingClientRect === undefined)
    rangePrototype.getBoundingClientRect = () => new dom.window.DOMRect(0, 0, 0, 0);
  const previous = new Map<string, PropertyDescriptor | undefined>();
  const globals: Array<[string, unknown]> = [
    ["window", dom.window],
    ["Window", dom.window.Window],
    ["document", dom.window.document],
    ["navigator", dom.window.navigator],
    ["MutationObserver", dom.window.MutationObserver],
    ["DOMRect", dom.window.DOMRect],
    ["requestAnimationFrame", dom.window.requestAnimationFrame.bind(dom.window)],
    ["cancelAnimationFrame", dom.window.cancelAnimationFrame.bind(dom.window)],
  ];
  for (const [name, value] of globals) {
    previous.set(name, Object.getOwnPropertyDescriptor(globalThis, name));
    Object.defineProperty(globalThis, name, { configurable: true, writable: true, value });
  }
  return () => {
    for (const [name, descriptor] of previous) {
      if (descriptor === undefined) delete (globalThis as Record<string, unknown>)[name];
      else Object.defineProperty(globalThis, name, descriptor);
    }
    dom.window.close();
  };
}

async function runTableInteractionProbe(dom: JSDOM): Promise<
  Readonly<{
    table_intent_events: number;
    table_cm6_transactions: number;
    table_source_transactions: number;
    table_appended_rows: number;
    table_zero_effect_rejections: number;
    table_cell_cap: number;
    table_cap_plus_one_transactions: number;
    table_multirange_transactions: number;
    table_context_record_checks: number;
    table_context_cells_retained_max: number;
    table_queue_max_retained: number;
    table_external_actions: number;
    table_bridge_calls: number;
    table_iframe_create: number;
    table_iframe_destroy: number;
    table_copied_bytes: number;
    table_event_record_checks_max: number;
    table_projection_record_count: number;
    table_non_table_record_count: number;
    table_projection_record_checks_max: number;
    table_group_build_record_checks_max: number;
    table_group_cell_arrays_created_max: number;
  }>
> {
  const host = dom.window.document.createElement("aside");
  const capHost = dom.window.document.createElement("aside");
  dom.window.document.body.append(host, capHost);
  const source = "| A | B |\n| - | - |\n| c | d |";
  const revisions = new EditorRevisionClock();
  let controller: EditableProjectionController | null = null;
  let sourceTransactions = 0;
  const editor = createMarkdownEditor(
    host,
    source,
    (update) => {
      if (update.docChanged) {
        revisions.documentChanged();
        sourceTransactions += 1;
      }
      controller?.handleUpdate(update);
    },
    () => {},
  );
  const results: LivePreviewDispatchResult[] = [];
  let maxCellsRetained = 0;
  let maxEventRecordChecks = 0;
  let maxProjectionRecordChecks = 0;
  let maxGroupBuildRecordChecks = 0;
  let maxGroupCellArraysCreated = 0;
  let bridgeCalls = 0;
  let documentQueue = Promise.resolve();
  const scheduleDocumentOperation = <T>(operation: () => T): Promise<T> => {
    const scheduled = documentQueue.then(operation);
    documentQueue = scheduled.then(
      () => undefined,
      () => undefined,
    );
    return scheduled;
  };
  controller = new EditableProjectionController(editor, 1, revisions);
  controller.enable();
  const coordinator = new LivePreviewIntentCoordinator({
    scheduleDocumentOperation,
    currentContext: (intent) => {
      if (controller === null) return null;
      const identity = controller.interactionIdentity();
      const interaction = controller.interactionContextForIntent(intent);
      maxCellsRetained = Math.max(maxCellsRetained, interaction.currentTableCells.length);
      return {
        view: editor,
        guard: {
          ...identity,
          mode: "live-preview",
          closeLockRequestId: null,
          composing: false,
          readonly: false,
        },
        currentEntry: interaction.currentEntry,
        currentTableCells: interaction.currentTableCells,
      };
    },
    hrefAllowed: () => false,
    openExternalAction: async () => {
      bridgeCalls += 1;
    },
    onDispatch: (result) => results.push(result),
  });
  const keyEvent = (key: "Tab" | "Enter", shiftKey = false) => ({
    key,
    shiftKey,
    metaKey: false,
    ctrlKey: false,
    altKey: false,
    trusted: true,
    composing: false,
    repeat: false,
  });
  const enqueueKey = async (key: "Tab" | "Enter", shiftKey = false): Promise<void> => {
    if (controller === null) throw new Error("table perf controller missing");
    const metricsBefore = controller.metrics();
    const capture = controller.tableKeyCapture(keyEvent(key, shiftKey));
    if (!capture.owned || capture.intent === null)
      throw new Error("table perf key capture bypassed the product resolver");
    const completed = coordinator.metrics().completed;
    if (!coordinator.enqueue(capture.intent))
      throw new Error("table perf coordinator rejected an in-cap intent");
    for (let turn = 0; turn < 20 && coordinator.metrics().completed === completed; turn += 1)
      await Promise.resolve();
    if (coordinator.metrics().completed !== completed + 1)
      throw new Error("table perf coordinator did not complete an intent");
    maxEventRecordChecks = Math.max(
      maxEventRecordChecks,
      controller.metrics().interactionRangeChecks - metricsBefore.interactionRangeChecks,
    );
    maxProjectionRecordChecks = Math.max(
      maxProjectionRecordChecks,
      controller.metrics().diffedDecorations - metricsBefore.diffedDecorations,
    );
    maxGroupBuildRecordChecks = Math.max(
      maxGroupBuildRecordChecks,
      controller.metrics().tableGroupBuildRecordChecks - metricsBefore.tableGroupBuildRecordChecks,
    );
    maxGroupCellArraysCreated = Math.max(
      maxGroupCellArraysCreated,
      controller.metrics().tableGroupCellArraysCreated - metricsBefore.tableGroupCellArraysCreated,
    );
  };

  const capColumns = maxLivePreviewTableCells / 2;
  const nonTableEntryCount = maxLivePreviewProjectionEntries - maxLivePreviewTableCells;
  if (nonTableEntryCount % 3 !== 0)
    throw new Error("table perf exact-entry fixture is not divisible into emphasis records");
  const capPrefix = "*x* ".repeat(nonTableEntryCount / 3);
  const capHeader = `| ${Array.from({ length: capColumns }, (_, index) => `h${index}`).join(" | ")} |`;
  const capDelimiter = `| ${Array.from({ length: capColumns }, () => "---").join(" | ")} |`;
  const capData = `| ${Array.from({ length: capColumns }, () => "x").join(" | ")} |`;
  const capTable = `${capHeader}\n${capDelimiter}\n${capData}`;
  const capTableFrom = capPrefix.length + 2;
  const capLastCellPosition =
    capTableFrom + capHeader.length + 1 + capDelimiter.length + 1 + capData.lastIndexOf("x");
  const capSource = `${capPrefix}\n\n${capTable}`;
  const capRevisions = new EditorRevisionClock();
  let capController: EditableProjectionController | null = null;
  const capEditor = createMarkdownEditor(
    capHost,
    capSource,
    (update) => {
      if (update.docChanged) capRevisions.documentChanged();
      capController?.handleUpdate(update);
    },
    () => {},
  );
  capEditor.dispatch({ selection: EditorSelection.cursor(capLastCellPosition) });
  if (!forceParsing(capEditor, capEditor.state.doc.length, 1_000))
    throw new Error("table perf exact-entry syntax fixture did not prewarm");
  capController = new EditableProjectionController(capEditor, 2, capRevisions);
  capController.enable();
  const capResults: LivePreviewDispatchResult[] = [];
  const capCoordinator = new LivePreviewIntentCoordinator({
    scheduleDocumentOperation: async (operation) => operation(),
    currentContext: (intent) => {
      if (capController === null) return null;
      const identity = capController.interactionIdentity();
      const interaction = capController.interactionContextForIntent(intent);
      maxCellsRetained = Math.max(maxCellsRetained, interaction.currentTableCells.length);
      return {
        view: capEditor,
        guard: {
          ...identity,
          mode: "live-preview",
          closeLockRequestId: null,
          composing: false,
          readonly: false,
        },
        currentEntry: interaction.currentEntry,
        currentTableCells: interaction.currentTableCells,
      };
    },
    hrefAllowed: () => false,
    openExternalAction: async () => {
      bridgeCalls += 1;
    },
    onDispatch: (result) => capResults.push(result),
  });
  const enqueueCapNavigation = async (shiftKey: boolean): Promise<void> => {
    if (capController === null) throw new Error("table perf exact-cap controller missing");
    const metricsBefore = capController.metrics();
    const selectionBefore = capEditor.state.selection.main.head;
    const capture = capController.tableKeyCapture(keyEvent("Tab", shiftKey));
    if (!capture.owned || capture.intent === null)
      throw new Error(
        `table perf exact-cap navigation capture missing: ${JSON.stringify({
          selection: capEditor.state.selection.main.head,
          metrics: metricsBefore,
        })}`,
      );
    const completed = capCoordinator.metrics().completed;
    if (!capCoordinator.enqueue(capture.intent))
      throw new Error("table perf exact-cap navigation admission failed");
    for (let turn = 0; turn < 20 && capCoordinator.metrics().completed === completed; turn += 1)
      await Promise.resolve();
    if (
      capCoordinator.metrics().completed !== completed + 1 ||
      capResults.at(-1)?.cm6Transactions !== 1
    ) {
      throw new Error("table perf exact-cap navigation did not commit once");
    }
    const metricsAfter = capController.metrics();
    if (
      metricsAfter.tableGroupBuildRecordChecks !== metricsBefore.tableGroupBuildRecordChecks ||
      metricsAfter.tableGroupCellArraysCreated !== metricsBefore.tableGroupCellArraysCreated
    ) {
      throw new Error("table perf exact-cap navigation rebuilt an unchanged table index");
    }
    maxEventRecordChecks = Math.max(
      maxEventRecordChecks,
      metricsAfter.interactionRangeChecks - metricsBefore.interactionRangeChecks,
    );
    maxProjectionRecordChecks = Math.max(
      maxProjectionRecordChecks,
      metricsAfter.diffedDecorations - metricsBefore.diffedDecorations,
    );
    maxGroupBuildRecordChecks = Math.max(
      maxGroupBuildRecordChecks,
      metricsAfter.tableGroupBuildRecordChecks - metricsBefore.tableGroupBuildRecordChecks,
    );
    maxGroupCellArraysCreated = Math.max(
      maxGroupCellArraysCreated,
      metricsAfter.tableGroupCellArraysCreated - metricsBefore.tableGroupCellArraysCreated,
    );
    const selectionAfter = capEditor.state.selection.main.head;
    if (
      (shiftKey && selectionAfter >= selectionBefore) ||
      (!shiftKey && selectionAfter <= selectionBefore)
    )
      throw new Error("table perf exact-cap navigation moved in the wrong direction");
  };

  const copyPadding = `\n\n${"plain ".repeat(
    Math.ceil(maxLivePreviewProjectionCodeUnits / 6) + 1,
  )}`;
  editor.dispatch({ changes: { from: editor.state.doc.length, insert: copyPadding } });
  sourceTransactions = 0;
  const measuredSourceLength = editor.state.doc.length;
  if (measuredSourceLength <= maxLivePreviewProjectionCodeUnits)
    throw new Error("table perf document-copy fixture is too small");

  let iframeCreate = 0;
  let iframeDestroy = 0;
  const countIframes = (node: Node): number => {
    if (!(node instanceof dom.window.Element)) return 0;
    return Number(node.matches("iframe")) + node.querySelectorAll("iframe").length;
  };
  const consumeIframeRecords = (records: readonly MutationRecord[]) => {
    for (const record of records) {
      for (const node of record.addedNodes) iframeCreate += countIframes(node);
      for (const node of record.removedNodes) iframeDestroy += countIframes(node);
    }
  };
  const iframeObserver = new dom.window.MutationObserver(consumeIframeRecords);
  iframeObserver.observe(host, { childList: true, subtree: true });
  iframeObserver.observe(capHost, { childList: true, subtree: true });
  const copyProbe = startDocumentCopyProbe();
  let copiedBytes: number | null = null;

  let capPlusOneTransactions = 0;
  let multirangeTransactions = 0;
  try {
    editor.dispatch({ selection: EditorSelection.cursor(source.indexOf("A")) });
    await enqueueKey("Tab");
    await enqueueKey("Enter");
    await enqueueKey("Enter");
    await enqueueKey("Tab", true);
    await enqueueKey("Tab");
    await enqueueKey("Tab");

    if (controller === null) throw new Error("table perf controller retired");
    const currentHead = editor.state.selection.main.head;
    const currentCapture = controller.tableKeyCapture(keyEvent("Tab"));
    if (!currentCapture.owned || currentCapture.intent === null)
      throw new Error("table perf multi-range source capture missing");
    editor.dispatch({
      selection: EditorSelection.create(
        [EditorSelection.cursor(source.indexOf("A")), EditorSelection.cursor(currentHead)],
        1,
      ),
    });
    const multirangeIdentity = controller.interactionIdentity();
    const multirangeIntent: LivePreviewIntent = {
      ...currentCapture.intent,
      ...multirangeIdentity,
    };
    const multiChecksBefore = controller.metrics().interactionRangeChecks;
    const beforeMulti = coordinator.metrics().completed;
    if (!coordinator.enqueue(multirangeIntent))
      throw new Error("table perf rejected the multi-range probe");
    for (let turn = 0; turn < 20 && coordinator.metrics().completed === beforeMulti; turn += 1)
      await Promise.resolve();
    multirangeTransactions = results.at(-1)?.cm6Transactions ?? -1;
    maxEventRecordChecks = Math.max(
      maxEventRecordChecks,
      controller.metrics().interactionRangeChecks - multiChecksBefore,
    );

    if (capController === null) throw new Error("table perf exact-cap controller missing");
    await enqueueCapNavigation(true);
    await enqueueCapNavigation(false);
    const capChecksBefore = capController.metrics().interactionRangeChecks;
    const capCapture = capController.tableKeyCapture(keyEvent("Tab"));
    if (!capCapture.owned || capCapture.intent === null)
      throw new Error("table perf exact-cap key capture missing");
    if (!capCoordinator.enqueue(capCapture.intent))
      throw new Error("table perf exact-cap coordinator admission failed");
    for (let turn = 0; turn < 20 && capCoordinator.metrics().completed < 3; turn += 1)
      await Promise.resolve();
    capPlusOneTransactions = capResults[2]?.cm6Transactions ?? -1;
    maxEventRecordChecks = Math.max(
      maxEventRecordChecks,
      capController.metrics().interactionRangeChecks - capChecksBefore,
    );

    await Promise.resolve();
    consumeIframeRecords(iframeObserver.takeRecords());
    copiedBytes = copyProbe.stop();

    const allResults = [...results, ...capResults];
    return {
      table_intent_events: allResults.length,
      table_cm6_transactions: allResults.reduce((sum, result) => sum + result.cm6Transactions, 0),
      table_source_transactions: sourceTransactions,
      table_appended_rows: (editor.state.doc.length - measuredSourceLength) / "\n|   |   |".length,
      table_zero_effect_rejections: allResults.reduce(
        (sum, result) => sum + Number(result.result.type !== "committed"),
        0,
      ),
      table_cell_cap: maxCellsRetained,
      table_cap_plus_one_transactions: capPlusOneTransactions,
      table_multirange_transactions: multirangeTransactions,
      table_context_record_checks:
        controller.metrics().interactionRangeChecks +
        capController.metrics().interactionRangeChecks,
      table_context_cells_retained_max: maxCellsRetained,
      table_queue_max_retained: Math.max(
        coordinator.metrics().maxRetained,
        capCoordinator.metrics().maxRetained,
      ),
      table_external_actions: allResults.reduce((sum, result) => sum + result.externalActions, 0),
      table_bridge_calls: bridgeCalls,
      table_iframe_create: iframeCreate,
      table_iframe_destroy: iframeDestroy,
      table_copied_bytes: copiedBytes,
      table_event_record_checks_max: maxEventRecordChecks,
      table_projection_record_count: capController.metrics().projectionRecordCount,
      table_non_table_record_count:
        capController.metrics().projectionRecordCount -
        capController.metrics().tableCellRecordCount,
      table_projection_record_checks_max: maxProjectionRecordChecks,
      table_group_build_record_checks_max: maxGroupBuildRecordChecks,
      table_group_cell_arrays_created_max: maxGroupCellArraysCreated,
    };
  } finally {
    if (copiedBytes === null) copyProbe.stop();
    iframeObserver.disconnect();
    coordinator.destroy();
    capCoordinator.destroy();
    controller?.destroy();
    capController?.destroy();
    editor.destroy();
    capEditor.destroy();
    host.remove();
    capHost.remove();
  }
}
async function runInteractionProbe(dom: JSDOM): Promise<
  Readonly<{
    intent_events: number;
    intent_cm6_transactions: number;
    intent_external_actions: number;
    intent_dual_effects: number;
    intent_zero_effect_rejections: number;
    intent_range_checks: number;
    intent_queue_capacity: number;
    intent_queue_max_retained: number;
    intent_queue_dropped: number;
    intent_bridge_calls: number;
  }>
> {
  const host = dom.window.document.createElement("aside");
  dom.window.document.body.append(host);
  const revisions = new EditorRevisionClock();
  let controller: EditableProjectionController | null = null;
  const editor = createMarkdownEditor(
    host,
    "- [ ] task\n\n[label](next.md)",
    (update) => {
      if (update.docChanged) revisions.documentChanged();
      controller?.handleUpdate(update);
    },
    () => {},
  );
  try {
    controller = new EditableProjectionController(editor, 1, revisions);
    controller.enable();
    const projectedLink = editor.dom.querySelector(".maru-projection-link");
    if (projectedLink === null) throw new Error("live preview interaction DOM target missing");
    projectedLink.dispatchEvent(
      new dom.window.MouseEvent("mousedown", { bubbles: true, button: 0, metaKey: true }),
    );
    const interactionRangeChecks = controller.metrics().interactionRangeChecks;
    if (interactionRangeChecks <= 0)
      throw new Error("live preview interaction DOM resolver was bypassed");

    const entries = buildEditableProjection(editor.state, {
      from: 0,
      to: editor.state.doc.length,
    }).entries;
    const task = entries.find((entry) => entry.type === "task");
    const link = entries.find((entry) => entry.type === "link");
    if (task?.type !== "task" || link?.type !== "link")
      throw new Error("live preview interaction perf projection missing");
    const identity = controller.interactionIdentity();
    const guard: EditorInteractionGuard = {
      ...identity,
      mode: "live-preview",
      closeLockRequestId: null,
      composing: false,
      readonly: false,
    };
    const taskIntent: LivePreviewIntent = {
      type: "toggle-task",
      ...identity,
      from: task.from,
      to: task.to,
      trusted: true,
      input: "pointer",
      gestureNonce: null,
    };
    const linkIntent: LivePreviewIntent = {
      type: "activate-link",
      ...identity,
      from: link.from,
      to: link.to,
      trusted: true,
      disposition: "command-pointer",
      gestureNonce: 1,
    };
    const staleIntent: LivePreviewIntent = { ...taskIntent, documentRevision: 1 };
    const composingIntent: LivePreviewIntent = { ...taskIntent };
    const untrustedIntent: LivePreviewIntent = { ...taskIntent, trusted: false };
    const results: LivePreviewDispatchResult[] = [];
    let bridgeCalls = 0;
    let pendingBridgeNode: HTMLElement | null = null;
    let stallBridge = false;
    const bridgeListener = () => {
      bridgeCalls += 1;
      pendingBridgeNode = dom.window.document.querySelector<HTMLElement>(
        '[data-maru-file-request="pending"]',
      );
      if (pendingBridgeNode === null || stallBridge) return;
      pendingBridgeNode.textContent = JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        result: { opened: true },
      });
      pendingBridgeNode.dataset.maruFileRequest = "done";
      dom.window.document.dispatchEvent(new dom.window.Event("maru:file-response"));
    };
    dom.window.document.addEventListener("maru:file-request", bridgeListener);
    let documentQueue = Promise.resolve();
    const scheduleDocumentOperation = <T>(operation: () => T): Promise<T> => {
      const scheduled = documentQueue.then(operation);
      documentQueue = scheduled.then(
        () => undefined,
        () => undefined,
      );
      return scheduled;
    };
    const hrefAllowed = (href: string) =>
      isLinkActivation({
        channel: viewerChannel,
        type: "link-activate",
        href,
        forceSystem: false,
      });
    const coordinator = new LivePreviewIntentCoordinator({
      scheduleDocumentOperation,
      currentContext: (intent) => ({
        view: editor,
        guard: intent === composingIntent ? { ...guard, composing: true } : guard,
        currentEntry: controller?.entryForIntent(intent) ?? null,
        currentTableCells: [],
      }),
      hrefAllowed,
      openExternalAction: async (intent, action) => {
        await requestFileBridge(
          dom.window.document,
          "openLink",
          {
            editor_epoch: intent.editorEpoch,
            href: action.href,
            forceSystem: action.forceSystem,
          },
          1_000,
        );
      },
      onDispatch: (dispatch) => results.push(dispatch),
    });
    try {
      for (const intent of [
        linkIntent,
        linkIntent,
        staleIntent,
        composingIntent,
        untrustedIntent,
        taskIntent,
      ]) {
        if (!coordinator.enqueue(intent))
          throw new Error("live preview product coordinator rejected a baseline intent");
      }
      for (let turn = 0; turn < 20 && coordinator.metrics().completed < 6; turn += 1)
        await Promise.resolve();
      if (results.length !== 6 || bridgeCalls !== 1)
        throw new Error("live preview product coordinator path was bypassed");

      stallBridge = true;
      const burstIdentity = controller.interactionIdentity();
      const burstLinkIntent: LivePreviewIntent = {
        ...linkIntent,
        ...burstIdentity,
        gestureNonce: 10,
      };
      const burstCoordinator = new LivePreviewIntentCoordinator({
        scheduleDocumentOperation,
        currentContext: (intent) => ({
          view: editor,
          guard: {
            ...burstIdentity,
            mode: "live-preview",
            closeLockRequestId: null,
            composing: false,
            readonly: false,
          },
          currentEntry: controller?.entryForIntent(intent) ?? null,
          currentTableCells: [],
        }),
        hrefAllowed,
        openExternalAction: async (intent, action) => {
          await requestFileBridge(
            dom.window.document,
            "openLink",
            {
              editor_epoch: intent.editorEpoch,
              href: action.href,
              forceSystem: action.forceSystem,
            },
            1_000,
          );
        },
      });
      for (let index = 0; index < maxRetainedLivePreviewIntents; index += 1)
        if (!burstCoordinator.enqueue({ ...burstLinkIntent, gestureNonce: index + 10 }))
          throw new Error("live preview bounded queue rejected an in-cap intent");
      if (burstCoordinator.enqueue({ ...burstLinkIntent, gestureNonce: 99 }))
        throw new Error("live preview bounded queue admitted cap+1");
      const saturated = burstCoordinator.metrics();
      for (let turn = 0; turn < 8 && bridgeCalls < 2; turn += 1) await Promise.resolve();
      if (pendingBridgeNode === null || bridgeCalls !== 2)
        throw new Error("live preview perf bridge path was bypassed");
      burstCoordinator.clearPending();
      pendingBridgeNode.textContent = JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        result: { ok: true },
      });
      pendingBridgeNode.dataset.maruFileRequest = "done";
      dom.window.document.dispatchEvent(new dom.window.Event("maru:file-response"));
      for (let turn = 0; turn < 4; turn += 1) await Promise.resolve();
      burstCoordinator.destroy();
      return {
        intent_events: results.length,
        intent_cm6_transactions: results.reduce((sum, result) => sum + result.cm6Transactions, 0),
        intent_external_actions: results.reduce((sum, result) => sum + result.externalActions, 0),
        intent_dual_effects: results.reduce(
          (sum, result) => sum + Number(result.cm6Transactions > 0 && result.externalActions > 0),
          0,
        ),
        intent_zero_effect_rejections: results.reduce(
          (sum, result) =>
            sum +
            Number(
              result.result.type !== "committed" &&
                result.cm6Transactions === 0 &&
                result.externalActions === 0,
            ),
          0,
        ),
        intent_range_checks: controller.metrics().interactionRangeChecks,
        intent_queue_capacity: maxRetainedLivePreviewIntents,
        intent_queue_max_retained: saturated.maxRetained,
        intent_queue_dropped: saturated.dropped,
        intent_bridge_calls: bridgeCalls,
      };
    } finally {
      coordinator.destroy();
      dom.window.document.removeEventListener("maru:file-request", bridgeListener);
    }
  } finally {
    controller?.destroy();
    editor.destroy();
    host.remove();
  }
}

export async function runLivePreviewBaselineScenario(): Promise<LivePreviewPerfCounters> {
  const dom = new JSDOM("<!doctype html><html><body><main></main></body></html>", {
    pretendToBeVisual: true,
  });
  const restoreDom = installDom(dom);
  // The visible prefix exercises real style/hidden/atomic projection. Short filler paragraphs preserve an exact
  // 8 MiB source without turning one CM6 line into a document-sized parse or DOM node.
  const prefix = "# heading ![alt](image.png)\n\n**strong** text\n\n$unclosed\n\n";
  const targetCodeUnits = 8 * 1024 * 1024;
  const paragraph = `${"a".repeat(62)}\n\n`;
  const repeated = paragraph.repeat(
    Math.floor((targetCodeUnits - prefix.length) / paragraph.length),
  );
  const initial = `${prefix}${repeated}${"a".repeat(targetCodeUnits - prefix.length - repeated.length)}`;
  const revisions = new EditorRevisionClock();
  let domMutations = 0;
  let iframeCreate = 0;
  let iframeDestroy = 0;
  const countIframes = (node: Node): number => {
    if (!(node instanceof dom.window.Element)) return 0;
    return Number(node.matches("iframe")) + node.querySelectorAll("iframe").length;
  };
  const projectionObserver = new dom.window.MutationObserver((records) => {
    for (const record of records) {
      const added = [...record.addedNodes].reduce((sum, node) => sum + countIframes(node), 0);
      const removed = [...record.removedNodes].reduce((sum, node) => sum + countIframes(node), 0);
      iframeCreate += added;
      iframeDestroy += removed;
      const touchesProjection = [...record.addedNodes, ...record.removedNodes].some((node) => {
        if (!(node instanceof dom.window.Element)) return false;
        return (
          [...node.classList].some((name) => name.startsWith("maru-projection-")) ||
          node.querySelector('[class*="maru-projection-"]') !== null
        );
      });
      if (touchesProjection) domMutations += 1;
    }
  });
  let controller: EditableProjectionController | null = null;
  let sourceTransactions = 0;
  const latestFallbackCounts = Object.fromEntries(
    projectionFallbackReasons.map((reason) => [reason, 0]),
  ) as Record<(typeof projectionFallbackReasons)[number], number>;
  const livePreviewDiagnostics = createLivePreviewDiagnosticsSnapshot();
  const updates = (update: ViewUpdate) => {
    const baseRevision = revisions.documentRevision;
    if (update.docChanged) revisions.documentChanged();
    if (update.docChanged) sourceTransactions += 1;
    atomicController?.handleUpdate(update, baseRevision, revisions.documentRevision);
    controller?.handleUpdate(update);
  };
  // A separate product EditorView forces the adversarial repeated-dollar parse without changing the canonical
  // projection fixture/fallback counts. The parser-site counter must remain at the context-wide hard cap.
  const denseHost = dom.window.document.createElement("aside");
  dom.window.document.body.append(denseHost);
  const denseMathProbe = startMathDelimiterScanProbe();
  const denseEditor = createMarkdownEditor(
    denseHost,
    "$1".repeat(8_192),
    () => {},
    () => {},
  );
  denseEditor.destroy();
  denseHost.remove();
  const denseMathScannedCodeUnits = denseMathProbe.stop();
  const interactionCounters = await runInteractionProbe(dom);
  const tableInteractionCounters = await runTableInteractionProbe(dom);
  const atomicProjectionCounters = runAtomicProjectionProbe();
  const atomicControllerCounters = await runAtomicControllerProbe(dom);
  const atomicFacadeCounters = await runAtomicFacadeRetentionProbe(dom);
  const mermaidControllerCounters = await runMermaidControllerProbe(dom);

  const mathScanProbe = startMathDelimiterScanProbe();
  PerfAtomicWorker.reset();
  let atomicController: AtomicProjectionController | null = null;
  const editor = createMarkdownEditor(
    dom.window.document.querySelector("main") as HTMLElement,
    initial,
    updates,
    () => {},
  );
  projectionObserver.observe(editor.dom, { childList: true, subtree: true });
  controller = new EditableProjectionController(editor, 1, revisions, ({ state }) => {
    if (state === "running") {
      const identity = controller?.interactionIdentity();
      if (identity !== undefined)
        atomicController?.submitEntries(
          identity.documentRevision,
          identity.projectionGeneration,
          [],
        );
    }
    if (controller === null) return;
    controller.writeDiagnostics(livePreviewDiagnostics);
    for (const reason of projectionFallbackReasons)
      latestFallbackCounts[reason] = livePreviewDiagnostics.fallbackCounts[reason];
  });
  atomicController = new AtomicProjectionController(
    editor,
    1,
    revisions,
    PerfAtomicWorker as unknown as typeof Worker,
    async () => null,
  );
  atomicController.enable();
  controller.enable();
  // Initial projection is the only admitted decoration commit. Its DOM records are outside the 1,000-input
  // same-fingerprint segment, whose projection-owned DOM mutation budget is exactly zero.
  projectionObserver.takeRecords();
  domMutations = 0;
  iframeCreate = 0;
  iframeDestroy = 0;

  const copyProbe = startDocumentCopyProbe();
  const atomicHashProbe = startAtomicSourceHashProbe();
  let copiedBytes = 0;
  let atomicMainHashedBytes = 0;
  let mathScannedCodeUnits = 0;
  let metrics = controller.metrics();
  let measuredFallbackCounts = { ...latestFallbackCounts };
  try {
    for (let index = 0; index < 1_000; index += 1) {
      editor.dispatch({ changes: { from: 2, to: 3, insert: index % 2 === 0 ? "H" : "h" } });
    }
    atomicMainHashedBytes = atomicHashProbe.stop();
    await new Promise<void>((resolve) => dom.window.requestAnimationFrame(() => resolve()));
    await Promise.resolve();
    const atomicMessages = PerfAtomicWorker.instances.flatMap(({ sent }) => sent);
    const atomicSeeds = atomicMessages.filter(({ type }) => type === "seed");
    const atomicApplies = atomicMessages.filter(({ type }) => type === "apply");
    if (
      atomicSeeds.length !== 1 ||
      atomicApplies.length !== 1 ||
      atomicApplies[0]?.baseRevision !== 0 ||
      atomicApplies[0]?.targetRevision !== 1_000
    )
      throw new Error("8 MiB atomic input path did not compose into one Apply");
    metrics = controller.metrics();
    measuredFallbackCounts = { ...latestFallbackCounts };
  } finally {
    if (atomicMainHashedBytes === 0) {
      try {
        atomicMainHashedBytes = atomicHashProbe.stop();
      } catch {
        // The probe was already stopped after the synchronous input segment.
      }
    }
    copiedBytes = copyProbe.stop();
    mathScannedCodeUnits = mathScanProbe.stop();
    atomicController.destroy();
    controller.destroy();
    editor.destroy();
    projectionObserver.disconnect();
    restoreDom();
  }
  if (sourceTransactions !== 1_000)
    throw new Error("live preview perf fixture bypassed the product input path");

  return {
    visited_code_units: metrics.visitedCodeUnits,
    visited_syntax_nodes: metrics.visitedSyntaxNodes,
    selection_range_checks: metrics.selectionRangeChecks,
    math_scanned_code_units: mathScannedCodeUnits,
    dense_math_scanned_code_units: denseMathScannedCodeUnits,
    emitted_decorations: metrics.emittedDecorations,
    diffed_decorations: metrics.diffedDecorations,
    copied_bytes: copiedBytes,
    source_transactions: sourceTransactions,
    projection_transactions: metrics.projectionTransactions,
    dom_mutations: domMutations,
    iframe_create: iframeCreate,
    iframe_destroy: iframeDestroy,
    retained_html_bytes: 0,
    generated_outside_retention: 0,
    ...atomicProjectionCounters,
    atomic_main_hashed_bytes: atomicMainHashedBytes,
    ...mermaidControllerCounters,
    atomic_main_copied_bytes: copiedBytes,
    ...atomicControllerCounters,
    ...atomicFacadeCounters,
    ...interactionCounters,
    ...tableInteractionCounters,
    projection_fallback_counts: Object.fromEntries(
      projectionFallbackReasons.map((reason) => [reason, measuredFallbackCounts[reason]]),
    ),
  };
}
