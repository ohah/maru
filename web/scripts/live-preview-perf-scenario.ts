import { Text } from "@codemirror/state";
import type { ViewUpdate } from "@codemirror/view";
import { JSDOM } from "jsdom";
import { createMarkdownEditor } from "../src/editor";
import { LivePreviewEditorController } from "../src/live-preview-editor";
import type { LivePreviewRequest, ProjectionResult } from "../src/live-preview-protocol";
import { maxLivePreviewProjectionCodeUnits } from "../src/live-preview-protocol";
import { EditorRevisionClock } from "../src/live-preview-state";
import type { LivePreviewPerfCounters } from "./live-preview-perf-model";

type CopyProbe = Readonly<{ stop: () => number }>;

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

class ControlledWorker {
  readonly sent: LivePreviewRequest[] = [];
  private replyIndex = 0;
  terminated = false;
  maxOutstanding = 0;
  onmessage: ((event: MessageEvent<unknown>) => void) | null = null;
  onerror: ((event: Event) => void) | null = null;
  onmessageerror: ((event: MessageEvent<unknown>) => void) | null = null;

  postMessage(message: LivePreviewRequest): void {
    this.sent.push(message);
    this.maxOutstanding = Math.max(this.maxOutstanding, this.sent.length - this.replyIndex);
    if (this.maxOutstanding > 1)
      throw new Error("live preview worker exceeded one in-flight request");
  }

  terminate(): void {
    this.terminated = true;
  }

  drain(): void {
    while (this.replyIndex < this.sent.length) {
      const request = this.sent[this.replyIndex];
      this.replyIndex += 1;
      if (request === undefined) throw new Error("missing live preview worker request");
      const result: ProjectionResult = {
        type: "result",
        documentRevision:
          request.type === "apply" ? request.targetRevision : request.documentRevision,
        projectionGeneration: request.type === "seed" ? 0 : request.projectionGeneration,
        fragments: [],
      };
      this.onmessage?.({ data: result } as MessageEvent<unknown>);
    }
  }
}

function installDom(dom: JSDOM): () => void {
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

export async function runLivePreviewBaselineScenario(): Promise<LivePreviewPerfCounters> {
  const dom = new JSDOM("<!doctype html><html><body><main></main></body></html>", {
    pretendToBeVisual: true,
  });
  const restoreDom = installDom(dom);
  // Short paragraphs keep the visible CM6 line bounded while preserving the exact 8 MiB document fixture.
  const initial = `${"a".repeat(62)}\n\n`.repeat(128 * 1024);
  const revisions = new EditorRevisionClock();
  const workers: ControlledWorker[] = [];
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
      if (added > 0 || removed > 0) domMutations += 1;
      iframeCreate += added;
      iframeDestroy += removed;
    }
  });
  let controller: LivePreviewEditorController | null = null;
  let sourceTransactions = 0;
  let projectionTransactions = 0;
  const updates = (update: ViewUpdate) => {
    if (!update.docChanged) {
      projectionTransactions += 1;
      controller?.handleUpdate(update, revisions.documentRevision, revisions.documentRevision);
      return;
    }
    const baseRevision = revisions.documentRevision;
    const targetRevision = revisions.documentChanged();
    sourceTransactions += 1;
    controller?.handleUpdate(update, baseRevision, targetRevision);
  };
  const editor = createMarkdownEditor(
    dom.window.document.querySelector("main") as HTMLElement,
    initial,
    updates,
    () => {},
  );
  projectionObserver.observe(editor.dom, { childList: true, subtree: true });
  const WorkerConstructor = class {
    constructor() {
      const worker = new ControlledWorker();
      workers.push(worker);
      return worker;
    }
  } as unknown as typeof Worker;
  controller = new LivePreviewEditorController(editor, 1, revisions, WorkerConstructor);
  controller.enable();
  const worker = workers[0];
  if (worker === undefined) throw new Error("live preview product path did not create a worker");
  worker.drain();

  const copyProbe = startDocumentCopyProbe();
  let copiedBytes = 0;
  let measuredProjectionTransactions = 0;
  try {
    for (let index = 0; index < 1_000; index += 1) {
      editor.dispatch({ changes: { from: 0, to: 1, insert: index % 2 === 0 ? "b" : "a" } });
      worker.drain();
    }
    await new Promise<void>((resolve) => dom.window.requestAnimationFrame(() => resolve()));
    measuredProjectionTransactions = projectionTransactions;
  } finally {
    copiedBytes = copyProbe.stop();
    controller.destroy();
    editor.destroy();
    projectionObserver.disconnect();
    restoreDom();
  }
  const applyRequests = worker.sent.filter(({ type }) => type === "apply").length;
  if (sourceTransactions !== 1_000 || applyRequests !== 1_000)
    throw new Error("live preview perf fixture bypassed the product input/worker path");
  if (worker.maxOutstanding !== 1)
    throw new Error("live preview perf fixture did not exercise bounded worker admission");
  if (!worker.terminated) throw new Error("live preview perf fixture leaked its worker");

  return {
    visited_code_units: 0,
    visited_syntax_nodes: 0,
    emitted_decorations: 0,
    diffed_decorations: 0,
    copied_bytes: copiedBytes,
    source_transactions: sourceTransactions,
    projection_transactions: measuredProjectionTransactions,
    dom_mutations: domMutations,
    iframe_create: iframeCreate,
    iframe_destroy: iframeDestroy,
    retained_html_bytes: 0,
    generated_outside_retention: 0,
    projection_fallback_counts: {
      "incomplete-tree": 0,
      "ambiguous-syntax": 0,
      "projection-limit": 0,
      "table-limit": 0,
      "atomic-not-enabled": 0,
      "rich-source-limit": 0,
      "renderer-unavailable": 0,
      "stale-capability": 0,
    },
  };
}
