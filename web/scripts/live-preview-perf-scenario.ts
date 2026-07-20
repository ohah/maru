import { Text } from "@codemirror/state";
import type { ViewUpdate } from "@codemirror/view";
import { JSDOM } from "jsdom";
import { createMarkdownEditor } from "../src/editor";
import { EditableProjectionController } from "../src/editable-projection-view";
import {
  createLivePreviewDiagnosticsSnapshot,
  projectionFallbackReasons,
} from "../src/live-preview-diagnostics";
import { maxLivePreviewProjectionCodeUnits } from "../src/live-preview-protocol";
import { startMathDelimiterScanProbe } from "../src/markdown-language";
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
    if (update.docChanged) revisions.documentChanged();
    if (update.docChanged) sourceTransactions += 1;
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

  const mathScanProbe = startMathDelimiterScanProbe();
  const editor = createMarkdownEditor(
    dom.window.document.querySelector("main") as HTMLElement,
    initial,
    updates,
    () => {},
  );
  projectionObserver.observe(editor.dom, { childList: true, subtree: true });
  controller = new EditableProjectionController(editor, 1, revisions, () => {
    if (controller === null) return;
    controller.writeDiagnostics(livePreviewDiagnostics);
    for (const reason of projectionFallbackReasons)
      latestFallbackCounts[reason] = livePreviewDiagnostics.fallbackCounts[reason];
  });
  controller.enable();
  // Initial projection is the only admitted decoration commit. Its DOM records are outside the 1,000-input
  // same-fingerprint segment, whose projection-owned DOM mutation budget is exactly zero.
  projectionObserver.takeRecords();
  domMutations = 0;
  iframeCreate = 0;
  iframeDestroy = 0;

  const copyProbe = startDocumentCopyProbe();
  let copiedBytes = 0;
  let mathScannedCodeUnits = 0;
  let metrics = controller.metrics();
  let measuredFallbackCounts = { ...latestFallbackCounts };
  try {
    for (let index = 0; index < 1_000; index += 1) {
      editor.dispatch({ changes: { from: 2, to: 3, insert: index % 2 === 0 ? "H" : "h" } });
    }
    await new Promise<void>((resolve) => dom.window.requestAnimationFrame(() => resolve()));
    metrics = controller.metrics();
    measuredFallbackCounts = { ...latestFallbackCounts };
  } finally {
    copiedBytes = copyProbe.stop();
    mathScannedCodeUnits = mathScanProbe.stop();
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
    projection_fallback_counts: Object.fromEntries(
      projectionFallbackReasons.map((reason) => [reason, measuredFallbackCounts[reason]]),
    ),
  };
}
