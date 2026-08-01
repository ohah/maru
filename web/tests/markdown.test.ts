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

  test("frontmatter는 메타데이터라 프리뷰에 그리지 않는다(본문 중간 `---`는 구분선으로 남는다)", () => {
    // 이게 없으면 파서가 `---`를 구분선으로, 그 아래 줄을 setext 제목으로 읽어 `<hr>` + `<h2>title: 문서</h2>`가
    // 그려진다 — frontmatter가 있는 문서마다 보이던 것이라 사용자가 매번 마주친다.
    const html = renderMarkdown("---\ntitle: 문서\ntags: [a, b]\n---\n\n# 제목\n\n본문\n");
    expect(html).not.toContain("title: 문서");
    expect(html).not.toContain("<hr");
    expect(html).toContain("<h1");

    // 위치가 정의의 전부다 — 중간 구분선까지 삼키면 그 줄이 문서에서 사라진다.
    const middle = renderMarkdown("# 제목\n\n---\n\n본문\n");
    expect(middle).toContain("<hr");
    expect(middle).toContain("본문");
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
