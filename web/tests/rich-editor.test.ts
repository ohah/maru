/**
 * 리치 편집 모드(docs/file-panel.md §2.5)가 마크다운을 잃지 않고 왕복하는지 검증한다.
 *
 * 왜 중요한가: 리치는 디스크의 마크다운을 문서모델로 파싱했다가 저장할 때 다시 직렬화한다. 그 왕복이 원문을
 * **얼마나** 바꾸는지가 이 모드의 실질적 위험이고, §2.5는 "정규화될 수 있다"를 계약으로 수용했다. 다만 제목·
 * 목록·강조 같은 기본 구조까지 깨지면 그건 수용한 대가가 아니라 결함이다. 이 테스트는 그 하한을 고정한다.
 * 툴바 버튼이 실제로 마크다운을 바꾸는지도 함께 본다 — 버튼이 눌리기만 하고 문서가 그대로면 아무 의미가 없다.
 */

import { describe, expect, test } from "bun:test";
import { withEditorDom } from "./editor-dom";
import { createRichEditor, unsupportedRichSyntax } from "../src/rich-editor";

function mountRich(dom: ReturnType<typeof Object>, markdown: string) {
  const host = (globalThis as unknown as { document: Document }).document.querySelector(
    "main",
  ) as HTMLElement;
  return createRichEditor(
    host,
    markdown,
    () => {},
    () => {},
  );
}

describe("rich editing mode", () => {
  test("잠금 안내는 툴바와 **같은 React 트리**에서 그려지고, 풀리면 사라진다", async () => {
    // 왜 중요한가: 안내는 편집기 위에 한 줄 밴드로 뜨고 사라지며 **레이아웃을 바꾼다**. 예전엔 이 안내만
    // DOM으로 직접 만들어 붙였는데, 그러면 문서 주변 UI가 React 트리와 손으로 만든 노드 둘로 갈린다.
    await withEditorDom(async (dom) => {
      const doc = (globalThis as unknown as { document: Document }).document;
      // frontmatter는 리치가 표현하지 못하는 문법이라 편집이 잠긴다(§2.5).
      const rich = mountRich(dom, "---\ntitle: 문서\n---\n\n본문");
      try {
        const notice = doc.querySelector(".maru-rich-notice");
        expect(notice).not.toBeNull();
        expect(notice?.textContent).toContain("소스 모드");
        // 툴바와 형제여야 한다 — 한 루트가 둘 다 그린다.
        expect(notice?.parentElement?.querySelector("[role='toolbar']")).not.toBeNull();

        // 표현 가능한 문서로 갈아끼우면 잠금이 풀리고 안내도 사라진다.
        rich.setMarkdown("# 그냥 제목");
        expect(doc.querySelector(".maru-rich-notice")).toBeNull();
      } finally {
        rich.destroy();
      }
    });
  });

  test("markdown structure survives a document-model round trip", async () => {
    await withEditorDom(async (dom) => {
      const source = [
        "# 제목",
        "",
        "본문에 **굵게**와 *기울임*이 있습니다.",
        "",
        "- 첫 항목",
        "- 둘째 항목",
        "",
        "1. 순서 하나",
        "2. 순서 둘",
        "",
        "> 인용문",
        "",
        "```js",
        "const a = 1;",
        "```",
      ].join("\n");
      const rich = mountRich(dom, source);
      try {
        const out = rich.getMarkdown();
        // 구조가 살아 있어야 한다. 공백·줄바꿈 정규화는 §2.5가 수용한 범위라 정확 일치는 요구하지 않는다.
        expect(out).toContain("# 제목");
        expect(out).toContain("**굵게**");
        expect(out).toContain("*기울임*");
        expect(out).toContain("- 첫 항목");
        expect(out).toContain("- 둘째 항목");
        expect(out).toMatch(/1\.\s*순서 하나/);
        expect(out).toContain("> 인용문");
        expect(out).toContain("const a = 1;");
      } finally {
        rich.destroy();
      }
    });
  });

  test("한글 본문과 인라인 코드가 왕복에서 보존된다", async () => {
    await withEditorDom(async (dom) => {
      const source = "한글 본문과 `인라인 코드`가 섞인 문단입니다.";
      const rich = mountRich(dom, source);
      try {
        const out = rich.getMarkdown();
        expect(out).toContain("한글 본문과");
        expect(out).toContain("`인라인 코드`");
      } finally {
        rich.destroy();
      }
    });
  });

  test("toolbar buttons change the serialized markdown, not just the DOM", async () => {
    await withEditorDom(async (dom) => {
      const rich = mountRich(dom, "평범한 문단");
      try {
        const doc = (globalThis as unknown as { document: Document }).document;
        // 기다리지 않는다. `createRichEditor`가 돌아온 시점에 툴바가 DOM에 있어야 한다는 계약을 여기서 함께
        // 고정한다(shell-ui.tsx가 첫 렌더를 flushSync로 동기화한다). 폴링을 넣으면 그 계약이 깨져도 통과한다.
        const buttons = [...doc.querySelectorAll<HTMLButtonElement>("[data-toolbar-button]")];
        expect(buttons.length).toBeGreaterThan(8);

        const heading1 = buttons.find((b) => b.title === "제목 1");
        expect(heading1).toBeDefined();
        // 전체 선택 후 제목 적용 — selection이 없으면 명령이 커서 위치 블록에만 걸린다.
        rich.focus();
        heading1?.dispatchEvent(new dom.window.Event("click", { bubbles: true }));
        expect(rich.getMarkdown()).toContain("# 평범한 문단");

        const bullet = buttons.find((b) => b.title === "불릿 목록");
        bullet?.dispatchEvent(new dom.window.Event("click", { bubbles: true }));
        expect(rich.getMarkdown()).toMatch(/^- /m);
      } finally {
        rich.destroy();
      }
    });
  });

  test("툴바 버튼은 배경을 스스로 지정하고, 토글이 아닌 버튼은 눌림 상태를 갖지 않는다", async () => {
    // 둘 다 눈에 보이지 않는 회귀라 클래스·속성으로 고정한다.
    // ⑴ preflight를 빼서 UA 기본 `background: ButtonFace`가 남는다 — 명시하지 않으면 버튼이 회색 칩으로 그려지고
    //    라이트 모드에서는 그 회색이 활성 하이라이트보다 진해 **활성 표시가 반전돼** 보인다.
    // ⑵ `isActive`가 없는 명령(구분선 삽입)에 `aria-pressed="false"`를 달면 보조기술이 토글로 읽고, 눌러도 상태가
    //    안 바뀌니 사용자가 실패로 여겨 반복 실행한다(구분선이 여러 개 삽입된다).
    await withEditorDom(async (dom) => {
      const rich = mountRich(dom, "평범한 문단");
      try {
        const doc = (globalThis as unknown as { document: Document }).document;
        const buttons = [...doc.querySelectorAll<HTMLButtonElement>("[data-toolbar-button]")];
        const inactive = buttons.find((b) => b.getAttribute("data-active") === "false");
        expect(inactive?.className).toContain("bg-transparent");
        // 활성 버튼은 선택 배경이 이겨야 한다(tailwind-merge가 뒤 클래스를 남긴다).
        const active = buttons.find((b) => b.getAttribute("data-active") === "true");
        expect(active?.className).toContain("bg-accent-selected");
        expect(active?.className).not.toContain("bg-transparent");

        const rule = buttons.find((b) => b.title === "구분선");
        expect(rule).toBeDefined();
        expect(rule?.hasAttribute("aria-pressed")).toBe(false);
        expect(rule?.hasAttribute("data-active")).toBe(false);
      } finally {
        rich.destroy();
      }
    });
  });

  test("이미지와 표는 확장이 보존한다", async () => {
    await withEditorDom(async (dom) => {
      const source = "![alt](img.png)\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n";
      const rich = mountRich(dom, source);
      try {
        const out = rich.getMarkdown();
        // 확장이 없으면 이미지는 `alt` 텍스트만 남고 표는 한 줄로 뭉개진다(실측). 둘 다 회귀 가드다.
        expect(out).toContain("![alt](img.png)");
        expect(out).toMatch(/\|\s*a\s*\|\s*b\s*\|/);
        expect(out).toMatch(/\|\s*---\s*\|/);
        expect(out).toMatch(/\|\s*1\s*\|\s*2\s*\|/);
      } finally {
        rich.destroy();
      }
    });
  });

  test("표현할 수 없는 문법이 있는 문서는 편집을 잠근다", async () => {
    // 저장 경로가 열려 있으면 왕복에서 원문이 파괴된다 — frontmatter는 제목으로 변질되고 태그·각주는 사라진다.
    expect(unsupportedRichSyntax("---\ntitle: 문서\n---\n\n본문")).toContain("YAML frontmatter");
    expect(unsupportedRichSyntax("텍스트[^1]\n\n[^1]: 각주")).toContain("각주");
    expect(unsupportedRichSyntax('<div class="x">raw</div>')).toContain("원시 HTML");
    // 주석·doctype도 왕복에서 사라진다 — 태그만 보면 `<!-- toc -->`가 있는 문서가 조용히 손상된다.
    expect(unsupportedRichSyntax("# 제목\n\n<!-- prettier-ignore -->\n\n본문")).toContain(
      "원시 HTML",
    );
    expect(unsupportedRichSyntax("<!DOCTYPE html>\n\n본문")).toContain("원시 HTML");

    // 평범한 문서는 잠그지 않는다.
    expect(unsupportedRichSyntax("# 제목\n\n- 목록\n\n**굵게**")).toEqual([]);
    // 코드펜스 안의 HTML은 내용일 뿐이라 대상이 아니다(HTML 예제를 담은 문서를 잠그면 안 된다).
    expect(unsupportedRichSyntax("```html\n<div>example</div>\n```")).toEqual([]);
    // 인라인 코드로 태그를 설명하는 문장도 마찬가지다.
    expect(unsupportedRichSyntax("설정은 `<div>` 태그로 합니다.")).toEqual([]);
    // frontmatter는 문서 첫 줄의 `---`만이다. 절 구분선으로 `---`를 두 번 쓴 평범한 문서를 잠그면 안 된다.
    expect(unsupportedRichSyntax("제목\n---\n\n본문\n\n---\n\n다음 절")).toEqual([]);

    await withEditorDom(async (dom) => {
      const rich = mountRich(dom, "---\ntitle: 문서\n---\n\n본문");
      try {
        const doc = (globalThis as unknown as { document: Document }).document;
        expect(doc.querySelector(".maru-rich-notice")).not.toBeNull();
        expect(doc.querySelector(".ProseMirror")?.getAttribute("contenteditable")).toBe("false");
      } finally {
        rich.destroy();
      }
    });
  });

  test("내용이 바뀌면 잠금도 다시 판정한다", async () => {
    // 생성 시 한 번만 보면, 소스에서 frontmatter를 붙였다 리치로 돌아온 문서에 잠금이 걸리지 않아
    // 그대로 저장돼 원문이 파괴된다. 반대로 frontmatter를 지운 문서가 영영 읽기 전용으로 남는 것도 막는다.
    await withEditorDom(async (dom) => {
      const doc = (globalThis as unknown as { document: Document }).document;
      const rich = mountRich(dom, "# 깨끗한 문서");
      try {
        expect(doc.querySelector(".maru-rich-notice")).toBeNull();

        rich.setMarkdown("---\ntitle: 문서\n---\n\n본문");
        expect(doc.querySelector(".maru-rich-notice")).not.toBeNull();
        expect(doc.querySelector(".ProseMirror")?.getAttribute("contenteditable")).toBe("false");

        rich.setMarkdown("# 다시 깨끗해진 문서");
        expect(doc.querySelector(".maru-rich-notice")).toBeNull();
        expect(doc.querySelector(".ProseMirror")?.getAttribute("contenteditable")).toBe("true");
      } finally {
        rich.destroy();
      }
    });
  });

  test("close lock이 풀려도 표현 불가 잠금은 유지된다", async () => {
    await withEditorDom(async (dom) => {
      const doc = (globalThis as unknown as { document: Document }).document;
      const rich = mountRich(dom, "---\ntitle: 문서\n---\n\n본문");
      try {
        rich.setEditable(false); // close lock 획득
        expect(doc.querySelector(".ProseMirror")?.getAttribute("contenteditable")).toBe("false");
        rich.setEditable(true); // close lock 해제 — 표현 불가 잠금까지 풀리면 안 된다
        expect(doc.querySelector(".ProseMirror")?.getAttribute("contenteditable")).toBe("false");
      } finally {
        rich.destroy();
      }
    });
  });

  test("setMarkdown replaces the document for external disk reloads", async () => {
    await withEditorDom(async (dom) => {
      const rich = mountRich(dom, "처음 내용");
      try {
        rich.setMarkdown("## 디스크에서 바뀐 내용");
        const out = rich.getMarkdown();
        expect(out).toContain("## 디스크에서 바뀐 내용");
        expect(out).not.toContain("처음 내용");
      } finally {
        rich.destroy();
      }
    });
  });
});
