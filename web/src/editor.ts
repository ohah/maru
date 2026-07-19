import { defaultKeymap, history, historyKeymap } from "@codemirror/commands";
import { markdown } from "@codemirror/lang-markdown";
import { EditorState } from "@codemirror/state";
import { EditorView, keymap, lineNumbers, type ViewUpdate } from "@codemirror/view";

export function createMarkdownEditor(
  parent: HTMLElement,
  content: string,
  onChange: (update: ViewUpdate) => void,
  onSave: () => void,
): EditorView {
  return new EditorView({
    parent,
    state: EditorState.create({
      doc: content,
      extensions: [
        lineNumbers(),
        history(),
        markdown(),
        EditorView.lineWrapping,
        keymap.of([
          {
            key: "Mod-s",
            preventDefault: true,
            run: () => {
              onSave();
              return true;
            },
          },
          ...defaultKeymap,
          ...historyKeymap,
        ]),
        EditorView.updateListener.of((update) => {
          if (update.docChanged) onChange(update);
        }),
      ],
    }),
  });
}
