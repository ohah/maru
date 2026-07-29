import { closeBrackets, closeBracketsKeymap } from "@codemirror/autocomplete";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { bracketMatching, indentOnInput, indentUnit } from "@codemirror/language";
import { EditorState, type Extension } from "@codemirror/state";
import { drawSelection, EditorView, keymap, lineNumbers, type ViewUpdate } from "@codemirror/view";
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
        // CM6는 문서를 가상화(보이는 줄만 DOM)하므로 브라우저 native 선택에 의존하면 긴 문서의 전체 선택이
        // 렌더된 줄만 덮여 화면·복사·삭제가 일부만 된다. drawSelection이 CM6 자체 선택 레이어를 그려 전체 모델
        // 선택을 일관되게 시각화·처리한다(⌘A 전체 선택이 실제로 전부 지워지도록).
        drawSelection(),
        lineNumbers(),
        history(),
        markdown({ base: markdownLanguage, extensions: maruMathMarkdownExtension }),
        indentUnit.of("  "),
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
          indentWithTab, // Tab/Shift-Tab = 들여쓰기/내어쓰기
          ...defaultKeymap,
          ...historyKeymap,
        ]),
        EditorView.updateListener.of(onChange),
      ],
    }),
  });
}

// text kind(docs/file-panel.md §2.2) 소스 전용 편집기. markdown render origin 없이 CM6에
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
        // CM6는 문서를 가상화(보이는 줄만 DOM)하므로 브라우저 native 선택에 의존하면 긴 문서의 전체 선택이
        // 렌더된 줄만 덮여 화면·복사·삭제가 일부만 된다. drawSelection이 CM6 자체 선택 레이어를 그려 전체 모델
        // 선택을 일관되게 시각화·처리한다(⌘A 전체 선택이 실제로 전부 지워지도록).
        drawSelection(),
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
