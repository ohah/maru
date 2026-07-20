import { defaultKeymap, history, historyKeymap } from "@codemirror/commands";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { EditorState } from "@codemirror/state";
import { EditorView, keymap, lineNumbers, type ViewUpdate } from "@codemirror/view";
import { editableProjectionExtension } from "./editable-projection-view";
import { maruMathMarkdownExtension } from "./markdown-language";

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
        EditorState.allowMultipleSelections.of(true),
        lineNumbers(),
        history(),
        markdown({ base: markdownLanguage, extensions: maruMathMarkdownExtension }),
        editableProjectionExtension,
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
        EditorView.updateListener.of(onChange),
      ],
    }),
  });
}
