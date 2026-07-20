import { describe, expect, test } from "bun:test";
import { mermaidFenceBody } from "../src/mermaid-fence";

describe("Mermaid fenced source boundary", () => {
  test("accepts backtick, tilde, longer closing fence, and CRLF", () => {
    expect(mermaidFenceBody("```mermaid\nflowchart TD\n  A --> B\n```")).toContain("A --> B");
    expect(mermaidFenceBody("~~~Mermaid\r\nflowchart TD\r\n  A --> B\r\n~~~~")).toContain(
      "A --> B",
    );
    expect(mermaidFenceBody("```` mermaid\nflowchart TD\n`````")).toBe("flowchart TD");
  });

  test("rejects mixed, shorter, over-indented, and non-Mermaid fences", () => {
    expect(mermaidFenceBody("```mermaid\nflowchart TD\n~~~")).toBeNull();
    expect(mermaidFenceBody("````mermaid\nflowchart TD\n```")).toBeNull();
    expect(mermaidFenceBody("    ```mermaid\nflowchart TD\n    ```")).toBeNull();
    expect(mermaidFenceBody("```js\nflowchart TD\n```")).toBeNull();
  });
});
