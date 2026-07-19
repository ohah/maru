import { describe, expect, test } from "bun:test";
import { maxLivePreviewProjectionCodeUnits } from "../src/live-preview-protocol";
import { MarkdownProjectionIndex, projectMarkdown } from "../src/project-markdown";

describe("live preview block projection", () => {
  test("keeps the selection block as source and renders only inactive visible blocks", () => {
    const source = "# Heading\n\nFirst paragraph.\n\nSecond **paragraph**.\n";
    const second = source.indexOf("Second");
    const fragments = projectMarkdown(source, [
      { from: 0, to: source.length, active: false },
      { from: second + 2, to: second + 2, active: true },
    ]);
    expect(fragments.map(({ kind }) => kind)).toEqual(["chunk", "paragraph"]);
    expect(fragments[0]?.html).toContain("<h1");
    expect(fragments[0]?.html).toContain("First paragraph");
    expect(fragments[1]?.html).toBeUndefined();
  });

  test("returns no offscreen HTML and bounds a giant block as source preserving", () => {
    const source = `# Top\n\n${"x".repeat(65 * 1024)}\n\nBottom\n`;
    const giant = source.indexOf("x");
    const fragments = projectMarkdown(source, [{ from: giant, to: giant + 1, active: false }]);
    expect(fragments).toHaveLength(1);
    expect(fragments[0]?.kind).toBe("paragraph");
    expect(fragments[0]?.html).toBeUndefined();
  });

  test("groups inactive blocks at the 16-block scheduling boundary", () => {
    const source = Array.from({ length: 20 }, (_, index) => `Paragraph ${index}.`).join("\n\n");
    const fragments = projectMarkdown(source, [{ from: 0, to: source.length, active: false }]);
    expect(fragments).toHaveLength(2);
    expect(fragments[0]).toMatchObject({ from: 0, kind: "chunk" });
    expect(fragments[1]?.to).toBe(source.length);
    expect(fragments.every(({ html }) => html !== undefined)).toBe(true);
  });

  test("merges adjacent inactive scheduling chunks when their count would exceed eight", () => {
    const source = Array.from({ length: 160 }, (_, index) => `P${index}.`).join("\n\n");
    const fragments = projectMarkdown(source, [{ from: 0, to: source.length, active: false }]);
    expect(fragments).toHaveLength(1);
    expect(fragments[0]).toMatchObject({ from: 0, to: source.length, kind: "chunk" });
    expect(fragments[0]?.html).toContain("P159.");
  });

  test("does not merge across an active source block while compacting inactive neighbors", () => {
    const source = Array.from({ length: 40 }, (_, index) => `Paragraph ${index}.`).join("\n\n");
    const active = source.indexOf("Paragraph 20");
    const fragments = projectMarkdown(source, [
      { from: 0, to: source.length, active: false },
      { from: active + 2, to: active + 2, active: true },
    ]);
    expect(fragments).toHaveLength(5);
    expect(fragments.filter(({ html }) => html === undefined)).toEqual([
      expect.objectContaining({ from: active, kind: "paragraph" }),
    ]);
    expect(fragments.every(({ to }, index) => index === 0 || to > fragments[index - 1]!.to)).toBe(
      true,
    );
  });

  test("keeps image assets and inert Mermaid fences as source until their capabilities ship", () => {
    const source = "![local](fixture.png)\n\n```mermaid\ngraph TD\n  A --> B\n```\n";
    const fragments = projectMarkdown(source, [{ from: 0, to: source.length, active: false }]);
    expect(fragments).toHaveLength(2);
    expect(fragments.every((fragment) => fragment.html === undefined)).toBe(true);
  });

  test("queries an 8 MiB document repeatedly without a full-document Markdown parse", () => {
    const source = `${"x\n\n".repeat(Math.floor((8 * 1024 * 1024) / 3))}tail`;
    const index = new MarkdownProjectionIndex(source);
    for (let iteration = 0; iteration < 1_000; iteration += 1) {
      const from = (iteration * 7919) % (source.length - 16);
      const fragments = index.project([{ from, to: from + 16, active: false }]);
      expect(fragments.length).toBeLessThanOrEqual(8);
      expect(
        fragments.every(({ from: start, to }) => to - start <= maxLivePreviewProjectionCodeUnits),
      ).toBe(true);
    }
  });

  test("hard-caps discovery for an exact-cap document with no newline", () => {
    const source = "x".repeat(8 * 1024 * 1024);
    const index = new MarkdownProjectionIndex(source);
    for (const from of [0, Math.floor(source.length / 2), source.length - 1]) {
      const fragments = index.project([{ from, to: from + 1, active: false }]);
      expect(fragments).toHaveLength(1);
      const fragment = fragments[0]!;
      expect(fragment.to - fragment.from).toBeLessThanOrEqual(maxLivePreviewProjectionCodeUnits);
      expect(fragment.html).toBeUndefined();
    }
  });

  test("uses a full-document selection only to mark blocks inside the bounded viewport active", () => {
    const source = `${"x\n\n".repeat(Math.floor((8 * 1024 * 1024) / 3))}tail`;
    const middle = Math.floor(source.length / 2);
    const fragments = projectMarkdown(source, [
      { from: middle, to: middle + 4_096, active: false },
      { from: 0, to: source.length, active: true },
    ]);
    expect(fragments).toHaveLength(8);
    expect(fragments.every(({ html }) => html === undefined)).toBe(true);
    const covered =
      Math.max(...fragments.map(({ to }) => to)) - Math.min(...fragments.map(({ from }) => from));
    expect(covered).toBeLessThanOrEqual(maxLivePreviewProjectionCodeUnits);
  });
});
