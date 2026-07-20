import { describe, expect, test } from "bun:test";
import {
  atomicProjectionBatchWireBytes,
  atomicSourceHash,
  startAtomicSourceHashProbe,
  maxAtomicSourceBytes,
  type AtomicProjectionRequest,
} from "../src/atomic-projection";
import { projectAtomicRequests } from "../src/project-atomic";
import { isProjectionResult, maxLivePreviewResultBytes } from "../src/live-preview-protocol";
import { startSha256SourceProbe } from "../src/sha256";

function request(
  source: string,
  kind: AtomicProjectionRequest["kind"],
  requestNonce = 1,
): AtomicProjectionRequest {
  return {
    editorEpoch: 7,
    documentRevision: 3,
    projectionGeneration: 5,
    requestNonce,
    kind,
    from: 0,
    to: source.length,
  };
}

describe("atomic projection worker", () => {
  test("renders image, KaTeX, and Prism payloads without exposing asset paths to the renderer", () => {
    const image = "![safe](images/picture.svg)";
    const imageBatch = projectAtomicRequests(image, [request(image, "image")]);
    expect(imageBatch.rejected).toEqual([]);
    expect(imageBatch.results[0]?.sanitizedPayload).toContain('data-maru-asset-id="1"');
    expect(imageBatch.results[0]?.sanitizedPayload).not.toContain("images/picture.svg");
    expect(imageBatch.results[0]?.assetGrants).toEqual([
      expect.objectContaining({
        editorEpoch: 7,
        opaqueId: 1,
        normalizedPath: "images/picture.svg",
        expectedMimeFamily: "svg-image",
      }),
    ]);

    const math = "$x^2$";
    expect(
      projectAtomicRequests(math, [request(math, "math")]).results[0]?.sanitizedPayload,
    ).toContain("<math");
    const code = "```ts\nconst value = 1;\n```";
    expect(
      projectAtomicRequests(code, [request(code, "fenced-code")]).results[0]?.sanitizedPayload,
    ).toContain("language-ts");
  });

  test("admits the exact 256 KiB fence and rejects cap plus one before hashing or rendering", () => {
    const cap = maxAtomicSourceBytes["fenced-code"];
    const exact = `\`\`\`\n${"x".repeat(cap - 8)}\n\`\`\``;
    const exactBatch = projectAtomicRequests(exact, [request(exact, "fenced-code")]);
    expect(exactBatch.results).toHaveLength(1);
    expect(exactBatch.hashedBytes).toBe(cap);
    expect(
      new TextEncoder().encode(exactBatch.results[0]?.sanitizedPayload ?? "").byteLength,
    ).toBeLessThanOrEqual(maxLivePreviewResultBytes);

    const over = `${exact}x`;
    const overBatch = projectAtomicRequests(over, [request(over, "fenced-code")]);
    expect(overBatch.results).toEqual([]);
    expect(overBatch.rejected).toEqual([{ requestNonce: 1, reason: "rich-source-limit" }]);
    expect(overBatch.hashedBytes).toBe(0);
  });

  test("keeps token-dense exact-cap code bounded and rejects only an aggregate overflow range", () => {
    const cap = maxAtomicSourceBytes["fenced-code"];
    const dense = `\`\`\`ts\n${"const a=1;".repeat(Math.floor((cap - 10) / 10))}\n\`\`\``;
    const exact = dense.padEnd(cap, " ");
    const denseBatch = projectAtomicRequests(exact, [request(exact, "fenced-code")]);
    expect(denseBatch.results).toHaveLength(1);
    expect(
      new TextEncoder().encode(denseBatch.results[0]?.sanitizedPayload ?? "").byteLength,
    ).toBeLessThanOrEqual(maxLivePreviewResultBytes);

    const math = `$${"x+".repeat(2_000)}x$`;
    const requests = Array.from({ length: 8 }, (_, index) => ({
      ...request(math, "math", index + 1),
    }));
    const aggregate = projectAtomicRequests(math, requests);
    const resultBytes = aggregate.results.reduce(
      (sum, result) => sum + new TextEncoder().encode(result.sanitizedPayload).byteLength,
      0,
    );
    expect(resultBytes).toBeLessThanOrEqual(maxLivePreviewResultBytes);
    expect(aggregate.results.length + aggregate.rejected.length).toBe(8);
    expect(aggregate.rejected.every(({ reason }) => reason === "rich-source-limit")).toBe(true);
    expect(
      atomicProjectionBatchWireBytes(aggregate.results, aggregate.rejected),
    ).toBeLessThanOrEqual(maxLivePreviewResultBytes);
    expect(
      isProjectionResult({
        type: "result",
        editorEpoch: 7,
        documentRevision: 3,
        projectionGeneration: 5,
        results: aggregate.results,
        rejected: aggregate.rejected,
      }),
    ).toBe(true);
  });

  test("bounds one exact eight-fence batch at two MiB of worker hashing", () => {
    const cap = maxAtomicSourceBytes["fenced-code"];
    const parts = Array.from(
      { length: 8 },
      (_, index) => `\`\`\`\n${String(index).repeat(cap - 8)}\n\`\`\``,
    );
    const source = parts.join("\n");
    let offset = 0;
    const requests = parts.map((part, index) => {
      const projected = {
        ...request(part, "fenced-code", index + 1),
        from: offset,
        to: offset + part.length,
      };
      offset += part.length + 1;
      return projected;
    });
    const batch = projectAtomicRequests(source, requests);
    expect(batch.hashedBytes).toBe(8 * cap);
    expect(batch.results.length + batch.rejected.length).toBe(8);
    expect(batch.rejected.every(({ reason }) => reason === "rich-source-limit")).toBe(true);
  });

  test("rejects traversal and external image references and keeps raw HTML inert", () => {
    for (const path of ["../secret.png", "/tmp/secret.png", "a\\b.png", "https://evil/x.png"]) {
      const source = `![x](${path})`;
      const result = projectAtomicRequests(source, [request(source, "image")]).results[0];
      expect(result?.assetGrants).toEqual([]);
      expect(result?.sanitizedPayload).not.toContain(path);
    }
    const raw = "<img src=x onerror=alert(1)>";
    const result = projectAtomicRequests(raw, [request(raw, "image")]).results[0];
    expect(result?.sanitizedPayload).not.toContain("onerror");
    expect(result?.sanitizedPayload).not.toContain("<img");
  });

  test("uses deterministic hashes and emits a helper-ready Mermaid source", () => {
    expect(atomicSourceHash("same")).toBe(atomicSourceHash("same"));
    expect(atomicSourceHash("same")).not.toBe(atomicSourceHash("different"));
    const mermaid = "```mermaid\ngraph TD\n```";
    expect(projectAtomicRequests(mermaid, [request(mermaid, "mermaid")])).toMatchObject({
      results: [
        {
          request: expect.objectContaining({ kind: "mermaid" }),
          sourceHash: "2151a7a6ec2eaff56c93602c3b07382d7bd484e8e572852da1ffe6b874656bd8",
          sanitizedPayload: "",
          assetGrants: [],
          mermaidSource: mermaid,
        },
      ],
      rejected: [],
      hashedBytes: 23,
    });
  });

  test("hashes Mermaid only once with SHA-256 and rejects cap plus one before either hash", () => {
    const exact = "x".repeat(maxAtomicSourceBytes.mermaid);
    const fnv = startAtomicSourceHashProbe();
    const sha = startSha256SourceProbe();
    const batch = projectAtomicRequests(exact, [request(exact, "mermaid", 501)]);
    expect(fnv.stop()).toBe(0);
    expect(sha.stop()).toBe(maxAtomicSourceBytes.mermaid);
    expect(batch.hashedBytes).toBe(maxAtomicSourceBytes.mermaid);

    const over = `${exact}x`;
    const overFnv = startAtomicSourceHashProbe();
    const overSha = startSha256SourceProbe();
    const rejected = projectAtomicRequests(over, [request(over, "mermaid", 502)]);
    expect(overFnv.stop()).toBe(0);
    expect(overSha.stop()).toBe(0);
    expect(rejected.hashedBytes).toBe(0);
  });
});
