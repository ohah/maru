import { describe, expect, test } from "bun:test";
import type { WindowLike } from "dompurify";
import { JSDOM } from "jsdom";
import { renderMarkdown } from "../src/markdown";
import { normalizeAssetReference } from "../src/asset-path";
import { mermaidConfig, sanitizeMermaidSvg } from "../src/rich-render";

describe("markdown trust boundary", () => {
  test("drops raw script, event handlers, iframe, srcdoc, and forged position attributes", () => {
    const html = renderMarkdown(`
# safe

<script>alert(1)</script>
<img src=x onerror="alert(2)" data-maru-source-start="1:1:0">
<iframe srcdoc="<script>alert(3)</script>"></iframe>
`);

    expect(html).toContain("<h1");
    expect(html).not.toContain("<script");
    expect(html).not.toContain("onerror");
    expect(html).not.toContain("iframe");
    expect(html).not.toContain("srcdoc");
    expect(html).not.toContain('1:1:0"');
  });

  test("removes executable URLs and external resource loads while retaining safe links", () => {
    const html = renderMarkdown(`
[bad](javascript:alert(1))

[safe](https://example.com/docs)

![remote](https://example.com/tracker.png)
`);

    expect(html).not.toContain("javascript:");
    expect(html).toContain('href="https://example.com/docs"');
    expect(html).not.toContain('src="https://example.com/tracker.png"');
    expect(html).not.toContain("data-maru-asset-path");
  });

  test("retains only normalized local image paths as renderer-owned metadata", () => {
    const html = renderMarkdown(`
![local](./images//hello%20world.png?cache=1#preview)

![traversal](images/%2e%2e/secret.png)

![absolute](/tmp/secret.png)
`);

    expect(html).toContain('data-maru-asset-path="images/hello world.png"');
    expect(html).not.toContain("secret.png");
    expect(html).not.toContain("src=");
  });

  test("frontmatter는 메타데이터 표로 그린다(본문 중간 `---`는 구분선으로 남는다)", () => {
    // 이 handler가 없으면 파서가 `---`를 구분선으로, 그 아래 줄을 setext 제목으로 읽어 `<hr>` + `<h2>title: 문서</h2>`가
    // 그려진다 — frontmatter가 있는 문서마다 보이던 것이라 사용자가 매번 마주친다.
    const html = renderMarkdown("---\ntitle: 문서\ntags: [a, b]\n---\n\n# 제목\n\n본문\n");
    expect(html).toContain('class="maru-frontmatter"');
    // 키와 값이 갈라져야 한다 — `title: 문서` 한 덩어리로 보이면 그건 표가 아니라 제목으로 샌 옛 결함이다.
    expect(html).toContain("<th>title</th>");
    expect(html).toContain("<td>문서</td>");
    expect(html).toContain("<td>[a, b]</td>");
    expect(html).not.toContain("<hr");
    expect(html).toContain("<h1");

    // 위치가 정의의 전부다 — 중간 구분선까지 삼키면 그 줄이 문서에서 사라진다.
    const middle = renderMarkdown("# 제목\n\n---\n\n본문\n");
    expect(middle).toContain("<hr");
    expect(middle).toContain("본문");
    expect(middle).not.toContain("maru-frontmatter");
  });

  test("메타데이터 표는 값을 해석하지 않고 원문 그대로 옮긴다", () => {
    // 값을 YAML로 해석하면 표에 원문과 **다른 것**이 뜬다. 읽기 모드는 확인하러 오는 화면이라 그건 거짓말이다.
    const html = renderMarkdown(
      "---\n# 이 주석은 표에 넣지 않는다\ndraft: false\nquoted: 'value'\nnested:\n  key: 1\n  list:\n    - 하나\nempty:\n---\n\n본문\n",
    );

    expect(html).toContain("<td>false</td>");
    // 따옴표가 벗겨지면 값이 달라진 것이다.
    expect(html).toContain("<td>'value'</td>");
    // 중첩 블록은 들여쓰기까지 한 칸에 그대로 담는다(표는 표시일 뿐 구조를 재구성하지 않는다).
    expect(html).toContain("<td>  key: 1\n  list:\n    - 하나</td>");
    // 빈 값은 빈 칸이다. 키는 남아야 한다 — 문서에 그 키가 있다는 사실 자체가 정보다.
    expect(html).toContain("<th>empty</th><td></td>");
    // 최상위 주석은 값이 아니라 문서에 대한 말이라 표 밖이다.
    expect(html).not.toContain("이 주석은 표에 넣지 않는다");
  });

  test("표시할 최상위 키가 없으면 표를 만들지 않는다", () => {
    // 빈 표는 문서 맨 위에 이유 없는 테두리만 남긴다.
    expect(renderMarkdown("---\n---\n\n본문\n")).not.toContain("maru-frontmatter");
    expect(renderMarkdown("---\n# 주석뿐\n---\n\n본문\n")).not.toContain("maru-frontmatter");
  });

  test("emits renderer-owned source positions with character offsets", () => {
    const html = renderMarkdown("# title\n\nparagraph");

    expect(html).toContain('data-maru-source-start="1:1:0"');
    expect(html).toContain('data-maru-source-end="1:8:7"');
    expect(html).toContain('data-maru-source-start="3:1:9"');
  });

  test("renders GFM, MathML-only KaTeX, Prism code, and inert Mermaid source", () => {
    const html = renderMarkdown(`
| a | b |
| - | - |
| 1 | 2 |

$x^2$

\`\`\`js
const answer = 42;
\`\`\`

\`\`\`mermaid
flowchart TD
  A --> B
\`\`\`
`);

    expect(html).toContain("<table");
    expect(html).toContain("<math");
    expect(html).not.toContain("style=");
    expect(html).toContain("token keyword");
    expect(html).toContain("language-mermaid");
    expect(html).toContain("flowchart");
    expect(html).toContain(" TD");
    expect(mermaidConfig.securityLevel).toBe("strict");
    expect(mermaidConfig.htmlLabels).toBe(false);
  });

  test("removes resource sinks emitted by untrusted KaTeX input after the sanitizer boundary", () => {
    const html = renderMarkdown(`${String.raw`$\color{url(https://evil.test/a.css)}{x}$`}

${String.raw`$\href{https://evil.test/link}{x}$`}

${String.raw`$\includegraphics{https://evil.test/image.png}$`}`);

    expect(html).toContain("katex-error");
    expect(html).not.toContain("style=");
    expect(html).not.toContain('href="https://evil.test');
    expect(html).not.toContain("src=");
  });
});

describe("asset path policy", () => {
  test("normalizes local references and rejects URL, traversal, backslash, controls, and malformed percent encoding", () => {
    expect(normalizeAssetReference("./images//한글%20그림.png?x=1#y")).toBe("images/한글 그림.png");
    for (const path of [
      "../secret.png",
      "images/%2e%2e/secret.png",
      "/absolute.png",
      "https://example.com/a.png",
      "data:image/png,x",
      "//example.com/a.png",
      "images\\a.png",
      "images/%00a.png",
      "images/%zz.png",
      ".",
    ]) {
      expect(normalizeAssetReference(path)).toBeNull();
    }
  });
});

test("Mermaid SVG sanitizer removes executable and network-capable sinks", () => {
  const testWindow = new JSDOM("").window;
  const svg = sanitizeMermaidSvg(
    `<svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)">
      <style>@import url(https://example.com/leak.css)</style>
      <foreignObject><iframe src="https://example.com"></iframe></foreignObject>
      <a href="javascript:alert(2)"><text>safe label</text></a>
      <a href="https://evil.test/link"><text>remote link</text></a>
      <image href="https://evil.test/image.png" />
      <use href="https://evil.test/icons.svg#x" />
      <use href="//evil.test/protocol-relative.svg#x" />
      <filter><feImage href="https://evil.test/filter.png" /></filter>
      <defs><linearGradient id="safe-gradient" /></defs>
      <rect id="local" fill="url(#safe-gradient)" />
      <rect id="external" fill="url(https://evil.test/paint.svg#x)" stroke="url(//evil.test/stroke.svg#x)" filter="url(relative.svg#x)" clip-path="url(data:image/svg+xml,x)" mask="u/**/rl(https://evil.test/mask.svg#x)" marker-start="u\\72l(https://evil.test/marker.svg#x)" marker-mid="u\\110000rl(https://evil.test/invalid-high.svg#x)" marker-end="u\\ffffffrl(https://evil.test/invalid-max.svg#x)" />
      <text>plain label</text>
    </svg>`,
    testWindow as unknown as WindowLike,
  );

  expect(svg).toContain("plain label");
  expect(svg).toContain('fill="url(#safe-gradient)"');
  expect(svg).not.toContain("onload");
  expect(svg).not.toContain("style");
  expect(svg).not.toContain("foreignObject");
  expect(svg).not.toContain("iframe");
  expect(svg).not.toContain("javascript:");
  expect(svg).not.toContain("https://");
  expect(svg).not.toContain("<image");
  expect(svg).not.toContain("<use");
  expect(svg).not.toContain("<a ");
  expect(svg).not.toContain("feImage");
  expect(svg).not.toContain("//evil.test");
  expect(svg).not.toContain("relative.svg");
  expect(svg).not.toContain("data:image");
  expect(svg).not.toContain("u/**/rl");
  expect(svg).not.toContain("u\\72l");
  expect(svg).not.toContain("110000");
  expect(svg).not.toContain("ffffff");
});
