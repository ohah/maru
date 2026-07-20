import { describe, expect, test } from "bun:test";
import { undo } from "@codemirror/commands";
import { EditorSelection } from "@codemirror/state";
import {
  EditableProjectionController,
  livePreviewGestureCaptureAllowed,
  livePreviewTableKeyIntent,
} from "../src/editable-projection-view";
import { buildEditableProjection } from "../src/editable-projection";
import { createMarkdownEditor } from "../src/editor";
import {
  BoundedLivePreviewIntentQueue,
  dispatchLivePreviewIntent,
  GestureNonceLedger,
  LivePreviewIntentCoordinator,
  maxRetainedLivePreviewIntents,
} from "../src/live-preview-interaction";
import type { EditorInteractionGuard, LivePreviewIntent } from "../src/live-preview-intent";
import type { ProjectionEntry } from "../src/live-preview-projection";
import { EditorRevisionClock } from "../src/live-preview-state";
import { isLinkActivation, requestFileBridge, viewerChannel } from "../src/viewer";
import { withEditorDom } from "./editor-dom";

const identity = {
  editorEpoch: 1,
  documentRevision: 0,
  projectionGeneration: 1,
} as const;

const guard: EditorInteractionGuard = {
  ...identity,
  mode: "live-preview",
  closeLockRequestId: null,
  composing: false,
  readonly: false,
};

function entryOfType<T extends ProjectionEntry["type"]>(
  entries: readonly ProjectionEntry[],
  type: T,
): Extract<ProjectionEntry, { type: T }> {
  const entry = entries.find((candidate) => candidate.type === type);
  if (entry === undefined) throw new Error(`missing ${type} projection entry`);
  return entry as Extract<ProjectionEntry, { type: T }>;
}

function productHrefAllowed(href: string): boolean {
  return isLinkActivation({
    channel: viewerChannel,
    type: "link-activate",
    href,
    forceSystem: false,
  });
}

describe("live preview interaction dispatcher", () => {
  test("toggles only the task marker middle byte in one undoable CM6 transaction", () => {
    withEditorDom((dom) => {
      let updates = 0;
      const editor = createMarkdownEditor(
        dom.window.document.querySelector("main") as HTMLElement,
        "- [ ] todo",
        () => {
          updates += 1;
        },
        () => {},
      );
      try {
        const task = entryOfType(
          buildEditableProjection(editor.state, { from: 0, to: editor.state.doc.length }).entries,
          "task",
        );
        const result = dispatchLivePreviewIntent(
          editor,
          {
            type: "toggle-task",
            ...identity,
            from: task.from,
            to: task.to,
            trusted: true,
            input: "pointer",
            gestureNonce: null,
          },
          guard,
          task,
          new GestureNonceLedger(),
          productHrefAllowed,
          [],
        );
        expect(editor.state.doc.toString()).toBe("- [x] todo");
        expect(result).toEqual({
          result: { type: "committed" },
          externalAction: null,
          cm6Transactions: 1,
          externalActions: 0,
        });
        expect(updates).toBe(1);
        expect(undo(editor)).toBe(true);
        expect(editor.state.doc.toString()).toBe("- [ ] todo");
      } finally {
        editor.destroy();
      }
    });
  });

  test("reparses the current source destination and consumes each link gesture once", () => {
    withEditorDom((dom) => {
      const editor = createMarkdownEditor(
        dom.window.document.querySelector("main") as HTMLElement,
        "[label](next.md)",
        () => {},
        () => {},
      );
      try {
        const link = entryOfType(
          buildEditableProjection(editor.state, { from: 0, to: editor.state.doc.length }).entries,
          "link",
        );
        const ledger = new GestureNonceLedger();
        const intent: LivePreviewIntent = {
          type: "activate-link",
          ...identity,
          from: link.from,
          to: link.to,
          trusted: true,
          disposition: "command-pointer",
          gestureNonce: 1,
        };
        expect(
          dispatchLivePreviewIntent(editor, intent, guard, link, ledger, productHrefAllowed, []),
        ).toEqual({
          result: { type: "committed" },
          externalAction: { type: "open-link", href: "next.md", forceSystem: false },
          cm6Transactions: 0,
          externalActions: 1,
        });
        expect(
          dispatchLivePreviewIntent(editor, intent, guard, link, ledger, productHrefAllowed, []),
        ).toEqual({
          result: { type: "consumed-no-change", reason: "duplicate-gesture" },
          externalAction: null,
          cm6Transactions: 0,
          externalActions: 0,
        });

        const invalidSource = "javascript:alert";
        editor.dispatch({
          changes: {
            from: link.destinationFrom,
            to: link.destinationTo,
            insert: invalidSource,
          },
        });
        const invalidLink: ProjectionEntry = {
          ...link,
          to: link.to - "next.md".length + invalidSource.length,
          destinationTo: link.destinationFrom + invalidSource.length,
        };
        const invalidIntent: LivePreviewIntent = {
          ...intent,
          documentRevision: 1,
          projectionGeneration: 2,
          from: invalidLink.from,
          to: invalidLink.to,
          gestureNonce: 2,
        };
        const invalidGuard: EditorInteractionGuard = {
          ...guard,
          documentRevision: 1,
          projectionGeneration: 2,
        };
        expect(
          dispatchLivePreviewIntent(
            editor,
            invalidIntent,
            invalidGuard,
            invalidLink,
            ledger,
            productHrefAllowed,
            [],
          ),
        ).toEqual({
          result: { type: "rejected", reason: "invalid-intent" },
          externalAction: null,
          cm6Transactions: 0,
          externalActions: 0,
        });
      } finally {
        editor.destroy();
      }
    });
  });

  test("rejects stale, locked, readonly, composing, untrusted, and malformed intents with zero effects", () => {
    withEditorDom((dom) => {
      const editor = createMarkdownEditor(
        dom.window.document.querySelector("main") as HTMLElement,
        "- [ ] todo",
        () => {},
        () => {},
      );
      try {
        const task = entryOfType(
          buildEditableProjection(editor.state, { from: 0, to: editor.state.doc.length }).entries,
          "task",
        );
        const baseIntent: LivePreviewIntent = {
          type: "toggle-task",
          ...identity,
          from: task.from,
          to: task.to,
          trusted: true,
          input: "keyboard",
          gestureNonce: null,
        };
        const cases: Array<readonly [LivePreviewIntent, EditorInteractionGuard, string]> = [
          [{ ...baseIntent, editorEpoch: 2 }, guard, "stale-epoch"],
          [{ ...baseIntent, documentRevision: 1 }, guard, "stale-revision"],
          [{ ...baseIntent, projectionGeneration: 2 }, guard, "stale-projection"],
          [baseIntent, { ...guard, closeLockRequestId: 7 }, "close-locked"],
          [baseIntent, { ...guard, readonly: true }, "readonly"],
          [baseIntent, { ...guard, mode: "source-edit" }, "readonly"],
          [baseIntent, { ...guard, mode: "read" }, "readonly"],
          [baseIntent, { ...guard, composing: true }, "composing"],
          [{ ...baseIntent, trusted: false }, guard, "untrusted-event"],
          [{ ...baseIntent, to: task.to - 1 }, guard, "stale-range"],
        ];
        for (const [intent, currentGuard, reason] of cases) {
          const result = dispatchLivePreviewIntent(
            editor,
            intent,
            currentGuard,
            task,
            new GestureNonceLedger(),
            productHrefAllowed,
            [],
          );
          expect(result.result).toEqual(expect.objectContaining({ reason }));
          expect(result.cm6Transactions).toBe(0);
          expect(result.externalActions).toBe(0);
          expect(result.externalAction).toBeNull();
          expect(editor.state.doc.toString()).toBe("- [ ] todo");
        }
      } finally {
        editor.destroy();
      }
    });
  });

  test("selects an admitted atomic range once", () => {
    withEditorDom((dom) => {
      let updates = 0;
      const editor = createMarkdownEditor(
        dom.window.document.querySelector("main") as HTMLElement,
        "![alt](image.png)\n\n| a |\n| - |",
        () => {
          updates += 1;
        },
        () => {},
      );
      try {
        editor.dispatch({ selection: EditorSelection.cursor(editor.state.doc.length) });
        updates = 0;
        const entries = buildEditableProjection(editor.state, {
          from: 0,
          to: editor.state.doc.length,
        }).entries;
        const atomic = entryOfType(entries, "atomic");
        const selected = dispatchLivePreviewIntent(
          editor,
          {
            type: "select-atomic",
            ...identity,
            from: atomic.from,
            to: atomic.to,
            trusted: true,
            input: "pointer",
            gestureNonce: null,
          },
          guard,
          atomic,
          new GestureNonceLedger(),
          productHrefAllowed,
          [],
        );
        expect(selected.cm6Transactions).toBe(1);
        expect(editor.state.selection.main).toEqual(EditorSelection.range(atomic.from, atomic.to));
        expect(updates).toBe(1);
      } finally {
        editor.destroy();
      }
    });
  });

  test("moves across the current rectangular table and appends one undoable row", () => {
    withEditorDom((dom) => {
      let updates = 0;
      const source = "| A | B |\n| - | - |\n| c | d |";
      const editor = createMarkdownEditor(
        dom.window.document.querySelector("main") as HTMLElement,
        source,
        () => {
          updates += 1;
        },
        () => {},
      );
      const ledger = new GestureNonceLedger();
      const cells = buildEditableProjection(editor.state, {
        from: 0,
        to: editor.state.doc.length,
      }).entries.filter(
        (entry): entry is Extract<ProjectionEntry, { type: "table-cell" }> =>
          entry.type === "table-cell",
      );
      const cell = (row: number, column: number) => {
        const match = cells.find((entry) => entry.row === row && entry.column === column);
        if (match === undefined) throw new Error(`missing table cell ${row}:${column}`);
        return match;
      };
      const dispatchTable = (
        current: ReturnType<typeof cell>,
        intent: Extract<LivePreviewIntent, { type: "move-table-cell" | "append-table-row" }>,
      ) =>
        dispatchLivePreviewIntent(
          editor,
          intent,
          guard,
          current,
          ledger,
          productHrefAllowed,
          cells,
        );
      try {
        editor.dispatch({ selection: EditorSelection.cursor(cell(0, 0).from) });
        expect(
          dispatchTable(cell(0, 0), {
            type: "move-table-cell",
            ...identity,
            from: cell(0, 0).from,
            to: cell(0, 0).to,
            trusted: true,
            input: "keyboard",
            direction: "forward",
            gestureNonce: null,
          }).cm6Transactions,
        ).toBe(1);
        expect(editor.state.selection.main.head).toBe(cell(0, 1).from);

        expect(
          dispatchTable(cell(0, 1), {
            type: "move-table-cell",
            ...identity,
            from: cell(0, 1).from,
            to: cell(0, 1).to,
            trusted: true,
            input: "keyboard",
            direction: "down",
            gestureNonce: null,
          }).cm6Transactions,
        ).toBe(1);
        expect(editor.state.selection.main.head).toBe(cell(1, 1).from);

        const appended = dispatchTable(cell(1, 1), {
          type: "append-table-row",
          ...identity,
          from: cell(1, 1).from,
          to: cell(1, 1).to,
          trusted: true,
          input: "keyboard",
          gestureNonce: null,
        });
        expect(appended).toEqual({
          result: { type: "committed" },
          externalAction: null,
          cm6Transactions: 1,
          externalActions: 0,
        });
        expect(editor.state.doc.toString()).toBe(`${source}\n|   |   |`);
        expect(editor.state.selection.main.head).toBe(source.length + "\n|   |".length + 1);
        expect(updates).toBe(4);
        expect(undo(editor)).toBe(true);
        expect(editor.state.doc.toString()).toBe(source);
      } finally {
        editor.destroy();
      }
    });
  });

  test("last-cell Tab appends at column zero while first-cell Shift-Tab consumes no change", () => {
    withEditorDom((dom) => {
      const source = "| A | B |\n| - | - |\n| c | d |";
      const editor = createMarkdownEditor(
        dom.window.document.querySelector("main") as HTMLElement,
        source,
        () => {},
        () => {},
      );
      const cells = buildEditableProjection(editor.state, {
        from: 0,
        to: editor.state.doc.length,
      }).entries.filter(
        (entry): entry is Extract<ProjectionEntry, { type: "table-cell" }> =>
          entry.type === "table-cell",
      );
      const first = cells[0];
      const last = cells.at(-1);
      if (first === undefined || last === undefined) throw new Error("missing table cells");
      try {
        editor.dispatch({ selection: EditorSelection.cursor(first.from) });
        expect(
          dispatchLivePreviewIntent(
            editor,
            {
              type: "move-table-cell",
              ...identity,
              from: first.from,
              to: first.to,
              trusted: true,
              input: "keyboard",
              direction: "backward",
              gestureNonce: null,
            },
            guard,
            first,
            new GestureNonceLedger(),
            productHrefAllowed,
            cells,
          ),
        ).toEqual({
          result: { type: "consumed-no-change", reason: "invalid-intent" },
          externalAction: null,
          cm6Transactions: 0,
          externalActions: 0,
        });
        expect(editor.state.selection.main.head).toBe(first.from);

        editor.dispatch({ selection: EditorSelection.cursor(last.from) });
        const appended = dispatchLivePreviewIntent(
          editor,
          {
            type: "move-table-cell",
            ...identity,
            from: last.from,
            to: last.to,
            trusted: true,
            input: "keyboard",
            direction: "forward",
            gestureNonce: null,
          },
          guard,
          last,
          new GestureNonceLedger(),
          productHrefAllowed,
          cells,
        );
        expect(appended.cm6Transactions).toBe(1);
        expect(editor.state.doc.toString()).toBe(`${source}\n|   |   |`);
        expect(editor.state.selection.main.head).toBe(source.length + "\n| ".length);
      } finally {
        editor.destroy();
      }
    });
  });

  test("preserves blockquote and list continuation prefixes when appending a row", () => {
    for (const [source, prefix] of [
      ["> | A | B |\n> | --- | --- |\n> | c | d |", "> "],
      ["- item\n\n  | A | B |\n  | --- | --- |\n  | c | d |", "  "],
    ] as const) {
      withEditorDom((dom) => {
        const editor = createMarkdownEditor(
          dom.window.document.querySelector("main") as HTMLElement,
          source,
          () => {},
          () => {},
        );
        const cells = buildEditableProjection(editor.state, {
          from: 0,
          to: editor.state.doc.length,
        }).entries.filter(
          (entry): entry is Extract<ProjectionEntry, { type: "table-cell" }> =>
            entry.type === "table-cell",
        );
        const last = cells.at(-1);
        if (last === undefined) throw new Error("missing nested table cell");
        try {
          editor.dispatch({ selection: EditorSelection.cursor(last.from) });
          const result = dispatchLivePreviewIntent(
            editor,
            {
              type: "append-table-row",
              ...identity,
              from: last.from,
              to: last.to,
              trusted: true,
              input: "keyboard",
              gestureNonce: null,
            },
            guard,
            last,
            new GestureNonceLedger(),
            productHrefAllowed,
            cells,
          );
          expect(result.cm6Transactions).toBe(1);
          expect(editor.state.doc.toString()).toBe(`${source}\n${prefix}|   |   |`);
          const reprojection = buildEditableProjection(editor.state, {
            from: 0,
            to: editor.state.doc.length,
          });
          expect(reprojection.entries.filter(({ type }) => type === "table-cell")).toHaveLength(6);
          expect(reprojection.fallbackCounts["ambiguous-syntax"]).toBe(0);
          expect(undo(editor)).toBe(true);
          expect(editor.state.doc.toString()).toBe(source);
        } finally {
          editor.destroy();
        }
      });
    }
  });

  test("uses the physical delimiter-line prefix for header-only nested tables", () => {
    for (const [source, prefix] of [
      ["| H |\n| --- |", ""],
      ["> | H |\n> | --- |", "> "],
      ["- | H |\n  | --- |", "  "],
      ["1. | H |\n   | --- |", "   "],
      ["- [ ] item\n\n  | H |\n  | --- |", "  "],
      ["- parent\n  - | H |\n    | --- |", "    "],
    ] as const) {
      for (const intentType of ["move-table-cell", "append-table-row"] as const) {
        withEditorDom((dom) => {
          const editor = createMarkdownEditor(
            dom.window.document.querySelector("main") as HTMLElement,
            source,
            () => {},
            () => {},
          );
          const cells = buildEditableProjection(editor.state, {
            from: 0,
            to: editor.state.doc.length,
          }).entries.filter(
            (entry): entry is Extract<ProjectionEntry, { type: "table-cell" }> =>
              entry.type === "table-cell",
          );
          const last = cells.at(-1);
          if (last === undefined) throw new Error("missing header-only table cell");
          try {
            editor.dispatch({ selection: EditorSelection.cursor(last.from) });
            const common = {
              ...identity,
              from: last.from,
              to: last.to,
              trusted: true,
              input: "keyboard" as const,
              gestureNonce: null,
            };
            const intent: LivePreviewIntent =
              intentType === "move-table-cell"
                ? { type: intentType, direction: "forward", ...common }
                : { type: intentType, ...common };
            const result = dispatchLivePreviewIntent(
              editor,
              intent,
              guard,
              last,
              new GestureNonceLedger(),
              productHrefAllowed,
              cells,
            );
            expect(result.cm6Transactions).toBe(1);
            expect(editor.state.doc.toString()).toBe(`${source}\n${prefix}|   |`);
            const reprojection = buildEditableProjection(editor.state, {
              from: 0,
              to: editor.state.doc.length,
            });
            const sameTable = reprojection.entries.filter(
              (entry): entry is Extract<ProjectionEntry, { type: "table-cell" }> =>
                entry.type === "table-cell" && entry.tableFrom === last.tableFrom,
            );
            expect(sameTable).toHaveLength(2);
            expect(sameTable.every(({ rowCount }) => rowCount === 2)).toBe(true);
            const appended = sameTable.at(-1);
            expect(appended).toBeDefined();
            expect(editor.state.selection.main.head).toBeGreaterThanOrEqual(appended?.from ?? 0);
            expect(editor.state.selection.main.head).toBeLessThanOrEqual(appended?.to ?? 0);
            expect(undo(editor)).toBe(true);
            expect(editor.state.doc.toString()).toBe(source);
          } finally {
            editor.destroy();
          }
        });
      }
    }
  });

  test("keeps table navigation and append behavior across all outer-pipe forms", () => {
    for (const source of [
      "| A | B |\n| --- | --- |\n| c | d |",
      "| A | B\n| --- | ---\n| c | d",
      "A | B |\n--- | --- |\nc | d |",
      "A | B\n--- | ---\nc | d",
    ]) {
      withEditorDom((dom) => {
        const editor = createMarkdownEditor(
          dom.window.document.querySelector("main") as HTMLElement,
          source,
          () => {},
          () => {},
        );
        const cells = buildEditableProjection(editor.state, {
          from: 0,
          to: editor.state.doc.length,
        }).entries.filter(
          (entry): entry is Extract<ProjectionEntry, { type: "table-cell" }> =>
            entry.type === "table-cell",
        );
        const [first, second, third, last] = cells;
        if (
          first === undefined ||
          second === undefined ||
          third === undefined ||
          last === undefined
        )
          throw new Error("missing outer-pipe table cells");
        const move = (current: typeof first, direction: "forward" | "backward" | "down") =>
          dispatchLivePreviewIntent(
            editor,
            {
              type: "move-table-cell",
              ...identity,
              from: current.from,
              to: current.to,
              trusted: true,
              input: "keyboard",
              direction,
              gestureNonce: null,
            },
            guard,
            current,
            new GestureNonceLedger(),
            productHrefAllowed,
            cells,
          );
        try {
          editor.dispatch({ selection: EditorSelection.cursor(first.from) });
          expect(move(first, "forward").cm6Transactions).toBe(1);
          expect(editor.state.selection.main.head).toBe(second.from);
          expect(move(second, "backward").cm6Transactions).toBe(1);
          expect(editor.state.selection.main.head).toBe(first.from);
          expect(move(first, "down").cm6Transactions).toBe(1);
          expect(editor.state.selection.main.head).toBe(third.from);
          editor.dispatch({ selection: EditorSelection.cursor(last.from) });
          expect(move(last, "forward").cm6Transactions).toBe(1);
          expect(editor.state.doc.toString()).toBe(`${source}\n|   |   |`);
        } finally {
          editor.destroy();
        }
      });
    }
  });

  test("rejects stale table geometry, multi-range selection, and cap-plus-one append with zero effects", () => {
    withEditorDom((dom) => {
      const source =
        `| h |\n| - |\n${Array.from({ length: 255 }, () => "| x |\n").join("")}`.trimEnd();
      const editor = createMarkdownEditor(
        dom.window.document.querySelector("main") as HTMLElement,
        source,
        () => {},
        () => {},
      );
      const cells = buildEditableProjection(editor.state, {
        from: 0,
        to: editor.state.doc.length,
      }).entries.filter(
        (entry): entry is Extract<ProjectionEntry, { type: "table-cell" }> =>
          entry.type === "table-cell",
      );
      const last = cells.at(-1);
      if (last === undefined) throw new Error("missing table cell");
      const intent: LivePreviewIntent = {
        type: "move-table-cell",
        ...identity,
        from: last.from,
        to: last.to,
        trusted: true,
        input: "keyboard",
        direction: "forward",
        gestureNonce: null,
      };
      try {
        editor.dispatch({
          selection: EditorSelection.create([
            EditorSelection.cursor(1),
            EditorSelection.cursor(last.from),
          ]),
        });
        const multi = dispatchLivePreviewIntent(
          editor,
          intent,
          guard,
          last,
          new GestureNonceLedger(),
          productHrefAllowed,
          cells,
        );
        expect(multi.cm6Transactions).toBe(0);
        expect(editor.state.doc.toString()).toBe(source);

        editor.dispatch({ selection: EditorSelection.cursor(last.from) });
        const atCap = dispatchLivePreviewIntent(
          editor,
          intent,
          guard,
          last,
          new GestureNonceLedger(),
          productHrefAllowed,
          cells,
        );
        expect(atCap.cm6Transactions).toBe(0);
        expect(atCap.result).toEqual({ type: "rejected", reason: "invalid-intent" });
        expect(editor.state.doc.toString()).toBe(source);

        const staleGeometry = dispatchLivePreviewIntent(
          editor,
          { ...intent, from: last.from - 1 },
          guard,
          last,
          new GestureNonceLedger(),
          productHrefAllowed,
          cells,
        );
        expect(staleGeometry.cm6Transactions).toBe(0);

        const stalePrefix = { ...last, appendPrefixTo: last.appendPrefixTo + 1 };
        const stalePrefixResult = dispatchLivePreviewIntent(
          editor,
          { ...intent, from: stalePrefix.from, to: stalePrefix.to },
          guard,
          stalePrefix,
          new GestureNonceLedger(),
          productHrefAllowed,
          cells,
        );
        expect(stalePrefixResult.cm6Transactions).toBe(0);
        expect(editor.state.doc.toString()).toBe(source);
      } finally {
        editor.destroy();
      }
    });
  });

  test("rejects synthetic pointer and keyboard events at capture without issuing intents", () => {
    withEditorDom((dom) => {
      const revisions = new EditorRevisionClock();
      const intents: LivePreviewIntent[] = [];
      let controller: EditableProjectionController | null = null;
      const editor = createMarkdownEditor(
        dom.window.document.querySelector("main") as HTMLElement,
        "- [ ] todo\n\n[label](next.md)",
        (update) => {
          if (update.docChanged) revisions.documentChanged();
          controller?.handleUpdate(update);
        },
        () => {},
      );
      controller = new EditableProjectionController(
        editor,
        1,
        revisions,
        () => {},
        (intent) => {
          intents.push(intent);
        },
      );
      try {
        controller.enable();
        const task = editor.dom.querySelector(".maru-projection-task");
        const link = editor.dom.querySelector(".maru-projection-link");
        if (task === null || link === null) throw new Error("projection marks were not mounted");
        task.dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true, button: 0 }));
        link.dispatchEvent(
          new dom.window.MouseEvent("mousedown", {
            bubbles: true,
            button: 0,
            metaKey: true,
          }),
        );
        editor.dispatch({ selection: EditorSelection.cursor(3) });
        editor.dom.dispatchEvent(
          new dom.window.KeyboardEvent("keydown", {
            bubbles: true,
            key: "Enter",
            metaKey: true,
          }),
        );
        expect(intents).toHaveLength(0);
        expect(editor.state.doc.toString()).toBe("- [ ] todo\n\n[label](next.md)");
      } finally {
        controller.destroy();
        editor.destroy();
      }
    });
  });

  test("rejects capture-time composition and repeated keyboard activation permanently", () => {
    expect(livePreviewGestureCaptureAllowed(true, false)).toBe(true);
    expect(livePreviewGestureCaptureAllowed(true, true)).toBe(false);
    expect(livePreviewGestureCaptureAllowed(true, false, true)).toBe(false);
    expect(livePreviewGestureCaptureAllowed(false, false)).toBe(false);
  });

  test("uses one pure table-key classifier for controller capture semantics", () => {
    const first: Extract<ProjectionEntry, { type: "table-cell" }> = {
      type: "table-cell",
      tableFrom: 0,
      tableTo: 30,
      appendPrefixFrom: 20,
      appendPrefixTo: 20,
      from: 1,
      to: 4,
      row: 0,
      column: 0,
      rowCount: 2,
      columnCount: 2,
    };
    const last = { ...first, from: 25, to: 28, row: 1, column: 1 };
    const event = (key: string, shiftKey = false) => ({
      key,
      shiftKey,
      metaKey: false,
      ctrlKey: false,
      altKey: false,
    });
    expect(livePreviewTableKeyIntent(first, event("Tab"))).toEqual({
      type: "move-table-cell",
      direction: "forward",
    });
    expect(livePreviewTableKeyIntent(first, event("Tab", true))).toEqual({
      type: "move-table-cell",
      direction: "backward",
    });
    expect(livePreviewTableKeyIntent(first, event("Enter"))).toEqual({
      type: "move-table-cell",
      direction: "down",
    });
    expect(livePreviewTableKeyIntent(last, event("Enter"))).toEqual({
      type: "append-table-row",
    });
    expect(livePreviewTableKeyIntent(first, { ...event("Enter"), shiftKey: true })).toBeNull();
    expect(livePreviewTableKeyIntent(first, { ...event("Tab"), metaKey: true })).toBeNull();
  });

  test("captures table keys through the product controller and rejects unsafe capture states", () => {
    withEditorDom((dom) => {
      const source = "| A | B |\n| --- | --- |\n| c | d |";
      const revisions = new EditorRevisionClock();
      const intents: LivePreviewIntent[] = [];
      let controller: EditableProjectionController | null = null;
      const editor = createMarkdownEditor(
        dom.window.document.querySelector("main") as HTMLElement,
        source,
        (update) => {
          if (update.docChanged) revisions.documentChanged();
          controller?.handleUpdate(update);
        },
        () => {},
      );
      controller = new EditableProjectionController(
        editor,
        7,
        revisions,
        () => {},
        (intent) => {
          intents.push(intent);
        },
      );
      const event = (
        overrides: Partial<Parameters<EditableProjectionController["tableKeyCapture"]>[0]> = {},
      ) => ({
        key: "Tab",
        shiftKey: false,
        metaKey: false,
        ctrlKey: false,
        altKey: false,
        trusted: true,
        composing: false,
        repeat: false,
        ...overrides,
      });
      try {
        controller.enable();
        const cells = buildEditableProjection(editor.state, {
          from: 0,
          to: editor.state.doc.length,
        }).entries.filter(
          (entry): entry is Extract<ProjectionEntry, { type: "table-cell" }> =>
            entry.type === "table-cell",
        );
        const first = cells[0];
        if (first === undefined) throw new Error("missing controller table cell");
        editor.dispatch({ selection: EditorSelection.cursor(first.from) });
        const capture = controller.tableKeyCapture(event());
        expect(capture.owned).toBe(true);
        expect(capture.intent).toEqual(
          expect.objectContaining({
            type: "move-table-cell",
            direction: "forward",
            editorEpoch: 7,
            from: first.from,
            to: first.to,
            trusted: true,
          }),
        );
        expect(controller.tableKeyCapture(event({ trusted: false }))).toEqual({
          owned: true,
          intent: null,
        });
        expect(controller.tableKeyCapture(event({ composing: true }))).toEqual({
          owned: true,
          intent: null,
        });
        expect(controller.tableKeyCapture(event({ repeat: true }))).toEqual({
          owned: true,
          intent: null,
        });
        expect(controller.tableKeyCapture(event({ metaKey: true }))).toEqual({
          owned: false,
          intent: null,
        });
        const commandEnter = new dom.window.KeyboardEvent("keydown", {
          bubbles: true,
          cancelable: true,
          key: "Enter",
          metaKey: true,
        });
        editor.dom.dispatchEvent(commandEnter);
        expect(commandEnter.defaultPrevented).toBe(false);
        expect(intents).toHaveLength(0);
        editor.dispatch({
          selection: EditorSelection.create([
            EditorSelection.cursor(first.from),
            EditorSelection.cursor(cells[1]?.from ?? first.from),
          ]),
        });
        expect(controller.tableKeyCapture(event())).toEqual({ owned: false, intent: null });
      } finally {
        controller.destroy();
        editor.destroy();
      }
    });
  });

  test("uses the product link policy for local and external destinations", () => {
    for (const href of ["next.md", "../guide/next.html#usage", "https://example.com/guide"])
      expect(productHrefAllowed(href)).toBe(true);
    for (const href of [
      "javascript:payload.md",
      "data:text/html,guide.md",
      "file:///tmp/guide.md",
      "//example.com/guide.md",
      "https://example.com/line\nbreak",
    ])
      expect(productHrefAllowed(href)).toBe(false);
  });

  test("rejects a cap-plus-one link destination before slicing source", () => {
    withEditorDom((dom) => {
      const editor = createMarkdownEditor(
        dom.window.document.querySelector("main") as HTMLElement,
        `${"a".repeat(4_093)}.mdx`,
        () => {},
        () => {},
      );
      const prototype = Object.getPrototypeOf(editor.state) as {
        sliceDoc: (from?: number, to?: number) => string;
      };
      const originalSliceDoc = prototype.sliceDoc;
      let sliceCalls = 0;
      prototype.sliceDoc = function (this: typeof editor.state, from = 0, to = this.doc.length) {
        sliceCalls += 1;
        return originalSliceDoc.call(this, from, to);
      };
      try {
        const exactEntry: ProjectionEntry = {
          type: "link",
          from: 0,
          to: 4_096,
          labelFrom: 0,
          labelTo: 1,
          destinationFrom: 0,
          destinationTo: 4_096,
        };
        const exactIntent: LivePreviewIntent = {
          type: "activate-link",
          ...identity,
          from: exactEntry.from,
          to: exactEntry.to,
          trusted: true,
          disposition: "command-pointer",
          gestureNonce: 1,
        };
        expect(
          dispatchLivePreviewIntent(
            editor,
            exactIntent,
            guard,
            exactEntry,
            new GestureNonceLedger(),
            () => true,
            [],
          ).externalActions,
        ).toBe(1);
        expect(sliceCalls).toBe(1);

        const tooLongEntry: ProjectionEntry = {
          ...exactEntry,
          to: 4_097,
          destinationTo: 4_097,
        };
        expect(
          dispatchLivePreviewIntent(
            editor,
            { ...exactIntent, to: 4_097, gestureNonce: 2 },
            guard,
            tooLongEntry,
            new GestureNonceLedger(),
            () => true,
            [],
          ),
        ).toEqual({
          result: { type: "rejected", reason: "invalid-intent" },
          externalAction: null,
          cm6Transactions: 0,
          externalActions: 0,
        });
        expect(sliceCalls).toBe(1);
      } finally {
        prototype.sliceDoc = originalSliceDoc;
        editor.destroy();
      }
    });
  });

  test("bounds retained intents and recovers after clearing a stalled bridge backlog", async () => {
    let release!: () => void;
    const stalled = new Promise<void>((resolve) => {
      release = resolve;
    });
    let runnerCalls = 0;
    const queue = new BoundedLivePreviewIntentQueue(async () => {
      runnerCalls += 1;
      await stalled;
    });
    const intent: LivePreviewIntent = {
      type: "toggle-task",
      ...identity,
      from: 0,
      to: 3,
      trusted: true,
      input: "pointer",
      gestureNonce: null,
    };
    for (let index = 0; index < maxRetainedLivePreviewIntents; index += 1)
      expect(queue.enqueue(intent)).toBe(true);
    expect(queue.enqueue(intent)).toBe(false);
    expect(runnerCalls).toBe(1);
    expect(queue.metrics()).toEqual({
      retained: maxRetainedLivePreviewIntents,
      maxRetained: maxRetainedLivePreviewIntents,
      dropped: 1,
      completed: 0,
    });
    expect(queue.clearPending()).toBe(maxRetainedLivePreviewIntents - 1);
    expect(queue.metrics().retained).toBe(1);
    release();
    for (let turn = 0; turn < 4; turn += 1) await Promise.resolve();
    expect(queue.metrics()).toEqual({
      retained: 0,
      maxRetained: maxRetainedLivePreviewIntents,
      dropped: 1,
      completed: 1,
    });
    queue.destroy();
  });

  test("publishes the exact retained count when the next runner stalls", async () => {
    let releaseFirst!: () => void;
    let releaseSecond!: () => void;
    const first = new Promise<void>((resolve) => {
      releaseFirst = resolve;
    });
    const second = new Promise<void>((resolve) => {
      releaseSecond = resolve;
    });
    let calls = 0;
    const snapshots: Array<{ retained: number; completed: number }> = [];
    const queue = new BoundedLivePreviewIntentQueue(
      async () => {
        calls += 1;
        await (calls === 1 ? first : second);
      },
      () => {},
      (metrics) => snapshots.push(metrics),
    );
    const intent: LivePreviewIntent = {
      type: "toggle-task",
      ...identity,
      from: 0,
      to: 3,
      trusted: true,
      input: "pointer",
      gestureNonce: null,
    };
    expect(queue.enqueue(intent)).toBe(true);
    expect(queue.enqueue(intent)).toBe(true);
    releaseFirst();
    for (let turn = 0; turn < 4; turn += 1) await Promise.resolve();
    expect(calls).toBe(2);
    expect(snapshots.at(-1)).toEqual(expect.objectContaining({ retained: 1, completed: 1 }));
    expect(
      snapshots
        .filter((snapshot) => snapshot.completed >= 1)
        .every((snapshot) => snapshot.retained <= 1),
    ).toBe(true);
    releaseSecond();
    for (let turn = 0; turn < 4; turn += 1) await Promise.resolve();
    expect(snapshots.at(-1)).toEqual(expect.objectContaining({ retained: 0, completed: 2 }));
    expect(snapshots.every((snapshot) => snapshot.retained <= maxRetainedLivePreviewIntents)).toBe(
      true,
    );
    queue.destroy();
  });

  test("coordinates current entry validation, CM6 commit, and epoch-scoped mailbox exactly once", async () => {
    await withEditorDom(async (dom) => {
      const editor = createMarkdownEditor(
        dom.window.document.querySelector("main") as HTMLElement,
        "- [ ] task\n\n[label](next.md)",
        () => {},
        () => {},
      );
      const entries = buildEditableProjection(editor.state, {
        from: 0,
        to: editor.state.doc.length,
      }).entries;
      const task = entryOfType(entries, "task");
      const link = entryOfType(entries, "link");
      let documentQueue = Promise.resolve();
      const scheduleDocumentOperation = <T>(operation: () => T): Promise<T> => {
        const scheduled = documentQueue.then(operation);
        documentQueue = scheduled.then(
          () => undefined,
          () => undefined,
        );
        return scheduled;
      };
      const requests: unknown[] = [];
      const listener = () => {
        const node = dom.window.document.querySelector<HTMLElement>(
          '[data-maru-file-request="pending"]',
        );
        if (node === null) return;
        requests.push(JSON.parse(node.textContent ?? "null"));
        node.textContent = JSON.stringify({ jsonrpc: "2.0", id: 1, result: { opened: true } });
        node.dataset.maruFileRequest = "done";
        dom.window.document.dispatchEvent(new dom.window.Event("maru:file-response"));
      };
      dom.window.document.addEventListener("maru:file-request", listener);
      const dispatches: Array<{ cm6Transactions: number; externalActions: number }> = [];
      const metricSnapshots: Array<{ retained: number; completed: number }> = [];
      const coordinator = new LivePreviewIntentCoordinator({
        scheduleDocumentOperation,
        currentContext: (intent) => ({
          view: editor,
          guard,
          currentEntry:
            intent.type === "toggle-task" ? task : intent.type === "activate-link" ? link : null,
          currentTableCells: [],
        }),
        hrefAllowed: productHrefAllowed,
        openExternalAction: async (intent, action) => {
          await requestFileBridge(dom.window.document, "openLink", {
            editor_epoch: intent.editorEpoch,
            href: action.href,
            forceSystem: action.forceSystem,
          });
        },
        onDispatch: (dispatch) => dispatches.push(dispatch),
        onMetricsChanged: (metrics) => metricSnapshots.push(metrics),
      });
      try {
        expect(
          coordinator.enqueue({
            type: "toggle-task",
            ...identity,
            from: task.from,
            to: task.to,
            trusted: true,
            input: "pointer",
            gestureNonce: null,
          }),
        ).toBe(true);
        expect(
          coordinator.enqueue({
            type: "activate-link",
            ...identity,
            from: link.from,
            to: link.to,
            trusted: true,
            disposition: "command-pointer",
            gestureNonce: 1,
          }),
        ).toBe(true);
        for (let turn = 0; turn < 8; turn += 1) await Promise.resolve();
        expect(editor.state.doc.toString()).toBe("- [x] task\n\n[label](next.md)");
        expect(dispatches).toEqual([
          expect.objectContaining({ cm6Transactions: 1, externalActions: 0 }),
          expect.objectContaining({ cm6Transactions: 0, externalActions: 1 }),
        ]);
        expect(requests).toEqual([
          {
            method: "openLink",
            editor_epoch: 1,
            href: "next.md",
            forceSystem: false,
          },
        ]);
        expect(coordinator.metrics()).toEqual({
          retained: 0,
          maxRetained: 2,
          dropped: 0,
          completed: 2,
        });
        expect(metricSnapshots.at(-1)).toEqual(
          expect.objectContaining({ retained: 0, completed: 2 }),
        );
      } finally {
        coordinator.destroy();
        dom.window.document.removeEventListener("maru:file-request", listener);
        editor.destroy();
      }
    });
  });

  test("keeps document operations live, republishes clear, and drains after bridge failure", async () => {
    await withEditorDom(async (dom) => {
      const editor = createMarkdownEditor(
        dom.window.document.querySelector("main") as HTMLElement,
        "- [ ] task\n\n[label](next.md)",
        () => {},
        () => {},
      );
      const entries = buildEditableProjection(editor.state, {
        from: 0,
        to: editor.state.doc.length,
      }).entries;
      const task = entryOfType(entries, "task");
      const link = entryOfType(entries, "link");
      let documentQueue = Promise.resolve();
      const scheduleDocumentOperation = <T>(operation: () => T): Promise<T> => {
        const scheduled = documentQueue.then(operation);
        documentQueue = scheduled.then(
          () => undefined,
          () => undefined,
        );
        return scheduled;
      };
      let failBridge!: (error: Error) => void;
      const stalledBridge = new Promise<void>((_resolve, reject) => {
        failBridge = reject;
      });
      let errors = 0;
      const metricSnapshots: Array<{ retained: number; completed: number }> = [];
      const coordinator = new LivePreviewIntentCoordinator({
        scheduleDocumentOperation,
        currentContext: (intent) => ({
          view: editor,
          guard,
          currentEntry: intent.type === "activate-link" ? link : task,
          currentTableCells: [],
        }),
        hrefAllowed: productHrefAllowed,
        openExternalAction: () => stalledBridge,
        onError: () => {
          errors += 1;
        },
        onMetricsChanged: (metrics) => metricSnapshots.push(metrics),
      });
      const linkIntent: LivePreviewIntent = {
        type: "activate-link",
        ...identity,
        from: link.from,
        to: link.to,
        trusted: true,
        disposition: "command-pointer",
        gestureNonce: 1,
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
      try {
        expect(coordinator.enqueue(linkIntent)).toBe(true);
        expect(coordinator.enqueue(taskIntent)).toBe(true);
        await Promise.resolve();
        let saveReached = false;
        await scheduleDocumentOperation(() => {
          saveReached = true;
        });
        expect(saveReached).toBe(true);
        expect(coordinator.clearPending()).toBe(1);
        expect(metricSnapshots.at(-1)).toEqual(
          expect.objectContaining({ retained: 1, completed: 0 }),
        );
        failBridge(new Error("bridge failed"));
        for (let turn = 0; turn < 6; turn += 1) await Promise.resolve();
        expect(errors).toBe(1);
        expect(editor.state.doc.toString()).toBe("- [ ] task\n\n[label](next.md)");
        expect(metricSnapshots.at(-1)).toEqual(
          expect.objectContaining({ retained: 0, completed: 1 }),
        );

        expect(coordinator.enqueue(taskIntent)).toBe(true);
        for (let turn = 0; turn < 4; turn += 1) await Promise.resolve();
        expect(editor.state.doc.toString()).toBe("- [x] task\n\n[label](next.md)");
        expect(coordinator.metrics()).toEqual(
          expect.objectContaining({ retained: 0, completed: 2 }),
        );
      } finally {
        coordinator.destroy();
        editor.destroy();
      }
    });
  });
});
