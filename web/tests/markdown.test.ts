import { describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { renderMarkdown } from "../src/markdown";
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
      <rect id="external" fill="url(https://evil.test/paint.svg#x)" stroke="url(//evil.test/stroke.svg#x)" filter="url(relative.svg#x)" clip-path="url(data:image/svg+xml,x)" mask="u/**/rl(https://evil.test/mask.svg#x)" marker-start="u\\72l(https://evil.test/marker.svg#x)" />
      <text>plain label</text>
    </svg>`,
    testWindow as unknown as Window,
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
});
