/**
 * 리치가 문서모델로 옮기지 못한 원문 조각을 **그대로 담는 노드**(docs/file-panel.md §2.5 보존 규칙).
 *
 * 문법 하나마다 전용 노드를 더하는 대신 규칙 하나를 둔다 — **모르는 것은 원문 문자열로 통과시키고 직렬화 때
 * 글자 그대로 되쓴다.** 그러면 문법 목록으로 편집을 막던 잠금이 필요 없어진다. 저장 경로가 닫혀서가 아니라
 * 저장해도 원문이 그대로라서 안전하다.
 *
 * **블록과 인라인 둘로 나눈다.** 마크다운 토크나이저가 문단 레벨 HTML은 토큰 하나로, 문장 안 HTML은 여는·닫는
 * 태그를 **각각 별도 토큰**으로 준다(실측). 짝을 맞추려 들지 않고 조각 그대로 보존하면 왕복이 성립한다 —
 * `<kbd>`·`⌘S`·`</kbd>` 셋이 순서대로 남으면 다시 이어 붙였을 때 원문과 같다.
 *
 * **보존과 렌더는 별개 축이다**(§2.5). 보존은 항상 하고, 블록 조각에 한해 안전하게 그릴 수 있는 것만 미리보기를
 * 함께 보여 준다. 미리보기가 비면 원문만 남을 뿐 보존은 그대로다 — 렌더가 실패해도 문서는 손상되지 않는다.
 *
 * **인라인 조각에는 미리보기를 붙이지 않는다.** 여는·닫는 태그가 각각 별도 노드라 짝을 맞출 수 없고, 조각
 * 하나만 그리면 `<kbd>`가 빈 `<kbd></kbd>`로 자동 완성돼 원문에 없는 것이 보인다(실측).
 */

import { Node, type MarkdownParseResult, type MarkdownToken } from "@tiptap/core";
import { renderMarkdown } from "./markdown";

export const rawBlockName = "rawBlock";
export const rawInlineName = "rawInline";

/** 블록 조각은 마크다운 토크나이저가 이미 이 이름으로 준다. */
const rawBlockTokenName = "html";

/**
 * 인라인 조각은 **우리가 발행하는 토큰 이름**을 쓴다.
 *
 * `@tiptap/markdown`의 인라인 파서는 `html` 토큰을 **하드코딩으로** 처리해(여는·닫는 태그를 짝지어 스키마
 * 규칙에 맞춰 보고, 맞는 게 없으면 버린다) 등록된 `parseMarkdown`을 아예 부르지 않는다(소스 확인). 반면 그
 * 밖의 토큰 타입은 등록된 핸들러로 넘긴다. 그래서 같은 조각을 **다른 이름으로 발행**해 우리 노드가 받게 한다.
 */
const rawInlineTokenName = "maruRawInline";

/** 문장 안에서 태그 하나·주석 하나를 통째로 집는다. 짝을 맞추지 않는다 — 조각 그대로가 보존 단위다. */
const inlineRawPattern = /^(?:<!--[\s\S]*?-->|<\/?[a-zA-Z][a-zA-Z0-9-]*(?:\s[^<>]*?)?\/?>)/;

/**
 * 각주 참조(`[^1]`). **토크나이저가 이걸 떼어 주지 않아서** 그냥 텍스트로 오고, 직렬화가 대괄호를
 * `\[^1\]`로 이스케이프해 **각주가 리터럴 대괄호로 바뀐다**(실측). 그래서 인식만 시켜 주면 나머지는 보존
 * 규칙이 받는다 — §2.5가 말한 "노드 한 벌이 아니라 토큰 규칙 하나" 비용이 이것이다.
 */
const footnoteRefPattern = /^\[\^[^\]\s]+\]/;

/** 각주 정의(`[^1]: 내용`). 줄 맨 앞에서만 유효하고, 이어지는 들여쓴 줄은 그 정의에 딸린 본문이다. */
const footnoteDefPattern = /^\[\^[^\]\s]+\]:[^\n]*(?:\n(?:[ \t]+[^\n]*|[ \t]*(?=\n)))*/;

/**
 * "이 토큰은 내 것이 아니다"라는 신호.
 *
 * 파서는 등록된 핸들러를 차례로 시도하다 falsy를 만나면 다음으로 넘어간다(소스 확인). 그런데 공개 타입인
 * `MarkdownParseResult`에는 그 표현이 없어서, 캐스팅을 **여기 한 곳에** 모으고 이유를 남긴다.
 */
const notMine = null as unknown as MarkdownParseResult;

/** 토큰에서 원문을 꺼낸다. `raw`가 원문 전체이며, 없으면 보존할 것이 없다. */
function rawOf(token: MarkdownToken): string {
  return typeof token.raw === "string" ? token.raw : (token.text ?? "");
}

/**
 * 문단 레벨 원문 조각. **안쪽은 평문 텍스트**라 사용자가 그 자리에서 고칠 수 있다 — frontmatter 블록과 같은
 * 모양이다. 서식 마크는 붙지 않는다(`marks: ""`): 원문 조각에 굵게를 적용하면 되쓸 때 표현할 방법이 없다.
 */
export const RawBlock = Node.create({
  name: rawBlockName,
  group: "block",
  content: "text*",
  marks: "",
  code: true,
  defining: true,
  // 다른 블록과 병합되지 않게 한다. 안 그러면 Backspace 한 번에 뒤 문단이 원문 조각 안으로 빨려 들어간다.
  isolating: true,
  markdownTokenName: rawBlockTokenName,
  markdownTokenizer: {
    // 각주 정의를 `html` 블록 토큰으로 발행해 **같은 노드가** 받게 한다. 문법마다 노드를 더하지 않는다는
    // 것이 보존 규칙의 요점이고, 토큰 이름을 맞추는 것이 그 실현이다.
    name: rawBlockTokenName,
    level: "block" as const,
    /**
     * **개행 뒤의 `[^`만** 가리킨다. 문단 중간의 각주 참조까지 블록 시작으로 알리면 marked가 거기서 문단을
     * 끊어 원문에 없던 줄바꿈이 생긴다(실측: `앞[^a] 뒤` → `앞\n[^a] 뒤`).
     *
     * 문자열 맨 앞은 **일부러 보지 않는다.** marked가 이 콜백에 `src.slice(1)`을 넘기기 때문에, 맨 앞을
     * `[^`로 판정하면 원문 두 번째 글자부터가 각주 정의로 오인된다(위 실측이 정확히 그 경로였다 — `본문`은
     * 두 글자라 우연히 피해 갔다). 진짜 문서 첫 줄의 각주 정의는 블록 루프가 시작부터 `tokenize`를
     * 시도하므로 이 힌트 없이도 잡힌다.
     */
    start: (src: string) => src.indexOf("\n[^"),
    tokenize(src: string) {
      const match = footnoteDefPattern.exec(src);
      if (match === null) return undefined;
      return { type: rawBlockTokenName, raw: match[0], text: match[0], block: true };
    },
  },
  parseMarkdown(token: MarkdownToken): MarkdownParseResult {
    // `block`이 블록과 인라인을 가른다(실측). 두 노드가 같은 토큰 이름을 공유하므로 이 플래그로 **자기
    // 것만** 받아야 한다 — 안 그러면 먼저 등록된 쪽이 둘 다 삼켜 반대쪽이 스키마에서 버려진다.
    if (token.block !== true) return notMine;
    const raw = rawOf(token);
    if (raw.length === 0) return notMine;
    // 끝의 개행은 블록 사이 간격이지 조각의 일부가 아니다. 되쓸 때 직렬화가 다시 넣는다.
    const inner = raw.replace(/\n+$/, "");
    return { type: rawBlockName, content: [{ type: "text", text: inner }] };
  },
  renderMarkdown(node: { content?: { text?: string }[] }): string {
    // 끝에 개행을 붙이지 않는다 — 블록 사이 간격은 직렬화가 이미 넣으므로, 여기서 더하면 빈 줄이 하나씩
    // 늘어난다(실측: 주석 블록 뒤에 `\n\n\n`).
    return (node.content ?? []).map((child) => child.text ?? "").join("");
  },
  parseHTML() {
    return [{ tag: "pre[data-maru-raw-block]", preserveWhitespace: "full" as const }];
  },
  renderHTML() {
    return ["pre", { "data-maru-raw-block": "", class: "maru-rich-raw-block" }, 0];
  },
  /**
   * 소스 칸과 미리보기를 함께 그린다(§2.5 조건 ④ — **미리보기는 편집 대상이 아니다**).
   *
   * 편집은 `contentDOM`인 소스 칸에서만 일어나고, 미리보기는 그 결과를 비추기만 한다. 미리보기를 편집
   * 가능하게 두면 그 DOM 변경을 다시 HTML로 되쓸 방법이 없어 왕복이 깨진다.
   */
  addNodeView() {
    return ({ node }: { node: { textContent: string } }) => {
      const dom = document.createElement("div");
      dom.className = "maru-rich-raw";
      const preview = document.createElement("div");
      preview.className = "maru-rich-raw-preview";
      // **편집 대상이 아님을 DOM에도 못 박는다.** 클래스만으로는 ProseMirror가 이 안으로 커서를 넣는다.
      // 프로퍼티 대입이 아니라 **속성**으로 단다 — ProseMirror가 읽는 것이 속성이고, 프로퍼티 대입은 DOM
      // 구현에 따라 속성에 반영되지 않는다(실측: 속성이 null로 남았다).
      preview.setAttribute("contenteditable", "false");
      const contentDOM = document.createElement("pre");
      contentDOM.className = "maru-rich-raw-block";
      contentDOM.setAttribute("data-maru-raw-block", "");

      const paint = (raw: string) => {
        // **읽기와 정확히 같은 함수**를 쓴다(§2.5 조건 ①). 같은 파이프라인이라고 적어 두는 것보다 같은
        // 함수를 부르는 것이 갈라지지 않는 유일한 방법이다. shell 특유의 위험(문서가 `#renderer` 같은 id로
        // 부품을 가로채기)은 sanitizer가 `id`·`name`에 `user-content-` 접두사를 붙여 이미 막는다.
        //
        // 빈 결과면 그릴 것이 없다는 뜻이라 미리보기를 감추고 원문만 보여 준다 — 각주 정의·주석이 그 경우다.
        const html = renderMarkdown(raw);
        preview.innerHTML = html;
        preview.hidden = html.trim().length === 0;
      };
      paint(node.textContent);

      dom.append(preview, contentDOM);
      return {
        dom,
        contentDOM,
        update: (next: { type: { name: string }; textContent: string }) => {
          if (next.type.name !== rawBlockName) return false;
          paint(next.textContent);
          return true;
        },
      };
    };
  },
});

/**
 * 문장 안 원문 조각. **atom이다** — 인라인 노드 안에 편집 가능한 텍스트를 두면 커서가 조각 내부로 들어가
 * 조각과 본문의 경계가 흐려진다. 여기서는 조각 하나를 통째로 선택·삭제하는 단위로 두고, 고치는 일은 소스
 * 모드가 받는다(§2.5는 리치가 소스를 대체하지 않는다고 못 박는다).
 */
export const RawInline = Node.create({
  name: rawInlineName,
  group: "inline",
  inline: true,
  atom: true,
  selectable: true,
  addAttributes() {
    return {
      raw: {
        default: "",
        parseHTML: (element: HTMLElement) => element.getAttribute("data-raw") ?? "",
        renderHTML: (attributes: { raw?: string }) => ({ "data-raw": attributes.raw ?? "" }),
      },
    };
  },
  markdownTokenName: rawInlineTokenName,
  markdownTokenizer: {
    name: rawInlineTokenName,
    level: "inline" as const,
    start: (src: string) => {
      const tag = src.indexOf("<");
      const ref = src.indexOf("[^");
      if (tag === -1) return ref;
      return ref === -1 ? tag : Math.min(tag, ref);
    },
    tokenize(src: string) {
      const match = inlineRawPattern.exec(src) ?? footnoteRefPattern.exec(src);
      if (match === null) return undefined;
      return { type: rawInlineTokenName, raw: match[0], text: match[0] };
    },
  },
  parseMarkdown(token: MarkdownToken): MarkdownParseResult {
    const raw = rawOf(token);
    if (raw.length === 0) return notMine;
    return { type: rawInlineName, attrs: { raw } };
  },
  renderMarkdown(node: { attrs?: { raw?: string } }): string {
    return node.attrs?.raw ?? "";
  },
  parseHTML() {
    return [{ tag: "span[data-maru-raw-inline]" }];
  },
  renderHTML({ node }: { node: { attrs: { raw?: string } } }) {
    return [
      "span",
      {
        "data-maru-raw-inline": "",
        "data-raw": node.attrs.raw ?? "",
        class: "maru-rich-raw-inline",
      },
      node.attrs.raw ?? "",
    ];
  },
});
