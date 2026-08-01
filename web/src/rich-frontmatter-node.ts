/**
 * 리치 편집기의 frontmatter 블록(docs/file-panel.md §2.5).
 *
 * 문서 맨 앞 메타데이터를 **보이고 고칠 수 있는 한 블록**으로 둔다. 예전에는 frontmatter가 있으면 편집 자체를
 * 잠갔다 — 문서모델에 대응 노드가 없어 왕복에서 `## title: 문서`로 뭉개졌기 때문이다. 노드를 주면 그 이유가
 * 사라진다.
 *
 * **안쪽은 평문이다.** YAML을 파싱하지 않고 줄 그대로 보관한다 — 우리가 해석해서 다시 쓰면 따옴표·들여쓰기·
 * 주석 같은 것이 정규화되고, 그건 이 모드가 피하려는 손실 그 자체다. 서식 마크도 붙지 않는다(`marks: ""`).
 *
 * **문서에 하나, 맨 앞에만** 존재한다. 위치가 곧 정의라 본문 중간의 `---`는 구분선으로 남아야 한다 —
 * 그 판정은 `frontmatter.ts`가 경계에서 하고, 이 노드는 "이미 갈라진 것"을 담기만 한다.
 */

import { Node } from "@tiptap/core";

import { joinFrontmatter } from "./frontmatter";

export const frontmatterNodeName = "frontmatter";

export const Frontmatter = Node.create({
  name: frontmatterNodeName,
  group: "block",
  content: "text*",
  marks: "",
  code: true,
  defining: true,
  // 다른 블록과 병합되지 않게 한다. 안 그러면 Backspace 한 번에 뒤 문단이 메타데이터 안으로 빨려 들어간다.
  isolating: true,
  parseHTML() {
    return [{ tag: "pre[data-maru-frontmatter]", preserveWhitespace: "full" as const }];
  },
  renderHTML() {
    return ["pre", { "data-maru-frontmatter": "", class: "maru-rich-frontmatter" }, 0];
  },
  // `@tiptap/markdown`이 이 이름으로 직렬화 핸들러를 찾는다. 파싱은 경계(`frontmatter.ts`)가 하므로
  // `parseMarkdown`은 두지 않는다 — 토크나이저로 잡으면 본문 중간의 구분선까지 삼킨다.
  renderMarkdown(node: { content?: { text?: string }[] }): string {
    const inner = (node.content ?? []).map((child) => child.text ?? "").join("");
    // 구분선 형식은 `frontmatter.ts`가 단독으로 소유한다 — 가르기와 되붙이기가 서로의 역함수라는 계약이
    // 거기 테스트로 걸려 있고, 형식을 여기에 한 번 더 적으면 그 계약 밖에서 갈라진다. 본문은 tiptap이
    // 뒤에 이어 붙이므로 여기서는 블록 하나만 내놓는다(`body`가 빈 문자열인 이유).
    return joinFrontmatter(inner, "");
  },
});
