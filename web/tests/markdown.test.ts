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
});

test("Mermaid SVG sanitizer removes executable and network-capable sinks", () => {
  const testWindow = new JSDOM("").window;
  const svg = sanitizeMermaidSvg(
    `<svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)">
      <style>@import url(https://example.com/leak.css)</style>
      <foreignObject><iframe src="https://example.com"></iframe></foreignObject>
      <a href="javascript:alert(2)"><text>safe label</text></a>
    </svg>`,
    testWindow as unknown as Window,
  );

  expect(svg).toContain("safe label");
  expect(svg).not.toContain("onload");
  expect(svg).not.toContain("style");
  expect(svg).not.toContain("foreignObject");
  expect(svg).not.toContain("iframe");
  expect(svg).not.toContain("javascript:");
  expect(svg).not.toContain("https://");
});
