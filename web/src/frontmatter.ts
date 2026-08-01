/**
 * YAML frontmatter 가르기(docs/file-panel.md §2.5).
 *
 * **왜 마크다운 파서에 맡기지 않는가**: frontmatter는 문법이 아니라 **문서 맨 앞이라는 위치**로 정의된다.
 * 같은 `---\n…\n---`가 본문 중간에 있으면 그건 구분선(thematic break)이고, 파서 토크나이저는 그 둘을 위치로
 * 구분하지 못한다 — 중간의 구분선을 frontmatter로 삼키면 본문이 통째로 사라진다. 그래서 경계에서 가른다.
 *
 * 리치 편집기는 이 함수로 앞부분을 떼어 **별도 블록**으로 보여 주고, 저장할 때 그대로 다시 붙인다. 예전에는
 * frontmatter가 있으면 편집 자체를 잠갔는데(왕복에서 `## title: 문서`로 뭉개졌다), 위치만 지키면 잠글 이유가 없다.
 */

export type SplitDocument = {
  /** `---` 구분선 **안쪽** 텍스트. frontmatter가 없으면 null이다(빈 문자열과 구분된다 — `---\n---`는 있는 것이다). */
  frontmatter: string | null;
  /** frontmatter를 뗀 나머지. 없으면 원문 그대로다. */
  body: string;
};

/** 여는 구분선. 문서 **첫 줄**이어야 하고 그 줄에 다른 글자가 없어야 한다. */
const opening = /^---[ \t]*\r?\n/;

/**
 * frontmatter를 가른다. 다음 셋 중 하나라도 아니면 frontmatter가 아니다(원문 그대로 돌려준다):
 * ⑴ 문서가 `---` 줄로 시작 ⑵ 뒤에 닫는 `---` 줄이 있음 ⑶ 그 사이가 문서 끝을 넘지 않음.
 *
 * 닫는 줄을 못 찾으면 **가르지 않는다** — 열기만 한 `---`는 구분선이고, 그걸 frontmatter로 보면 문서 전체가
 * 메타데이터 블록으로 빨려 들어간다.
 */
export function splitFrontmatter(markdown: string): SplitDocument {
  const open = opening.exec(markdown);
  if (open === null) return { frontmatter: null, body: markdown };
  const afterOpen = open[0].length;

  // 닫는 구분선은 **줄 전체**가 `---`인 첫 줄이다. 줄 시작에서만 찾아야 `a---b` 같은 본문이 안 걸린다.
  const closing = /^---[ \t]*(\r?\n|$)/m;
  const rest = markdown.slice(afterOpen);
  const close = closing.exec(rest);
  if (close === null || close.index === undefined) return { frontmatter: null, body: markdown };

  const inner = rest.slice(0, close.index);
  const body = rest.slice(close.index + close[0].length);
  // 안쪽 끝의 개행 하나는 구분선의 것이라 뺀다(다시 붙일 때 우리가 넣는다).
  return { frontmatter: inner.replace(/\r?\n$/, ""), body };
}

/**
 * 가른 것을 되붙인다. **`split`의 역함수여야 한다** — 왕복이 원문을 바꾸면 리치로 열었다 저장하는 것만으로
 * 파일이 달라진다(그게 예전에 편집을 잠갔던 이유다).
 *
 * frontmatter가 null이면 본문만 돌려준다.
 */
export function joinFrontmatter(frontmatter: string | null, body: string): string {
  if (frontmatter === null) return body;
  // 빈 frontmatter(`---\n---`)는 안쪽 줄이 **없다** — 무조건 개행을 넣으면 빈 줄이 하나 생겨 왕복이 어긋난다.
  if (frontmatter.length === 0) return `---\n---\n${body}`;
  return `---\n${frontmatter}\n---\n${body}`;
}

/** 읽기 프리뷰가 표로 그리는 한 항목. `value`는 **원문 그대로**이며 여러 줄일 수 있다. */
export type FrontmatterEntry = {
  key: string;
  /** `키:` 뒤 나머지 + 뒤따르는 들여쓴 줄들. 값이 없으면 빈 문자열이다. */
  value: string;
};

/** 최상위 `키:` 줄. 들여쓰기가 없어야 하고, 키에 `:`나 `#`가 없어야 한다. */
const topLevelKey = /^([^\s#][^:]*):(?:[ \t]+(.*))?$/;

/**
 * 표시용으로 항목을 뽑는다(읽기 프리뷰의 메타데이터 표).
 *
 * **YAML 파서를 쓰지 않는다.** 이건 값을 해석하는 게 아니라 **보여 주려고 줄을 묶는** 일이다. 파서를 쓰면
 * 앵커·태그·타입 캐스팅이 개입해 원문과 다른 것이 표에 뜨고(`draft: false` → `false`가 아닌 무엇), 문법이
 * 조금 어긋난 frontmatter는 통째로 표시에 실패한다. 여기서는 값을 **글자 그대로** 옮기므로 둘 다 없다.
 * 저장 경로가 YAML을 다시 쓰지 않는 것과 같은 이유다(`rich-frontmatter-node.ts`).
 *
 * 최상위 키가 하나도 없으면 빈 배열이다 — 호출자는 그때 표를 만들지 않는다.
 */
export function frontmatterEntries(frontmatter: string): FrontmatterEntry[] {
  const entries: FrontmatterEntry[] = [];
  let current: { key: string; lines: string[] } | null = null;

  const flush = () => {
    if (current === null) return;
    // 값 끝의 빈 줄은 표에서 빈 칸으로 보이므로 턴다. 안쪽 빈 줄은 값의 일부라 남긴다.
    entries.push({ key: current.key, value: current.lines.join("\n").replace(/\s+$/, "") });
    current = null;
  };

  for (const line of frontmatter.split("\n")) {
    const match = topLevelKey.exec(line);
    if (match !== null) {
      flush();
      current = { key: match[1].trimEnd(), lines: match[2] === undefined ? [] : [match[2]] };
      continue;
    }
    // 최상위 주석은 값이 아니라 문서에 대한 말이라 표에 넣지 않는다. 들여쓴 주석은 값 블록의 일부다.
    if (/^#/.test(line)) continue;
    // 키를 만나기 전의 줄은 버린다 — 붙일 곳이 없다.
    if (current !== null) current.lines.push(line);
  }
  flush();
  return entries;
}
