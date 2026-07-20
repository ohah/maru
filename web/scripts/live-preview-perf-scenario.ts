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
  const interactionCounters = await runInteractionProbe(dom);
  const tableInteractionCounters = await runTableInteractionProbe(dom);

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
    ...interactionCounters,
    ...tableInteractionCounters,
    projection_fallback_counts: Object.fromEntries(
      projectionFallbackReasons.map((reason) => [reason, measuredFallbackCounts[reason]]),
    ),
  };
}
