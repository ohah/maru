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
import Image from "@tiptap/extension-image";
import { Table, TableRow, TableCell, TableHeader } from "@tiptap/extension-table";

/**
 * 리치가 문서모델로 표현하지 못해 **저장할 때 잃어버리는** 문법을 찾는다.
 *
 * 실측(왕복 테스트)으로 확인된 것들이다 — frontmatter는 `---` 구분자가 제목으로 변질되고(`## title: 문서`),
 * 원시 HTML은 태그가 사라지며, 각주는 정의가 인라인 링크로 뭉개진다. 이미지·표는 확장을 넣어 해결했지만
 * 이 셋은 문서모델에 대응 노드가 없어 확장으로 채울 수 없다.
 *
 * 그래서 이런 문서는 리치에서 **읽기만** 하게 하고 편집을 막는다. 저장 경로가 닫히면 원문은 안전하고,
 * 사용자는 소스 모드에서 손실 없이 고칠 수 있다(docs/file-panel.md §2.5).
 */
export function unsupportedRichSyntax(markdown: string): string[] {
  // 코드 안의 텍스트는 내용일 뿐이라 검사 대상이 아니다. 코드펜스와 인라인 코드를 모두 지운 뒤 본다 —
  // `설정은 \`<div>\` 태그로…` 같은 평범한 설명문이 원시 HTML로 오탐되면 그 문서는 영영 리치에서 못 연다.
  const withoutCode = markdown
    .replace(/^ {0,3}(`{3,}|~{3,})[\s\S]*?^ {0,3}\1[ \t]*$/gm, "")
    .replace(/`[^`\n]*`/g, "");
  const found: string[] = [];
  // frontmatter는 **문서 첫 줄**의 `---`만이다. 앵커가 없으면 `제목\n---`(setext H2)이나 절 구분선으로 쓴
  // `---` 두 개짜리 평범한 문서가 전부 잠긴다(실측 오탐).
  if (/^---\r?\n[\s\S]*?^---[ \t]*$/m.test(withoutCode) && /^---\r?\n/.test(withoutCode)) {
    found.push("YAML frontmatter");
  }
  if (/^\[\^[^\]]+\]:/m.test(withoutCode)) found.push("각주");
  // 태그뿐 아니라 주석·doctype도 왕복에서 사라진다(`<!-- toc -->`, `<!-- prettier-ignore -->`, `<!DOCTYPE html>`).
  if (
    /<!--|<!DOCTYPE/i.test(withoutCode) ||
    /<\/?[a-zA-Z][a-zA-Z0-9-]*(\s[^<>]*)?>/.test(withoutCode)
  ) {
    found.push("원시 HTML");
  }
  return found;
}

export type RichEditorHandle = {
  /** 현재 문서를 마크다운으로 직렬화한다. 저장·모드 전환의 유일한 출력 경로다. */
  getMarkdown: () => string;
  /**
   * 외부 변경(디스크 reload)이나 모드 인계로 문서를 통째로 갈아끼운다. dirty 판정은 호출자가 소유한다.
   * **표현 불가 문법 검사도 여기서 다시 돈다** — 내용이 바뀌면 잠금 여부도 바뀌기 때문이다.
   */
  setMarkdown: (markdown: string) => void;
  focus: () => void;
  destroy: () => void;
  /** 편집 가능 여부. close lock 중에는 native가 편집을 막는다. */
  setEditable: (editable: boolean) => void;
  /** 문서 전체 선택(⌘A). 리치가 보이는 모드에서 native selectAll: 대신 쓴다. */
  selectAll: () => boolean;
  /** IME 조합 중인가. close lock이 조합 중 탭을 닫지 않도록 fail-closed 판정에 쓴다. */
  isComposing: () => boolean;
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
  /** 표현 불가 문법 때문에 잠겼는지 알린다. shell이 저장 경로를 막는 데 쓴다. */
  onLockChanged: (locked: boolean) => void = () => {},
): RichEditorHandle {
  const doc = parent.ownerDocument;
  const shell = doc.createElement("div");
  shell.className = "maru-rich-shell";
  const content = doc.createElement("div");
  content.className = "maru-rich-content";
  parent.appendChild(shell);

  let syncToolbar: () => void = () => {};
  /// close lock으로 잠긴 상태인가(표현 불가 잠금과 독립 — 둘 중 하나라도 걸리면 편집 불가).
  let closeLocked = false;
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

  syncToolbar = buildToolbar(shell, editor);
  shell.appendChild(content);
  syncToolbar();

  // 리치가 표현하지 못하는 문법이 있으면 편집을 막는다. **내용이 바뀔 때마다 다시 판정한다** — 생성 시
  // 한 번만 보면, 소스에서 frontmatter를 붙였다 리치로 돌아온 문서에는 잠금이 걸리지 않는다(그 반대도 마찬가지).
  let notice: HTMLElement | null = null;
  let locked = false;
  const applyLock = (source: string) => {
    const unsupported = unsupportedRichSyntax(source);
    locked = unsupported.length > 0;
    editor.setEditable(!locked && !closeLocked);
    if (locked) {
      if (notice === null) {
        notice = doc.createElement("div");
        notice.className = "maru-rich-notice";
        shell.insertBefore(notice, content);
      }
      notice.textContent = `이 문서에는 리치 편집이 다루지 못하는 문법이 있어 편집을 잠갔습니다(${unsupported.join(", ")}). 소스 모드에서 고치면 원문이 그대로 보존됩니다.`;
    } else if (notice !== null) {
      notice.remove();
      notice = null;
    }
    onLockChanged(locked);
  };
  applyLock(markdown);

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
      editor.commands.setContent(next, { contentType: "markdown", emitUpdate: false });
      applyLock(next);
      syncToolbar();
    },
    focus: () => editor.commands.focus(),
    destroy: () => editor.destroy(),
    setEditable: (editable: boolean) => {
      closeLocked = !editable;
      // 표현 불가 잠금이 걸린 문서는 close lock이 풀려도 계속 잠긴 상태여야 한다.
      editor.setEditable(editable && !locked);
    },
    selectAll: () => {
      editor.commands.focus();
      return editor.commands.selectAll();
    },
    isComposing: () => editor.view.composing,
  };
}
