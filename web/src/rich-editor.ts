/**
 * 리치 편집 모드(docs/file-panel.md §2.5) — 툴바를 가진 문서모델 WYSIWYG 편집기다.
 *
 * 소스 모드(CM6)와의 결정적 차이: 여기서는 사용자가 마크다운 기호를 보지 않는다. 화면에 보이는 것이 곧 렌더된
 * 결과이고, 파일을 열 때 마크다운을 문서모델로 파싱해 들어왔다가 저장할 때 다시 마크다운으로 직렬화해 나간다.
 * **그 왕복이 원문을 정규화할 수 있다는 것이 이 모드의 명시된 대가다** — 손실이 곤란한 문서는 소스 모드가 받는다.
 *
 * 편집기 본문은 문서모델 라이브러리가 DOM에 직접 마운트하고, 그 **주변 chrome(툴바)은 React가 그린다**(§2.1)
 * — 둘은 형제 노드이고 편집기를 React 컴포넌트로 다시 쓰지 않는다.
 *
 * **문법 목록으로 편집을 잠그던 장치는 없다.** 문서모델이 모르는 원문 조각은 그대로 보존되므로(§2.5 보존
 * 규칙, `rich-raw-node.ts`) 저장해도 원문이 파괴되지 않는다 — 막을 근거 자체가 사라졌다.
 */

import { Editor, type JSONContent } from "@tiptap/core";
import StarterKit from "@tiptap/starter-kit";
import { Markdown } from "@tiptap/markdown";
import TaskList from "@tiptap/extension-task-list";
import TaskItem from "@tiptap/extension-task-item";
import Image from "@tiptap/extension-image";
import { Table, TableRow, TableCell, TableHeader } from "@tiptap/extension-table";
import { mountShellUi, type ShellUiHandle } from "./shell-ui";
import { splitFrontmatter } from "./frontmatter";
import { Frontmatter, frontmatterNodeName } from "./rich-frontmatter-node";
import { RawBlock, RawInline } from "./rich-raw-node";
import type { ToolbarItem } from "./ui/toolbar";

export type RichEditorHandle = {
  /** 현재 문서를 마크다운으로 직렬화한다. 저장·모드 전환의 유일한 출력 경로다. */
  getMarkdown: () => string;
  /** 외부 변경(디스크 reload)이나 모드 인계로 문서를 통째로 갈아끼운다. dirty 판정은 호출자가 소유한다. */
  setMarkdown: (markdown: string) => void;
  focus: () => void;
  destroy: () => void;
  /** 편집 가능 여부. close lock 중에는 native가 편집을 막는다. */
  setEditable: (editable: boolean) => void;
  /** 문서 전체 선택(⌘A). 리치가 보이는 모드에서 native selectAll: 대신 쓴다. */
  selectAll: () => boolean;
  /** IME 조합 중인가. close lock이 조합 중 탭을 닫지 않도록 fail-closed 판정에 쓴다. */
  isComposing: () => boolean;
  /**
   * 문서모델 좌표의 현재 선택(§2.6). **DOM Range를 저장해 두면 안 된다** — 편집기가 DOM을 다시 만들면 그
   * Range의 노드가 문서에서 빠져 되살리기가 조용히 실패한다(실측: 1379자를 붙잡았는데 복원 뒤 선택 0자).
   */
  selectionRange: () => { from: number; to: number };
  /** 저장해 둔 문서모델 좌표로 선택을 되돌리고 편집기에 focus를 준다. */
  setSelectionRange: (from: number, to: number) => void;
};

type ToolbarButton = {
  label: string;
  title: string;
  /** 눌렀을 때 실행할 명령. 현재 selection에 토글로 적용한다. */
  run: (editor: Editor) => void;
  /** 지금 selection이 이 서식 안에 있는지(버튼 활성 표시용). */
  isActive?: (editor: Editor) => boolean;
};

/** 툴바 구성(v1, §2.5). 이미지·표 **삽입 버튼**은 후속이다 — 문서에 이미 있는 이미지·표는 확장이 보존한다. */
const toolbar_groups: ToolbarButton[][] = [
  [
    {
      label: "본문",
      title: "본문 텍스트",
      run: (e) => e.chain().focus().setParagraph().run(),
      isActive: (e) => e.isActive("paragraph"),
    },
    {
      label: "H1",
      title: "제목 1",
      run: (e) => e.chain().focus().toggleHeading({ level: 1 }).run(),
      isActive: (e) => e.isActive("heading", { level: 1 }),
    },
    {
      label: "H2",
      title: "제목 2",
      run: (e) => e.chain().focus().toggleHeading({ level: 2 }).run(),
      isActive: (e) => e.isActive("heading", { level: 2 }),
    },
    {
      label: "H3",
      title: "제목 3",
      run: (e) => e.chain().focus().toggleHeading({ level: 3 }).run(),
      isActive: (e) => e.isActive("heading", { level: 3 }),
    },
  ],
  [
    {
      label: "B",
      title: "굵게",
      run: (e) => e.chain().focus().toggleBold().run(),
      isActive: (e) => e.isActive("bold"),
    },
    {
      label: "I",
      title: "기울임",
      run: (e) => e.chain().focus().toggleItalic().run(),
      isActive: (e) => e.isActive("italic"),
    },
    {
      label: "S",
      title: "취소선",
      run: (e) => e.chain().focus().toggleStrike().run(),
      isActive: (e) => e.isActive("strike"),
    },
    {
      label: "`",
      title: "인라인 코드",
      run: (e) => e.chain().focus().toggleCode().run(),
      isActive: (e) => e.isActive("code"),
    },
  ],
  [
    {
      label: "•",
      title: "불릿 목록",
      run: (e) => e.chain().focus().toggleBulletList().run(),
      isActive: (e) => e.isActive("bulletList"),
    },
    {
      label: "1.",
      title: "번호 목록",
      run: (e) => e.chain().focus().toggleOrderedList().run(),
      isActive: (e) => e.isActive("orderedList"),
    },
    {
      label: "☑",
      title: "체크 목록",
      run: (e) => e.chain().focus().toggleTaskList().run(),
      isActive: (e) => e.isActive("taskList"),
    },
  ],
  [
    {
      label: "❝",
      title: "인용",
      run: (e) => e.chain().focus().toggleBlockquote().run(),
      isActive: (e) => e.isActive("blockquote"),
    },
    {
      label: "—",
      title: "구분선",
      run: (e) => e.chain().focus().setHorizontalRule().run(),
    },
  ],
];

/** 선언한 그룹을 현재 편집기 상태로 평가해 표현 계층에 넘길 항목으로 만든다. */
function toolbarItems(editor: Editor): ToolbarItem[][] {
  return toolbar_groups.map((group) =>
    group.map((button) => ({
      id: button.title,
      label: button.label,
      title: button.title,
      // `isActive`가 없는 버튼(구분선 삽입 등)은 토글이 아니므로 `undefined`를 그대로 넘긴다. `?? false`로 접으면
      // 표현 계층이 "꺼진 토글"로 그려 `aria-pressed="false"`가 붙는다(toolbar.tsx의 `active` 주석 참고).
      active: button.isActive?.(editor),
      run: () => button.run(editor),
    })),
  );
}

/**
 * 본문을 문서 JSON으로 파싱하고 frontmatter 블록을 **맨 앞에** 얹는다.
 *
 * 마크다운 문자열로 한 번에 넣지 않는 이유: 문자열 경로는 파서가 `---`를 구분선으로 읽어 우리가 방금 가른 것을
 * 되돌린다. JSON으로 넣으면 그 블록이 우리가 정한 노드로 그대로 들어간다.
 */
function withFrontmatter(editor: Editor, split: ReturnType<typeof splitFrontmatter>): JSONContent {
  const parsed = editor.markdown?.parse(split.body) ?? { type: "doc", content: [] };
  if (split.frontmatter === null) return parsed;
  const block: JSONContent = {
    type: frontmatterNodeName,
    // 빈 frontmatter(`---\n---`)에는 텍스트 자식이 없다 — 빈 문자열 노드를 넣으면 ProseMirror가 거부한다.
    ...(split.frontmatter.length === 0
      ? {}
      : { content: [{ type: "text", text: split.frontmatter }] }),
  };
  return { ...parsed, content: [block, ...(parsed.content ?? [])] };
}

export function createRichEditor(
  parent: HTMLElement,
  markdown: string,
  onChange: () => void,
  onSave: () => void,
): RichEditorHandle {
  const doc = parent.ownerDocument;
  const shell = doc.createElement("div");
  shell.className = "maru-rich-shell";
  const content = doc.createElement("div");
  content.className = "maru-rich-content";
  parent.appendChild(shell);

  let syncToolbar: () => void = () => {};
  // frontmatter는 **위치로 정의된다**(문서 맨 앞) — 마크다운 파서에 맡기면 본문 중간의 구분선까지 삼킨다.
  // 그래서 경계에서 갈라 별도 노드로 넣는다(`frontmatter.ts`).
  const initial = splitFrontmatter(markdown);
  const editor = new Editor({
    element: content,
    content: initial.body,
    contentType: "markdown",
    extensions: [
      StarterKit,
      // 문서 맨 앞 메타데이터를 보이고 고칠 수 있는 블록으로 둔다(§2.5). 이 노드가 없으면 왕복에서 뭉개져
      // 예전처럼 편집을 통째로 잠가야 한다.
      Frontmatter,
      // 문서모델이 모르는 원문 조각을 그대로 통과시킨다(§2.5 보존 규칙). 이 둘이 없으면 원시 HTML·각주가
      // 왕복에서 사라지고, 그래서 예전에는 문법 목록으로 편집을 잠가야 했다.
      RawBlock,
      RawInline,
      Markdown,
      TaskList,
      // 체크박스를 눌러 바로 토글할 수 있게 한다(GFM `- [ ]`).
      TaskItem.configure({ nested: true }),
      // 이미지·표 확장이 없으면 문서모델이 그 노드를 만들지 못해 **저장할 때 통째로 사라진다**
      // (실측: `![alt](img.png)` → `alt`, 표 3줄 → 한 줄로 뭉갬). 리치가 다룰 수 있는 문법은 확장으로 채운다.
      Image,
      Table,
      TableRow,
      TableCell,
      TableHeader,
    ],
    onUpdate: () => {
      onChange();
      syncToolbar();
    },
    onSelectionUpdate: () => syncToolbar(),
  });

  // 생성은 본문만으로 하고(마크다운 문자열 경로) frontmatter 블록은 곧바로 얹는다 — JSON을 만들려면 편집기의
  // 마크다운 매니저가 필요한데 그건 편집기가 선 뒤에야 있다.
  if (initial.frontmatter !== null) {
    editor.commands.setContent(withFrontmatter(editor, initial), { emitUpdate: false });
  }

  const uiHost = doc.createElement("div");
  shell.appendChild(uiHost);
  // 마운트 실패를 삼키지 않는다. 제품(WKWebView)에서 툴바가 통째로 비어 있는데 콘솔에도 아무 흔적이 없어
  // 원인 추적이 사용자 왕복이 됐다. 실패 사실을 DOM에 남겨 native 진단이 읽을 수 있게 한다.
  let ui: ShellUiHandle;
  try {
    ui = mountShellUi(uiHost, () => toolbarItems(editor));
  } catch (error) {
    doc.body.dataset.richToolbarError = String(error);
    throw error;
  }
  syncToolbar = ui.sync;
  shell.appendChild(content);

  // ⌘S는 편집기가 소유한다 — native가 web_editor로 라우팅한 키가 여기 도달한다(§2.3 키 경계).
  content.addEventListener("keydown", (event) => {
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "s") {
      event.preventDefault();
      onSave();
    }
  });

  return {
    getMarkdown: () => editor.getMarkdown(),
    setMarkdown: (next: string) => {
      // emitUpdate=false: 같은 내용을 다시 넣는 것뿐인데 onUpdate가 돌면 revision이 오르고 dirty가 켜져
      // "리치를 잠깐 들여다보기만 해도 탭에 ●가 붙는" 상태가 된다.
      const split = splitFrontmatter(next);
      editor.commands.setContent(withFrontmatter(editor, split), { emitUpdate: false });
      syncToolbar();
    },
    focus: () => editor.commands.focus(),
    destroy: () => {
      ui.destroy();
      editor.destroy();
    },
    // close lock이 리치를 잠그는 **유일한** 이유다 — 문법 때문에 잠그던 장치는 원문 보존 규칙(§2.5)이
    // 대체했다. 그래서 상태를 따로 들고 조합할 것이 없다.
    setEditable: (editable: boolean) => editor.setEditable(editable),
    selectAll: () => {
      editor.commands.focus();
      return editor.commands.selectAll();
    },
    isComposing: () => editor.view.composing,
    selectionRange: () => ({ from: editor.state.selection.from, to: editor.state.selection.to }),
    setSelectionRange: (from: number, to: number) => {
      editor.chain().focus().setTextSelection({ from, to }).run();
    },
  };
}
