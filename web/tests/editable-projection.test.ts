import { describe, expect, test } from "bun:test";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { EditorSelection, EditorState, Transaction } from "@codemirror/state";
import {
  buildEditableProjection,
  editableProjectionBudget,
  editableProjectionWindow,
} from "../src/editable-projection";
import {
  EditableProjectionController,
  reconcileEditableProjectionDecorations,
} from "../src/editable-projection-view";
import { createMarkdownEditor } from "../src/editor";
import type { ProjectionEntry } from "../src/live-preview-projection";
import { EditorRevisionClock } from "../src/live-preview-state";
import { createLivePreviewDiagnosticsSnapshot } from "../src/live-preview-diagnostics";
import {
  maruMathMarkdownExtension,
  maxMathDelimiterScanCodeUnits,
  startMathDelimiterScanProbe,
} from "../src/markdown-language";
import { maxLivePreviewTableCells } from "../src/live-preview-projection";
import { withEditorDom } from "./editor-dom";

function markdownState(doc: string, selection = doc.length): EditorState {
  return EditorState.create({
    doc,
    selection: EditorSelection.cursor(selection),
    extensions: [
      EditorState.allowMultipleSelections.of(true),
      markdown({ base: markdownLanguage, extensions: maruMathMarkdownExtension }),
    ],
  });
}

function project(doc: string, selection = doc.length) {
  const state = markdownState(doc, selection);
  return buildEditableProjection(state, { from: 0, to: state.doc.length });
}

function hasEntry(
  entries: readonly ProjectionEntry[],
  expected: Partial<ProjectionEntry> & Pick<ProjectionEntry, "type">,
): boolean {
  return entries.some((entry) =>
    Object.entries(expected).every(([key, value]) => entry[key as keyof ProjectionEntry] === value),
  );
}

describe("CM6 editable Markdown projection", () => {
  test("derives style and hidden marker roles from the incremental GFM tree", () => {
    const source =
      "# Heading\n\n*em* **strong** ~~strike~~ `code`\\*\n\n> quote\n\n- item\n\n---\n\nplain";
    const result = project(source);
    expect(hasEntry(result.entries, { type: "style", role: "heading-1" })).toBe(true);
    expect(hasEntry(result.entries, { type: "style", role: "emphasis" })).toBe(true);
    expect(hasEntry(result.entries, { type: "style", role: "strong" })).toBe(true);
    expect(hasEntry(result.entries, { type: "style", role: "strike" })).toBe(true);
    expect(hasEntry(result.entries, { type: "style", role: "inline-code" })).toBe(true);
    expect(hasEntry(result.entries, { type: "style", role: "quote" })).toBe(true);
    expect(hasEntry(result.entries, { type: "style", role: "list" })).toBe(true);
    expect(hasEntry(result.entries, { type: "style", role: "thematic-break" })).toBe(true);
    for (const role of [
      "heading-marker",
      "emphasis-marker",
      "strong-marker",
      "strike-marker",
      "code-fence",
      "quote-marker",
      "list-marker",
      "escape",
    ] as const) {
      expect(hasEntry(result.entries, { type: "hidden-syntax", role })).toBe(true);
    }
  });

  test("reveals only the syntax owned by every intersecting selection range", () => {
    const source = "# one\n\n*two* and `three`\n\nplain";
    let state = markdownState(source);
    state = state.update({
      selection: EditorSelection.create([
        EditorSelection.cursor(3),
        EditorSelection.range(source.indexOf("two"), source.indexOf("two") + 3),
        EditorSelection.cursor(source.indexOf("three") + 2),
      ]),
    }).state;
    const result = buildEditableProjection(state, { from: 0, to: state.doc.length });
    expect(hasEntry(result.entries, { type: "hidden-syntax", role: "heading-marker" })).toBe(false);
    expect(hasEntry(result.entries, { type: "hidden-syntax", role: "emphasis-marker" })).toBe(
      false,
    );
    expect(hasEntry(result.entries, { type: "hidden-syntax", role: "code-fence" })).toBe(false);
    expect(result.activeSourceRangeCount).toBeGreaterThan(0);
  });

  test("uses label-only and destination reveal rules for links", () => {
    const source = "before [label](destination) after";
    const linkFrom = source.indexOf("[");
    const label = project(source, source.indexOf("label") + 2);
    expect(hasEntry(label.entries, { type: "link" })).toBe(true);
    expect(hasEntry(label.entries, { type: "hidden-syntax", role: "link-destination" })).toBe(true);
    expect(hasEntry(label.entries, { type: "hidden-syntax", role: "link-bracket" })).toBe(false);

    const destination = project(source, source.indexOf("destination") + 2);
    expect(hasEntry(destination.entries, { type: "hidden-syntax", role: "link-destination" })).toBe(
      false,
    );
    expect(destination.activeSourceRanges.some(({ from }) => from === linkFrom)).toBe(true);

    const inactive = project(`${source}\n\nplain`);
    expect(hasEntry(inactive.entries, { type: "hidden-syntax", role: "link-bracket" })).toBe(true);
    expect(hasEntry(inactive.entries, { type: "hidden-syntax", role: "link-destination" })).toBe(
      true,
    );
  });

  test("keeps empty link labels as source without throwing in the CM6 adapter", () => {
    for (const source of ["[](x)", "[](<x>)"]) {
      const projection = project(source);
      expect(projection.entries.some(({ type }) => type === "link")).toBe(false);
      expect(projection.fallbackCounts["ambiguous-syntax"]).toBe(1);
    }
    const emptyDestination = project("[x]()");
    expect(emptyDestination.entries.some(({ type }) => type === "link")).toBe(false);
    expect(emptyDestination.fallbackCounts["ambiguous-syntax"]).toBe(1);
    expect(project("[x](y)").entries.some(({ type }) => type === "link")).toBe(true);

    withEditorDom((dom) => {
      const revisions = new EditorRevisionClock();
      let controller: EditableProjectionController | null = null;
      const editor = createMarkdownEditor(
        dom.window.document.querySelector("main") as HTMLElement,
        "[x](y)\n\nplain",
        (update) => {
          if (update.docChanged) revisions.documentChanged();
          controller?.handleUpdate(update);
        },
        () => {},
      );
      controller = new EditableProjectionController(editor, 1, revisions);
      try {
        expect(() => controller?.enable()).not.toThrow();
        expect(editor.dom.querySelector(".maru-projection-link")).not.toBeNull();
        expect(() => editor.dispatch({ changes: { from: 1, to: 2, insert: "" } })).not.toThrow();
        expect(editor.dom.querySelector(".maru-projection-link")).toBeNull();
        expect(() => editor.dispatch({ changes: { from: 1, insert: "z" } })).not.toThrow();
        expect(editor.dom.querySelector(".maru-projection-link")).not.toBeNull();
      } finally {
        controller.destroy();
        editor.destroy();
      }
    });
  });

  test("classifies task, table, and rich atomic ranges without rendering HTML", () => {
    const source =
      "- [x] done\n\n| A | B |\n| - | - |\n| c | d |\n\n$inline$\n\n$$\nblock math\n$$\n\n![alt](image.png)\n\n```mermaid\ngraph TD\n```\n\nplain";
    const result = project(source);
    expect(hasEntry(result.entries, { type: "task", checked: true })).toBe(true);
    const tableCells = result.entries.filter(({ type }) => type === "table-cell");
    expect(tableCells).toHaveLength(4);
    expect(tableCells).toEqual([
      expect.objectContaining({
        type: "table-cell",
        row: 0,
        column: 0,
        rowCount: 2,
        columnCount: 2,
      }),
      expect.objectContaining({ type: "table-cell", row: 0, column: 1 }),
      expect.objectContaining({ type: "table-cell", row: 1, column: 0 }),
      expect.objectContaining({ type: "table-cell", row: 1, column: 1 }),
    ]);
    expect(new Set(tableCells.map(({ tableFrom }) => tableFrom))).toEqual(new Set([12]));
    expect(new Set(tableCells.map(({ tableTo }) => tableTo))).toEqual(
      new Set([source.indexOf("\n\n$inline$")]),
    );
    expect(hasEntry(result.entries, { type: "atomic", role: "image" })).toBe(true);
    expect(
      result.entries.filter(({ type, role }) => type === "atomic" && role === "math"),
    ).toHaveLength(2);
    expect(hasEntry(result.entries, { type: "atomic", role: "mermaid" })).toBe(true);
    expect(result.fallbackCounts["atomic-not-enabled"]).toBe(4);
    expect(JSON.stringify(result)).not.toContain("<iframe");
    expect(JSON.stringify(result)).not.toContain("<img");
  });

  test("keeps ambiguous dollar syntax as source and bounds unclosed delimiter scans", () => {
    for (const source of [
      "$5 and $10",
      "$ inline$",
      "$inline $",
      "$$inline block$$",
      String.raw`\$escaped$`,
      "`$code$`",
      "```\n$code$\n```",
    ]) {
      expect(
        project(source).entries.some(({ type, role }) => type === "atomic" && role === "math"),
      ).toBe(false);
    }
    expect(
      project("$inline$\n\n$$\nblock\n$$").entries.filter(
        ({ type, role }) => type === "atomic" && role === "math",
      ),
    ).toHaveLength(2);

    const exactProbe = startMathDelimiterScanProbe();
    const exact = project(`$${"a".repeat(maxMathDelimiterScanCodeUnits - 1)}$`);
    const exactScanned = exactProbe.stop();
    expect(exact.entries.some(({ type, role }) => type === "atomic" && role === "math")).toBe(true);
    expect(exactScanned).toBeLessThanOrEqual(maxMathDelimiterScanCodeUnits);

    const overProbe = startMathDelimiterScanProbe();
    const over = project(`$${"a".repeat(maxMathDelimiterScanCodeUnits)}$`);
    const overScanned = overProbe.stop();
    expect(over.entries.some(({ type, role }) => type === "atomic" && role === "math")).toBe(false);
    expect(overScanned).toBe(maxMathDelimiterScanCodeUnits);

    for (const source of [
      "$1".repeat(maxMathDelimiterScanCodeUnits),
      "$x ".repeat(maxMathDelimiterScanCodeUnits / 3),
      String.raw`$x\$ `.repeat(maxMathDelimiterScanCodeUnits / 4),
    ]) {
      const denseProbe = startMathDelimiterScanProbe();
      const dense = project(source);
      const denseScanned = denseProbe.stop();
      expect(denseScanned).toBeLessThanOrEqual(maxMathDelimiterScanCodeUnits);
      expect(dense.entries.some(({ type, role }) => type === "atomic" && role === "math")).toBe(
        false,
      );
    }
  });

  test("admits the exact table-cell cap and falls the whole table back at cap plus one", () => {
    const table = (cellCount: number) =>
      `| h |\n| - |\n${Array.from({ length: cellCount - 1 }, () => "| x |\n").join("")}`.trimEnd();
    const exact = project(table(maxLivePreviewTableCells));
    expect(exact.entries.filter(({ type }) => type === "table-cell")).toHaveLength(
      maxLivePreviewTableCells,
    );
    expect(exact.fallbackCounts["table-limit"]).toBe(0);

    const source = table(maxLivePreviewTableCells + 1);
    const over = project(source);
    expect(over.entries.filter(({ type }) => type === "table-cell")).toHaveLength(0);
    expect(over.fallbackCounts["table-limit"]).toBe(1);
    expect(over.activeSourceRanges).toEqual([{ from: 0, to: source.length }]);
  });

  test("derives empty and escaped cells from syntax delimiters and rejects ragged geometry", () => {
    const exactSource = "| A | B |\n| - | - |\n|   | c\\|d |";
    const exact = project(exactSource);
    const exactCells = exact.entries.filter(({ type }) => type === "table-cell");
    expect(exactCells).toHaveLength(4);
    expect(exactCells[2]).toEqual(
      expect.objectContaining({
        type: "table-cell",
        row: 1,
        column: 0,
        from: exactSource.indexOf("|   |") + 1,
        to: exactSource.indexOf("|   |") + 4,
      }),
    );
    expect(exactCells[3]).toEqual(
      expect.objectContaining({
        type: "table-cell",
        row: 1,
        column: 1,
        from: exactSource.indexOf("c\\|d") - 1,
        to: exactSource.indexOf("c\\|d") + 5,
      }),
    );
    expect(exact.fallbackCounts["ambiguous-syntax"]).toBe(0);

    const raggedSource = "| A | B |\n| - | - |\n| only-one |";
    const ragged = project(raggedSource);
    expect(ragged.entries.filter(({ type }) => type === "table-cell")).toHaveLength(0);
    expect(ragged.fallbackCounts["ambiguous-syntax"]).toBe(1);
    expect(ragged.activeSourceRanges).toEqual([{ from: 0, to: raggedSource.length }]);
  });

  test("projects all four valid GFM outer-pipe forms into the same rectangular geometry", () => {
    for (const source of [
      "| A | B |\n| --- | --- |\n| c | d |",
      "| A | B\n| --- | ---\n| c | d",
      "A | B |\n--- | --- |\nc | d |",
      "A | B\n--- | ---\nc | d",
    ]) {
      const result = project(source);
      const cells = result.entries.filter(({ type }) => type === "table-cell");
      expect(cells).toHaveLength(4);
      expect(cells.map(({ row, column }) => [row, column])).toEqual([
        [0, 0],
        [0, 1],
        [1, 0],
        [1, 1],
      ]);
      expect(cells.every(({ rowCount, columnCount }) => rowCount === 2 && columnCount === 2)).toBe(
        true,
      );
      expect(result.fallbackCounts["ambiguous-syntax"]).toBe(0);
    }
  });

  test("finds a syntax owner across many cursors with logarithmic selection checks", () => {
    const source = `# heading\n${"plain ".repeat(2_048)}`;
    let state = markdownState(source);
    state = state.update({
      selection: EditorSelection.create(
        Array.from({ length: 1_024 }, (_, index) =>
          EditorSelection.cursor("# heading\n".length + index * 6),
        ),
      ),
    }).state;
    const projection = buildEditableProjection(state, { from: 0, to: state.doc.length });
    expect(projection.metrics.selectionRangeChecks).toBeGreaterThan(0);
    expect(projection.metrics.selectionRangeChecks).toBeLessThanOrEqual(12);
  });

  test("reuses 4,095 decoration identities when one of 4,096 entries changes", () => {
    const entries = Array.from({ length: 4_096 }, (_, index) => ({
      type: "style" as const,
      role: "emphasis" as const,
      from: index * 2,
      to: index * 2 + 1,
    }));
    const initial = reconcileEditableProjectionDecorations([], entries);
    const changed = [...entries];
    changed[changed.length - 1] = {
      ...changed[changed.length - 1]!,
      role: "strong",
    };
    const next = reconcileEditableProjectionDecorations(initial.records, changed);
    expect(next.comparisons).toBe(4_096);
    expect(next.createdDecorations).toBe(1);
    expect(next.remove.size).toBe(1);
    expect(next.add).toHaveLength(1);
    for (let index = 0; index < changed.length - 1; index += 1)
      expect(next.records[index]).toBe(initial.records[index]);
  });

  test("stops at the same node and entry exact-cap boundary used by production", () => {
    const source = "# h\n\n*one* **two** ~~three~~ [label](dest)\n\nplain";
    const state = markdownState(source);
    const baseline = buildEditableProjection(state, { from: 0, to: state.doc.length });
    expect(baseline.metrics.visitedSyntaxNodes).toBeGreaterThan(1);
    expect(baseline.entries.length).toBeGreaterThan(1);

    const exactNodes = buildEditableProjection(
      state,
      { from: 0, to: state.doc.length },
      { ...editableProjectionBudget, maxSyntaxNodes: baseline.metrics.visitedSyntaxNodes },
    );
    const overNodes = buildEditableProjection(
      state,
      { from: 0, to: state.doc.length },
      { ...editableProjectionBudget, maxSyntaxNodes: baseline.metrics.visitedSyntaxNodes - 1 },
    );
    expect(exactNodes.fallbackCounts["projection-limit"]).toBe(0);
    expect(overNodes.fallbackCounts["projection-limit"]).toBe(1);

    const exactEntries = buildEditableProjection(
      state,
      { from: 0, to: state.doc.length },
      { ...editableProjectionBudget, maxEntries: baseline.entries.length },
    );
    const overEntries = buildEditableProjection(
      state,
      { from: 0, to: state.doc.length },
      { ...editableProjectionBudget, maxEntries: baseline.entries.length - 1 },
    );
    expect(exactEntries.fallbackCounts["projection-limit"]).toBe(0);
    expect(overEntries.fallbackCounts["projection-limit"]).toBe(1);
    expect(overEntries.activeSourceRanges).toEqual([{ from: 0, to: state.doc.length }]);
    expect(overEntries.activeSourceRangeCount).toBe(1);
    for (const [reason, count] of Object.entries(overEntries.fallbackCounts))
      expect(count).toBe(reason === "projection-limit" ? 1 : 0);
  });

  test("keeps Select All discovery inside the shared UTF-16 hard ceiling", () => {
    const source = "a".repeat(editableProjectionBudget.maxCodeUnits * 2);
    const state = markdownState(source).update({
      selection: EditorSelection.range(0, source.length),
    }).state;
    const window = editableProjectionWindow({
      state,
      viewport: { from: 0, to: source.length },
    } as never);
    expect(window.to - window.from).toBe(editableProjectionBudget.maxCodeUnits);
    const result = buildEditableProjection(state, window);
    expect(result.metrics.visitedCodeUnits).toBe(editableProjectionBudget.maxCodeUnits);
  });

  test("keeps a syntax owner that crosses the discovery window entirely as source", () => {
    const state = markdownState(`# ${"a".repeat(100)}`);
    const result = buildEditableProjection(state, { from: 40, to: 60 });
    expect(result.entries).toEqual([]);
    expect(result.fallbackCounts["projection-limit"]).toBe(1);
    expect(result.activeSourceRanges).toEqual([{ from: 40, to: 60 }]);
  });

  test("applies fixed-class decorations, skips identical commits, and creates no iframe", () => {
    withEditorDom((dom) => {
      const revisions = new EditorRevisionClock();
      const editor = createMarkdownEditor(
        dom.window.document.querySelector("main") as HTMLElement,
        "# heading\n\nplain",
        (update) => {
          if (update.docChanged) revisions.documentChanged();
          controller?.handleUpdate(update);
        },
        () => {},
      );
      let controller: EditableProjectionController | null = new EditableProjectionController(
        editor,
        1,
        revisions,
      );
      try {
        editor.dispatch({ selection: EditorSelection.cursor(editor.state.doc.length) });
        controller.enable();
        expect(editor.dom.querySelector(".maru-projection-heading-1")).not.toBeNull();
        expect(editor.dom.querySelector("iframe")).toBeNull();
        const before = controller.metrics().projectionTransactions;
        editor.dispatch({ selection: editor.state.selection });
        expect(controller.metrics().projectionTransactions).toBe(before);
      } finally {
        controller.destroy();
        controller = null;
        editor.destroy();
      }
    });
  });

  test("reuses table groups for selection-only projection and rebuilds once after a document change", () => {
    withEditorDom((dom) => {
      const revisions = new EditorRevisionClock();
      const source = "| A | B |\n| - | - |\n| c | d |";
      const editor = createMarkdownEditor(
        dom.window.document.querySelector("main") as HTMLElement,
        source,
        (update) => {
          if (update.docChanged) revisions.documentChanged();
          controller?.handleUpdate(update);
        },
        () => {},
      );
      let controller: EditableProjectionController | null = new EditableProjectionController(
        editor,
        1,
        revisions,
      );
      try {
        editor.dispatch({ selection: EditorSelection.cursor(source.indexOf("A")) });
        controller.enable();
        const initial = controller.metrics();
        expect(initial.tableCellRecordCount).toBe(4);

        editor.dispatch({ selection: EditorSelection.cursor(source.indexOf("B")) });
        const selectionOnly = controller.metrics();
        expect(selectionOnly.diffedDecorations - initial.diffedDecorations).toBe(
          initial.projectionRecordCount,
        );
        expect(selectionOnly.tableGroupBuildRecordChecks).toBe(initial.tableGroupBuildRecordChecks);
        expect(selectionOnly.tableGroupCellArraysCreated).toBe(initial.tableGroupCellArraysCreated);

        editor.dispatch({
          changes: { from: source.lastIndexOf("d"), to: source.lastIndexOf("d") + 1, insert: "e" },
        });
        const changed = controller.metrics();
        expect(changed.tableGroupBuildRecordChecks).toBeGreaterThan(
          selectionOnly.tableGroupBuildRecordChecks,
        );
        expect(changed.tableGroupCellArraysCreated).toBe(
          selectionOnly.tableGroupCellArraysCreated + 1,
        );

        editor.contentDOM.dispatchEvent(new dom.window.CompositionEvent("compositionstart"));
        const beforeComposition = controller.metrics();
        editor.dispatch({
          changes: { from: source.lastIndexOf("d"), to: source.lastIndexOf("d") + 1, insert: "f" },
          annotations: Transaction.userEvent.of("input.type.compose"),
        });
        const duringComposition = controller.metrics();
        expect(duringComposition.visitedSyntaxNodes).toBe(beforeComposition.visitedSyntaxNodes);
        expect(duringComposition.tableGroupBuildRecordChecks).toBeGreaterThan(
          beforeComposition.tableGroupBuildRecordChecks,
        );
        expect(duringComposition.tableGroupCellArraysCreated).toBe(
          beforeComposition.tableGroupCellArraysCreated + 1,
        );
        expect(
          controller.tableKeyCapture({
            key: "Tab",
            metaKey: false,
            ctrlKey: false,
            altKey: false,
            shiftKey: false,
            trusted: true,
            composing: false,
            repeat: false,
          }).owned,
        ).toBeTrue();

        editor.contentDOM.dispatchEvent(new dom.window.CompositionEvent("compositionend"));
        const afterComposition = controller.metrics();
        expect(afterComposition.visitedSyntaxNodes).toBeGreaterThan(
          beforeComposition.visitedSyntaxNodes,
        );
        expect(afterComposition.tableGroupBuildRecordChecks).toBe(
          duringComposition.tableGroupBuildRecordChecks,
        );
        expect(afterComposition.tableGroupCellArraysCreated).toBe(
          duringComposition.tableGroupCellArraysCreated,
        );

        controller.disable();
        expect(controller.metrics()).toEqual(
          expect.objectContaining({ projectionRecordCount: 0, tableCellRecordCount: 0 }),
        );
        expect(
          controller.tableKeyCapture({
            key: "Tab",
            metaKey: false,
            ctrlKey: false,
            altKey: false,
            shiftKey: false,
            trusted: true,
            composing: false,
            repeat: false,
          }),
        ).toEqual({ owned: false, intent: null });
      } finally {
        controller.destroy();
        controller = null;
        editor.destroy();
      }
    });
  });

  test("publishes the same advanced interaction and diagnostics identity when disabled", () => {
    withEditorDom((dom) => {
      const revisions = new EditorRevisionClock();
      const diagnostics = createLivePreviewDiagnosticsSnapshot();
      const editor = createMarkdownEditor(
        dom.window.document.querySelector("main") as HTMLElement,
        "- [ ] task",
        () => {},
        () => {},
      );
      const controller = new EditableProjectionController(editor, 7, revisions);
      try {
        controller.enable();
        const before = controller.interactionIdentity();
        controller.disable();
        const after = controller.interactionIdentity();
        controller.writeDiagnostics(diagnostics);
        expect(after).toEqual({
          editorEpoch: 7,
          documentRevision: before.documentRevision,
          projectionGeneration: before.projectionGeneration + 1,
        });
        expect(diagnostics).toEqual(
          expect.objectContaining({
            editorEpoch: after.editorEpoch,
            documentRevision: after.documentRevision,
            projectionGeneration: after.projectionGeneration,
            decorationCount: 0,
          }),
        );
      } finally {
        controller.destroy();
        editor.destroy();
      }
    });
  });

  test("publishes an externally replaced document only after its revision advances", () => {
    withEditorDom((dom) => {
      const revisions = new EditorRevisionClock();
      const committedRevisions: number[] = [];
      let deferredUpdate: Parameters<EditableProjectionController["handleUpdate"]>[0] | null = null;
      let deferProjection = false;
      let controller: EditableProjectionController | null = null;
      const diagnostics = createLivePreviewDiagnosticsSnapshot();
      const editor = createMarkdownEditor(
        dom.window.document.querySelector("main") as HTMLElement,
        "# old\n\nplain",
        (update) => {
          if (deferProjection) {
            deferredUpdate = update;
            return;
          }
          if (update.docChanged) revisions.documentChanged();
          controller?.handleUpdate(update);
        },
        () => {},
      );
      controller = new EditableProjectionController(editor, 1, revisions, ({ state }) => {
        if (state !== "running" || controller === null) return;
        controller.writeDiagnostics(diagnostics);
        committedRevisions.push(diagnostics.documentRevision);
      });
      try {
        controller.enable();
        committedRevisions.length = 0;
        deferProjection = true;
        editor.dispatch({
          changes: { from: 0, to: editor.state.doc.length, insert: "plain\n\n**content**" },
        });
        deferProjection = false;
        revisions.documentChanged();
        expect(deferredUpdate).not.toBeNull();
        if (deferredUpdate !== null) controller.handleUpdate(deferredUpdate);
        expect(committedRevisions).toEqual([1]);
        expect(editor.dom.querySelector(".maru-projection-heading-1")).toBeNull();
        expect(editor.dom.querySelector(".maru-projection-strong")).not.toBeNull();
      } finally {
        controller.destroy();
        editor.destroy();
      }
    });
  });

  test("defers decoration rewrites for the full IME composition lifetime", () => {
    withEditorDom((dom) => {
      const revisions = new EditorRevisionClock();
      let controller: EditableProjectionController | null = null;
      const editor = createMarkdownEditor(
        dom.window.document.querySelector("main") as HTMLElement,
        "*text*\n\nplain",
        (update) => {
          if (update.docChanged) revisions.documentChanged();
          controller?.handleUpdate(update);
        },
        () => {},
      );
      controller = new EditableProjectionController(editor, 1, revisions);
      try {
        controller.enable();
        editor.contentDOM.dispatchEvent(new dom.window.CompositionEvent("compositionstart"));
        const duringComposition = controller.metrics();
        editor.dispatch({
          changes: { from: 1, to: 2, insert: "T" },
          annotations: Transaction.userEvent.of("input.type.compose"),
        });
        expect(controller.metrics().visitedSyntaxNodes).toBe(duringComposition.visitedSyntaxNodes);
        expect(controller.metrics().projectionTransactions).toBe(
          duringComposition.projectionTransactions,
        );
        editor.contentDOM.dispatchEvent(new dom.window.CompositionEvent("compositionend"));
        expect(controller.metrics().visitedSyntaxNodes).toBeGreaterThan(
          duringComposition.visitedSyntaxNodes,
        );
      } finally {
        controller.destroy();
        editor.destroy();
      }
    });
  });
});
