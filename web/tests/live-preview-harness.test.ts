import { describe, expect, test } from "bun:test";
import { EditorSelection } from "@codemirror/state";
import {
  atomicProjectionRequestShapeValid,
  atomicSourceWithinLimit,
  maxAtomicSourceBytes,
  type AssetGrant,
  type AtomicProjectionRequest,
  type AtomicProjectionResult,
} from "../src/atomic-projection";
import { createMarkdownEditor } from "../src/editor";
import {
  createLivePreviewDiagnosticsSnapshot,
  LivePreviewDiagnosticsStore,
} from "../src/live-preview-diagnostics";
import {
  interactionGuardRejection,
  isLivePreviewIntent,
  type EditorInteractionGuard,
  type LivePreviewIntent,
} from "../src/live-preview-intent";
import {
  compareProjectionEntries,
  maxLivePreviewProjectionEntries,
  maxLivePreviewSyntaxNodes,
  projectionEntriesEqual,
  type ProjectionEntry,
} from "../src/live-preview-projection";
import { withEditorDom } from "./editor-dom";

describe("FP11 live preview contract harness", () => {
  test("uses one closed canonical key for every projection variant", () => {
    const entries: ProjectionEntry[] = [
      { type: "atomic", role: "image", from: 30, to: 40 },
      { type: "style", role: "heading-1", from: 0, to: 8 },
      { type: "task", checked: false, from: 10, to: 13 },
      {
        type: "link",
        from: 14,
        to: 29,
        labelFrom: 15,
        labelTo: 20,
        destinationFrom: 22,
        destinationTo: 28,
      },
      {
        type: "table-cell",
        from: 41,
        to: 45,
        tableFrom: 40,
        tableTo: 60,
        appendPrefixFrom: 40,
        appendPrefixTo: 40,
        row: 1,
        column: 2,
        rowCount: 2,
        columnCount: 3,
      },
      { type: "hidden-syntax", role: "heading-marker", from: 0, to: 1 },
    ];
    const canonical = [...entries].sort(compareProjectionEntries);
    expect(canonical.map(({ type }) => type)).toEqual([
      "hidden-syntax",
      "style",
      "task",
      "link",
      "atomic",
      "table-cell",
    ]);
    expect(
      canonical.every((entry, index) =>
        canonical.every((other, otherIndex) =>
          otherIndex === index
            ? projectionEntriesEqual(entry, other)
            : !projectionEntriesEqual(entry, other),
        ),
      ),
    ).toBe(true);
    expect(maxLivePreviewSyntaxNodes).toBe(8_192);
    expect(maxLivePreviewProjectionEntries).toBe(4_096);

    // @ts-expect-error atomic entries cannot carry a style role.
    const invalid: ProjectionEntry = { type: "atomic", role: "emphasis", from: 0, to: 1 };
    expect(invalid.type).toBe("atomic");
  });

  test("rejects malformed, stale, and duplicate interactions before commit", () => {
    const intent: LivePreviewIntent = {
      type: "toggle-task",
      editorEpoch: 2,
      documentRevision: 3,
      projectionGeneration: 4,
      from: 1,
      to: 4,
      trusted: true,
      gestureNonce: null,
      input: "pointer",
    };
    const guard: EditorInteractionGuard = {
      editorEpoch: 2,
      documentRevision: 3,
      projectionGeneration: 4,
      mode: "live-preview",
      closeLockRequestId: null,
      composing: false,
      readonly: false,
    };
    expect(interactionGuardRejection(intent, guard, 10, true)).toBeNull();
    expect(interactionGuardRejection({ ...intent, editorEpoch: 1 }, guard, 10, true)).toBe(
      "stale-epoch",
    );
    expect(interactionGuardRejection({ ...intent, documentRevision: 2 }, guard, 10, true)).toBe(
      "stale-revision",
    );
    expect(interactionGuardRejection({ ...intent, projectionGeneration: 3 }, guard, 10, true)).toBe(
      "stale-projection",
    );
    expect(interactionGuardRejection({ ...intent, to: 11 }, guard, 10, true)).toBe("stale-range");
    expect(interactionGuardRejection(intent, { ...guard, closeLockRequestId: 9 }, 10, true)).toBe(
      "close-locked",
    );
    expect(interactionGuardRejection(intent, { ...guard, composing: true }, 10, true)).toBe(
      "composing",
    );
    expect(interactionGuardRejection({ ...intent, trusted: false }, guard, 10, true)).toBe(
      "untrusted-event",
    );
    expect(interactionGuardRejection({ ...intent, from: Number.NaN }, guard, 10, true)).toBe(
      "invalid-intent",
    );

    const link: LivePreviewIntent = {
      type: "activate-link",
      editorEpoch: 2,
      documentRevision: 3,
      projectionGeneration: 4,
      from: 1,
      to: 4,
      trusted: true,
      disposition: "command-pointer",
      gestureNonce: 8,
    };
    expect(interactionGuardRejection(link, guard, 10, false)).toBe("duplicate-gesture");
    expect(isLivePreviewIntent({ ...link, gestureNonce: null })).toBe(false);
    expect(isLivePreviewIntent({ ...link, extra: true })).toBe(false);

    const backward: LivePreviewIntent = {
      ...intent,
      type: "move-table-cell",
      input: "keyboard",
      direction: "backward",
    };
    expect(isLivePreviewIntent(backward)).toBe(true);

    // @ts-expect-error table movement requires an explicit direction.
    const missingDirection: LivePreviewIntent = {
      ...intent,
      type: "move-table-cell",
      input: "keyboard",
    };
    expect(isLivePreviewIntent(missingDirection)).toBe(false);
  });

  test("copies diagnostics into caller storage without exposing source offsets", () => {
    const store = new LivePreviewDiagnosticsStore(7);
    const ranges = Array.from({ length: 16 }, (_, index) => ({ from: index, to: index + 1 }));
    store.commit({
      documentRevision: 3,
      projectionGeneration: 5,
      decorationCount: 2,
      desiredWidgets: 3,
      mountedWidgets: 2,
      activeSourceRangeCount: 18,
      activeSourceRanges: ranges,
      fallbackCounts: { "atomic-not-enabled": 1 },
    });
    const first = createLivePreviewDiagnosticsSnapshot();
    store.writeSnapshot(first);
    const second = createLivePreviewDiagnosticsSnapshot();
    store.writeSnapshot(second);
    expect(second).not.toBe(first);
    expect(second).toEqual(first);
    second.fallbackCounts["atomic-not-enabled"] = 99;
    store.writeSnapshot(first);
    expect(first.fallbackCounts["atomic-not-enabled"]).toBe(1);
    expect(first.activeSourceRangeCount).toBe(18);
    expect(first.activeSourceRangesTruncated).toBe(true);
    const rangeTarget = new Uint32Array(32);
    expect(store.writeTestOnlyActiveSourceRanges(rangeTarget)).toBe(32);
    const serialized = JSON.stringify(first);
    expect(serialized).not.toContain('"from"');
    expect(serialized).not.toContain('"to"');
    expect(serialized).not.toContain("content");
    expect(serialized).not.toContain("path");
    expect(serialized).not.toContain("url");
    expect(() =>
      store.commit({
        documentRevision: 3,
        projectionGeneration: 5,
        decorationCount: -1,
        desiredWidgets: 0,
        mountedWidgets: 0,
        activeSourceRangeCount: 0,
        activeSourceRanges: [],
      }),
    ).toThrow();
  });

  test("mounts an actual EditorView with the FP11 extension boundary", () => {
    withEditorDom((dom) => {
      const editor = createMarkdownEditor(
        dom.window.document.querySelector("main") as HTMLElement,
        "# heading\n\ntext",
        () => {},
        () => {},
      );
      try {
        editor.dispatch({ selection: EditorSelection.cursor(4) });
        expect(editor.state.doc.toString()).toBe("# heading\n\ntext");
        expect(editor.state.selection.main.head).toBe(4);
      } finally {
        editor.destroy();
      }
    });
  });

  test("admits only closed atomic request shapes and bounds worker source bytes", () => {
    const request: AtomicProjectionRequest = {
      editorEpoch: 2,
      documentRevision: 0,
      projectionGeneration: 1,
      requestNonce: 9,
      kind: "fenced-code",
      from: 4,
      to: 20,
    };
    expect(atomicProjectionRequestShapeValid(request, 20)).toBe(true);
    expect(atomicProjectionRequestShapeValid(null, 20)).toBe(false);
    expect(atomicProjectionRequestShapeValid(request, Number.NaN)).toBe(false);
    expect(atomicProjectionRequestShapeValid({ ...request, editorEpoch: 0 }, 20)).toBe(false);
    expect(atomicProjectionRequestShapeValid({ ...request, requestNonce: 0 }, 20)).toBe(false);
    expect(atomicProjectionRequestShapeValid({ ...request, kind: "unknown" }, 20)).toBe(false);
    expect(atomicProjectionRequestShapeValid({ ...request, to: 21 }, 20)).toBe(false);
    expect(atomicProjectionRequestShapeValid({ ...request, extra: true }, 20)).toBe(false);
    expect(atomicSourceWithinLimit("math", "a".repeat(maxAtomicSourceBytes.math))).toBe(true);
    expect(atomicSourceWithinLimit("math", "a".repeat(maxAtomicSourceBytes.math + 1))).toBe(false);
    expect(atomicSourceWithinLimit("mermaid", "\n".repeat(511))).toBe(true);
    expect(atomicSourceWithinLimit("mermaid", "\n".repeat(512))).toBe(false);

    const grant: AssetGrant = {
      editorEpoch: 2,
      assetNonce: 10,
      opaqueId: 11,
      normalizedPath: "images/diagram.png",
      expectedMimeFamily: "raster-image",
    };
    const result: AtomicProjectionResult = {
      request,
      sourceHash: "a".repeat(16),
      sanitizedPayload: "<img>",
      assetGrants: [grant],
      mermaidSource: null,
    };
    expect(result.assetGrants[0]).toEqual(grant);

    const acceptResult = (_result: AtomicProjectionResult) => {};
    // @ts-expect-error count-only results cannot replace capability-bearing asset grants.
    acceptResult({ request, sourceHash: "a", sanitizedPayload: "", assetGrantCount: 1 });
    const acceptGrant = (_grant: AssetGrant) => {};
    // @ts-expect-error every asset grant requires its non-reusable asset nonce.
    acceptGrant({
      editorEpoch: 2,
      opaqueId: 11,
      normalizedPath: "x",
      expectedMimeFamily: "svg-image",
    });
  });
});
