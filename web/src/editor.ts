import { closeBrackets, closeBracketsKeymap } from "@codemirror/autocomplete";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { bracketMatching, indentOnInput, indentUnit } from "@codemirror/language";
import { EditorState, type Extension } from "@codemirror/state";
import { EditorView, keymap, lineNumbers, type ViewUpdate } from "@codemirror/view";
import { editableProjectionExtension } from "./editable-projection-view";
import { livePreviewEditorExtension } from "./live-preview-editor";
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
        livePreviewEditorExtension,
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

// text kind(docs/file-panel.md §2.2) 소스 전용 편집기. markdown projection/worker/render origin 없이 CM6에
// 확장자별 문법 하이라이트만 얹는다. dirty/save/외부변경은 shell의 read/write 브리지 배관을 그대로 공유하고,
// `languageExtensions`가 빈 배열이면 plain 텍스트로 편집만 된다.
export function createSourceEditor(
  parent: HTMLElement,
  content: string,
  languageExtensions: Extension[],
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
        // 코드 편집 필수: Enter 자동 들여쓰기(언어 indent service)·`}` 등 입력 시 재들여쓰기·괄호 매칭·자동 닫기.
        indentUnit.of("  "),
        indentOnInput(),
        bracketMatching(),
        closeBrackets(),
        ...languageExtensions,
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
          ...closeBracketsKeymap,
          indentWithTab, // Tab/Shift-Tab = 들여쓰기/내어쓰기
          ...defaultKeymap, // Enter = insertNewlineAndIndent(언어 indent 반영)
          ...historyKeymap,
        ]),
        EditorView.updateListener.of(onChange),
      ],
    }),
  });
}
