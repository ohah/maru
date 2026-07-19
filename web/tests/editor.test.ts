import { describe, expect, test } from "bun:test";
import { EditorState, Text, Transaction } from "@codemirror/state";
import type { EditorView } from "@codemirror/view";
import { JSDOM } from "jsdom";
import { createMarkdownEditor } from "../src/editor";

function withEditorDom<T>(run: (dom: JSDOM) => T): T {
  const dom = new JSDOM("<!doctype html><html><body><main></main></body></html>", {
    pretendToBeVisual: true,
  });
  const previous = new Map<string, PropertyDescriptor | undefined>();
  const globals: Array<[string, unknown]> = [
    ["window", dom.window],
    ["document", dom.window.document],
    ["navigator", dom.window.navigator],
    ["MutationObserver", dom.window.MutationObserver],
    ["DOMRect", dom.window.DOMRect],
    ["requestAnimationFrame", dom.window.requestAnimationFrame.bind(dom.window)],
    ["cancelAnimationFrame", dom.window.cancelAnimationFrame.bind(dom.window)],
  ];
  try {
    for (const [name, value] of globals) {
      previous.set(name, Object.getOwnPropertyDescriptor(globalThis, name));
      Object.defineProperty(globalThis, name, { configurable: true, writable: true, value });
    }
    return run(dom);
  } finally {
    for (const [name, descriptor] of previous) {
      if (descriptor === undefined) delete (globalThis as Record<string, unknown>)[name];
      else Object.defineProperty(globalThis, name, descriptor);
    }
    dom.window.close();
  }
}

describe("markdown editor hot path", () => {
  test("Mod-s stays in the CM6 keymap and invokes the explicit save callback", () => {
    withEditorDom((dom) => {
      let saves = 0;
      const editor = createMarkdownEditor(
        dom.window.document.querySelector("main") as HTMLElement,
        "# live",
        () => {},
        () => {
          saves += 1;
        },
      );
      try {
        const event = new dom.window.KeyboardEvent("keydown", {
          key: "s",
          code: "KeyS",
          metaKey: true,
          bubbles: true,
          cancelable: true,
        });
        expect(editor.contentDOM.dispatchEvent(event)).toBe(false);
        expect(event.defaultPrevented).toBe(true);
        expect(saves).toBe(1);
      } finally {
        editor.destroy();
      }
    });
  });

  test("large input and composition transactions do not serialize or save the full document", () => {
    withEditorDom((dom) => {
      const textPrototype = Text.prototype as Text & { toString: () => string };
      const originalToString = textPrototype.toString;
      let serializations = 0;
      textPrototype.toString = function (this: Text) {
        serializations += 1;
        return originalToString.call(this);
      };

      let editor: EditorView | null = null;
      try {
        const initial = "a".repeat(8 * 1024 * 1024);
        let savedDocument: Text | null = null;
        let documentRevision = 0;
        let dirty = false;
        let nativeWrites = 0;
        editor = createMarkdownEditor(
          dom.window.document.querySelector("main") as HTMLElement,
          initial,
          (update) => {
            documentRevision += 1;
            dirty = savedDocument === null || !update.state.doc.eq(savedDocument);
          },
          () => {
            nativeWrites += 1;
          },
        );
        savedDocument = editor.state.doc;
        serializations = 0;
        editor.dispatch({
          changes: { from: 0, to: 1, insert: "b" },
          annotations: Transaction.userEvent.of("input.type.compose"),
        });
        dirty = !editor.state.doc.eq(savedDocument);

        expect(documentRevision).toBe(1);
        expect(dirty).toBe(true);
        expect(serializations).toBe(0);
        expect(nativeWrites).toBe(0);

        // The full 1,000-transaction FP10c2 perf artifact is added in that slice. Keep its persistent-text
        // comparison invariant here without paying 1,000 DOM layout/paint cycles in every web unit-test run.
        editor.destroy();
        editor = null;
        let model = EditorState.create({ doc: initial });
        const savedModel = model.doc;
        let dirtyRevisions = 0;
        serializations = 0;
        for (let index = 0; index < 1_000; index += 1) {
          model = model.update({
            changes: { from: 0, to: 1, insert: index % 2 === 0 ? "b" : "a" },
            annotations: Transaction.userEvent.of("input.type.compose"),
          }).state;
          if (!model.doc.eq(savedModel)) dirtyRevisions += 1;
        }
        expect(dirtyRevisions).toBe(500);
        expect(serializations).toBe(0);
      } finally {
        editor?.destroy();
        textPrototype.toString = originalToString;
      }
    });
  });

  test("editor DOM fixture restores globals when setup work throws", () => {
    const before = Object.getOwnPropertyDescriptor(globalThis, "window");
    expect(() =>
      withEditorDom(() => {
        throw new Error("fixture failure");
      }),
    ).toThrow("fixture failure");
    expect(Object.getOwnPropertyDescriptor(globalThis, "window")).toEqual(before);
  });
});
