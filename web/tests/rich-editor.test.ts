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
  test("문서모델이 모르는 문법도 편집을 잠그지 않는다(원문 보존 규칙)", async () => {
    // 왜 중요한가: 예전에는 원시 HTML·각주가 있으면 편집과 저장을 통째로 막았다. 막던 이유는 왕복에서 원문이
    // 파괴되기 때문이었는데(태그 소실, `[^1]`→`\[^1\]`), 보존 노드가 그 파괴를 없앴으므로 막을 근거가 없다.
    await withEditorDom(async (dom) => {
      const doc = (globalThis as unknown as { document: Document }).document;
      const rich = mountRich(dom, "텍스트[^1]\n\n[^1]: 각주");
      try {
        expect(doc.querySelector(".ProseMirror")?.getAttribute("contenteditable")).toBe("true");
        // 안내 밴드라는 개념 자체가 없어졌다.
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

  test("frontmatter는 블록으로 보이고, 왕복해도 원문 그대로다", async () => {
    // 왜 중요한가: frontmatter 값은 글이 아니라 빌드·배포가 읽는 데이터다. 예전에는 왕복에서 `## title: 문서`로
    // 뭉개져 편집을 통째로 잠갔는데, 노드를 주면 그 이유가 사라진다 — 대신 **왕복 무손실**이 계약이 된다.
    await withEditorDom(async (dom) => {
      const doc = (globalThis as unknown as { document: Document }).document;
      const source = "---\ntitle: 문서\ntags: [a, b]\n---\n\n# 제목\n\n본문\n";
      const rich = mountRich(dom, source);
      try {
        const block = doc.querySelector(".maru-rich-frontmatter");
        expect(block).not.toBeNull();
        expect(block?.textContent).toBe("title: 문서\ntags: [a, b]");
        // 본문과 **다른 블록**이어야 한다 — 문단으로 들어가면 서식이 붙고 값이 정규화된다.
        expect(block?.closest(".ProseMirror")).not.toBeNull();
        // 잠기지 않는다.
        expect(doc.querySelector(".maru-rich-notice")).toBeNull();
        expect(doc.querySelector(".ProseMirror")?.getAttribute("contenteditable")).toBe("true");

        // 왕복: 구분선과 안쪽 값이 글자 그대로 살아 있어야 한다.
        const round = rich.getMarkdown();
        expect(round.startsWith("---\ntitle: 문서\ntags: [a, b]\n---\n")).toBe(true);
        expect(round).toContain("# 제목");

        // 모드 인계(setMarkdown)로 들어와도 같다.
        rich.setMarkdown("---\nid: 7\n---\n\n다른 본문\n");
        expect(doc.querySelector(".maru-rich-frontmatter")?.textContent).toBe("id: 7");
        expect(rich.getMarkdown().startsWith("---\nid: 7\n---\n")).toBe(true);

        // frontmatter가 없는 문서로 갈아끼우면 블록도 사라진다.
        rich.setMarkdown("# 그냥 제목\n");
        expect(doc.querySelector(".maru-rich-frontmatter")).toBeNull();
      } finally {
        rich.destroy();
      }
    });
  });

  test("본문 중간의 `---`는 구분선으로 남는다(frontmatter로 삼키지 않는다)", async () => {
    // 위치가 정의의 전부다. 중간 구분선을 메타데이터로 읽으면 그 아래 본문이 통째로 블록에 빨려 들어간다.
    await withEditorDom(async (dom) => {
      const doc = (globalThis as unknown as { document: Document }).document;
      const rich = mountRich(dom, "# 제목\n\n---\n\n본문\n");
      try {
        expect(doc.querySelector(".maru-rich-frontmatter")).toBeNull();
        expect(rich.getMarkdown()).toContain("본문");
      } finally {
        rich.destroy();
      }
    });
  });

  test("원시 HTML·각주는 원문 그대로 왕복한다", async () => {
    // 이 넷이 예전 잠금 목록의 전부였다. 실측으로 각각 이렇게 깨졌다 — `<kbd>⌘S</kbd>`→`⌘S`,
    // `<details>…</details>`→내부 텍스트만, `<!-- c -->`→빈 줄, `[^1]`→`\[^1\]`(각주가 리터럴 대괄호로).
    await withEditorDom(async (dom) => {
      const roundTrip = (source: string) => {
        const rich = mountRich(dom, source);
        try {
          return rich.getMarkdown();
        } finally {
          rich.destroy();
        }
      };

      // 블록 조각: 여는 태그부터 닫는 태그까지 통째로.
      expect(roundTrip("<details>\n<summary>접기</summary>\n안쪽\n</details>\n")).toBe(
        "<details>\n<summary>접기</summary>\n안쪽\n</details>",
      );
      // 인라인 조각: 여는·닫는 태그가 각각 별도 토큰이라 조각 그대로 이어 붙여야 원문이 된다.
      expect(roundTrip("누르세요 <kbd>⌘S</kbd> 그리고 H<sub>2</sub>O\n")).toBe(
        "누르세요 <kbd>⌘S</kbd> 그리고 H<sub>2</sub>O",
      );
      // void 태그도 hard break로 정규화되지 않고 원문으로 남는다.
      expect(roundTrip("줄바꿈<br>\n다음 줄\n")).toBe("줄바꿈<br>\n다음 줄");
      // 각주는 토크나이저가 떼어 주지 않아 **토큰 규칙을 더해** 인식시킨 문법이다(§2.5).
      expect(roundTrip("본문[^1] 입니다.\n\n[^1]: 각주 정의\n")).toBe(
        "본문[^1] 입니다.\n\n[^1]: 각주 정의",
      );
      // 각주 참조가 문단 중간에 있어도 그 자리에서 문단이 끊기지 않는다.
      expect(roundTrip("앞[^a] 뒤\n")).toBe("앞[^a] 뒤");
    });
  });

  test("코드 안의 태그는 조각이 아니라 내용이라 그대로 코드로 남는다", async () => {
    // 보존 노드가 코드펜스·인라인 코드까지 삼키면 HTML 예제를 담은 문서가 통째로 조각이 된다.
    await withEditorDom(async (dom) => {
      const rich = mountRich(
        dom,
        "설정은 `<div>` 태그로 합니다.\n\n```html\n<b>example</b>\n```\n",
      );
      try {
        const out = rich.getMarkdown();
        expect(out).toContain("`<div>`");
        expect(out).toContain("```html");
        expect(out).toContain("<b>example</b>");
      } finally {
        rich.destroy();
      }
    });
  });

  test("close lock이 리치를 잠그는 유일한 이유다", async () => {
    // 예전에는 잠금 이유가 둘이라(close lock + 표현 불가 문법) 해제할 때 서로를 덮지 않게 조합해야 했다.
    // 보존 규칙이 뒤엣것을 없앴으므로 이제 close lock 하나만 본다 — 획득하면 잠기고 풀면 곧바로 열린다.
    await withEditorDom(async (dom) => {
      const doc = (globalThis as unknown as { document: Document }).document;
      const rich = mountRich(dom, "텍스트[^1]\n\n[^1]: 각주");
      try {
        rich.setEditable(false); // close lock 획득
        expect(doc.querySelector(".ProseMirror")?.getAttribute("contenteditable")).toBe("false");
        rich.setEditable(true); // close lock 해제
        expect(doc.querySelector(".ProseMirror")?.getAttribute("contenteditable")).toBe("true");
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

  test("임의로 조합한 문서도 조각 단위로 보존된다(속성 테스트)", async () => {
    // 왜 속성 테스트인가: 문법을 하나씩 세는 방식은 **우리가 떠올린 것만** 검사한다. 보존 규칙의 값어치는
    // 목록에 없는 문법에서 나오므로, 조각을 무작위로 이어 붙여 "원문 조각이 출력에 그대로 남는가"를 본다.
    // 결정적으로 돌려야 하므로 난수 대신 고정 시드 LCG를 쓴다 — 실패를 재현할 수 없으면 가드가 아니다.
    const fragments = [
      "# 제목",
      "본문 한 줄",
      "- 목록 항목",
      "> 인용",
      "<details>\n<summary>접기</summary>\n안쪽\n</details>",
      "<!-- 주석 -->",
      "[^ref]: 각주 정의",
      "문장 안 <kbd>⌘S</kbd> 태그",
      "참조[^ref] 포함 문장",
      "`인라인 코드`",
      "| a | b |\n| --- | --- |\n| 1 | 2 |",
      "```js\nconst a = 1;\n```",
      "![alt](img.png)",
      "---",
    ];
    // 보존 대상 조각(이 문자열이 출력에 그대로 남아야 한다). 제목·목록 등은 정규화가 허용되므로 제외한다.
    const mustSurvive = [
      "<details>",
      "</details>",
      "<!-- 주석 -->",
      "[^ref]: 각주 정의",
      "<kbd>",
      "</kbd>",
      "[^ref]",
    ];

    await withEditorDom(async (dom) => {
      let seed = 20260802;
      const next = (bound: number) => {
        seed = (seed * 1103515245 + 12345) % 2147483648;
        return seed % bound;
      };

      for (let round = 0; round < 40; round += 1) {
        const picked: string[] = [];
        const count = 2 + next(4);
        for (let i = 0; i < count; i += 1) picked.push(fragments[next(fragments.length)]);
        const source = picked.join("\n\n");

        const rich = mountRich(dom, source);
        try {
          const out = rich.getMarkdown();
          for (const needle of mustSurvive) {
            if (!source.includes(needle)) continue;
            // 코드펜스·인라인 코드 안에 들어간 경우는 내용이지 조각이 아니다 — 이 조합에서는 생기지 않지만
            // 실패 메시지에 원문을 실어 두면 회귀가 났을 때 어느 조합인지 바로 보인다.
            expect(`${needle} in ${JSON.stringify(out)}`).toContain(needle);
          }
        } finally {
          rich.destroy();
        }
      }
    });
  });
});
