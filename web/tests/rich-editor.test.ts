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
import { createRichEditor } from "../src/rich-editor";

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
  test("markdown structure survives a document-model round trip", () => {
    withEditorDom((dom) => {
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

  test("한글 본문과 인라인 코드가 왕복에서 보존된다", () => {
    withEditorDom((dom) => {
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

  test("toolbar buttons change the serialized markdown, not just the DOM", () => {
    withEditorDom((dom) => {
      const rich = mountRich(dom, "평범한 문단");
      try {
        const doc = (globalThis as unknown as { document: Document }).document;
        const buttons = [...doc.querySelectorAll<HTMLButtonElement>(".maru-rich-toolbar-button")];
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

  test("setMarkdown replaces the document for external disk reloads", () => {
    withEditorDom((dom) => {
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
