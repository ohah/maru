/**
 * 리치 편집 모드(docs/file-panel.md §2.5) — 툴바를 가진 문서모델 WYSIWYG 편집기다.
 *
 * 소스 모드(CM6)와의 결정적 차이: 여기서는 사용자가 마크다운 기호를 보지 않는다. 화면에 보이는 것이 곧 렌더된
 * 결과이고, 파일을 열 때 마크다운을 문서모델로 파싱해 들어왔다가 저장할 때 다시 마크다운으로 직렬화해 나간다.
 * **그 왕복이 원문을 정규화할 수 있다는 것이 이 모드의 명시된 대가다** — 손실이 곤란한 문서는 소스 모드가 받는다.
 *
 * 마운트는 vanilla다(웹앱에 프레임워크를 두지 않는다 — §2.1). 툴바도 DOM으로 직접 만든다.
 */

import { Editor } from "@tiptap/core";
import StarterKit from "@tiptap/starter-kit";
import { Markdown } from "@tiptap/markdown";
import TaskList from "@tiptap/extension-task-list";
import TaskItem from "@tiptap/extension-task-item";

export type RichEditorHandle = {
  /** 현재 문서를 마크다운으로 직렬화한다. 저장·모드 전환의 유일한 출력 경로다. */
  getMarkdown: () => string;
  /** 외부 변경(디스크 reload)으로 문서를 통째로 갈아끼운다. dirty 판정은 호출자가 소유한다. */
  setMarkdown: (markdown: string) => void;
  focus: () => void;
  destroy: () => void;
  /** 편집 가능 여부. close lock 중에는 native가 편집을 막는다. */
  setEditable: (editable: boolean) => void;
};

type ToolbarButton = {
  label: string;
  title: string;
  /** 눌렀을 때 실행할 명령. 현재 selection에 토글로 적용한다. */
  run: (editor: Editor) => void;
  /** 지금 selection이 이 서식 안에 있는지(버튼 활성 표시용). */
  isActive?: (editor: Editor) => boolean;
};

/** 툴바 구성(v1, §2.5). 이미지·표·코드블록 삽입은 후속이다. */
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

function buildToolbar(host: HTMLElement, editor: Editor): () => void {
  const bar = host.ownerDocument.createElement("div");
  bar.className = "maru-rich-toolbar";
  const syncers: Array<() => void> = [];

  for (const [index, group] of toolbar_groups.entries()) {
    if (index > 0) {
      const separator = host.ownerDocument.createElement("span");
      separator.className = "maru-rich-toolbar-separator";
      bar.appendChild(separator);
    }
    for (const button of group) {
      const el = host.ownerDocument.createElement("button");
      el.type = "button";
      el.className = "maru-rich-toolbar-button";
      el.textContent = button.label;
      el.title = button.title;
      // 툴바 클릭이 편집기 selection을 빼앗으면 명령이 엉뚱한 위치에 적용된다.
      el.addEventListener("mousedown", (event) => event.preventDefault());
      el.addEventListener("click", () => button.run(editor));
      bar.appendChild(el);
      const isActive = button.isActive;
      if (isActive !== undefined) {
        syncers.push(() => {
          el.dataset.active = isActive(editor) ? "true" : "false";
        });
      }
    }
  }
  host.appendChild(bar);
  return () => {
    for (const sync of syncers) sync();
  };
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
  const editor = new Editor({
    element: content,
    content: markdown,
    contentType: "markdown",
    extensions: [
      StarterKit,
      Markdown,
      TaskList,
      // 체크박스를 눌러 바로 토글할 수 있게 한다(GFM `- [ ]`).
      TaskItem.configure({ nested: true }),
    ],
    onUpdate: () => {
      onChange();
      syncToolbar();
    },
    onSelectionUpdate: () => syncToolbar(),
  });

  syncToolbar = buildToolbar(shell, editor);
  shell.appendChild(content);
  syncToolbar();

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
      editor.commands.setContent(next, { contentType: "markdown" });
      syncToolbar();
    },
    focus: () => editor.commands.focus(),
    destroy: () => editor.destroy(),
    setEditable: (editable: boolean) => editor.setEditable(editable),
  };
}
