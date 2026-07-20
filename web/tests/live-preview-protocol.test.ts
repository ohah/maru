import { describe, expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import {
  applySourceChanges,
  applySourceChangesBounded,
  insertedBytes,
  isLivePreviewRequest,
  isProjectionResult,
  maxLivePreviewResultBytes,
  maxLivePreviewSourceBytes,
  maxLivePreviewWorkers,
  projectionResultIsCurrent,
} from "../src/live-preview-protocol";
import { atomicProjectionBatchWireBytes } from "../src/atomic-projection";

const atomic = {
  editorEpoch: 1,
  documentRevision: 3,
  projectionGeneration: 5,
  requestNonce: 7,
  kind: "image",
  from: 0,
  to: 4,
} as const;

describe("atomic live preview worker protocol", () => {
  test("accepts exact seed/apply/project identities and rejects duplicate or mismatched nonces", () => {
    expect(
      isLivePreviewRequest({ type: "seed", editorEpoch: 1, documentRevision: 0, source: "seed" }),
    ).toBe(true);
    expect(
      isLivePreviewRequest({
        type: "project",
        editorEpoch: 1,
        documentRevision: 3,
        projectionGeneration: 5,
        requests: [atomic],
      }),
    ).toBe(true);
    expect(
      isLivePreviewRequest({
        type: "apply",
        editorEpoch: 1,
        baseRevision: 2,
        targetRevision: 3,
        changes: [{ from: 0, to: 1, insert: "A" }],
        projectionGeneration: 5,
        requests: [atomic],
      }),
    ).toBe(true);
    expect(
      isLivePreviewRequest({
        type: "project",
        editorEpoch: 1,
        documentRevision: 3,
        projectionGeneration: 5,
        requests: [atomic, atomic],
      }),
    ).toBe(false);
    expect(
      isLivePreviewRequest({
        type: "project",
        editorEpoch: 2,
        documentRevision: 3,
        projectionGeneration: 5,
        requests: [atomic],
      }),
    ).toBe(false);
    expect(
      isLivePreviewRequest({
        type: "seed",
        editorEpoch: 1,
        documentRevision: 1,
        source: "x".repeat(maxLivePreviewSourceBytes + 1),
      }),
    ).toBe(false);
  });

  test("validates result capability, payload budget, and one terminal outcome per nonce", () => {
    const projected = {
      request: atomic,
      sourceHash: "0123456789abcdef",
      sanitizedPayload: "<p>safe</p>",
      assetGrants: [],
      mermaidSource: null,
    } as const;
    const result = {
      type: "result",
      editorEpoch: 1,
      documentRevision: 3,
      projectionGeneration: 5,
      results: [projected],
      rejected: [],
    } as const;
    expect(isProjectionResult(result)).toBe(true);
    expect(projectionResultIsCurrent(result, 1, 3, 5)).toBe(true);
    expect(projectionResultIsCurrent(result, 2, 3, 5)).toBe(false);
    expect(
      isProjectionResult({
        ...result,
        rejected: [{ requestNonce: atomic.requestNonce, reason: "rich-source-limit" }],
      }),
    ).toBe(false);
    expect(
      isProjectionResult({
        ...result,
        results: [{ ...projected, sanitizedPayload: "x".repeat(maxLivePreviewResultBytes + 1) }],
      }),
    ).toBe(false);
  });

  test("revalidates Mermaid UTF-8 bytes and line count at the worker result boundary", () => {
    const request = { ...atomic, kind: "mermaid" as const };
    const result = (mermaidSource: string) => ({
      type: "result" as const,
      editorEpoch: 1,
      documentRevision: 3,
      projectionGeneration: 5,
      results: [
        {
          request,
          sourceHash: "a".repeat(64),
          sanitizedPayload: "",
          assetGrants: [],
          mermaidSource,
        },
      ],
      rejected: [],
    });
    expect(isProjectionResult(result("x".repeat(32 * 1024)))).toBe(true);
    expect(isProjectionResult(result("x".repeat(32 * 1024 + 1)))).toBe(false);
    expect(isProjectionResult(result("😀".repeat(8 * 1024)))).toBe(true);
    expect(isProjectionResult(result(`${"😀".repeat(8 * 1024)}x`))).toBe(false);
    expect(isProjectionResult(result(`${"x\n".repeat(511)}x`))).toBe(true);
    expect(isProjectionResult(result(`${"x\n".repeat(512)}x`))).toBe(false);
  });

  test("counts envelope, grant, and rejection metadata in exact whole-batch admission", () => {
    const grant = {
      editorEpoch: 1,
      assetNonce: 71,
      opaqueId: 1,
      normalizedPath: `${"a".repeat(4_000)}.png`,
      expectedMimeFamily: "raster-image" as const,
    };
    const base = {
      request: atomic,
      sourceHash: "0123456789abcdef",
      sanitizedPayload: "",
      assetGrants: [grant],
      mermaidSource: null,
    };
    const singleOverhead = atomicProjectionBatchWireBytes([base], []);
    const exact = {
      ...base,
      sanitizedPayload: "x".repeat(maxLivePreviewResultBytes - singleOverhead),
    };
    expect(atomicProjectionBatchWireBytes([exact], [])).toBe(maxLivePreviewResultBytes);
    expect(
      isProjectionResult({
        type: "result",
        editorEpoch: 1,
        documentRevision: 3,
        projectionGeneration: 5,
        results: [exact],
        rejected: [],
      }),
    ).toBe(true);
    expect(
      isProjectionResult({
        type: "result",
        editorEpoch: 1,
        documentRevision: 3,
        projectionGeneration: 5,
        results: [{ ...exact, sanitizedPayload: `${exact.sanitizedPayload}x` }],
        rejected: [],
      }),
    ).toBe(false);

    const rejection = { requestNonce: atomic.requestNonce + 1, reason: "rich-source-limit" };
    expect(
      isProjectionResult({
        type: "result",
        editorEpoch: 1,
        documentRevision: 3,
        projectionGeneration: 5,
        results: [exact],
        rejected: [rejection],
      }),
    ).toBe(false);
    const mixedOverhead = atomicProjectionBatchWireBytes([base], [rejection]);
    const exactMixed = {
      ...base,
      sanitizedPayload: "x".repeat(maxLivePreviewResultBytes - mixedOverhead),
    };
    expect(atomicProjectionBatchWireBytes([exactMixed], [rejection])).toBe(
      maxLivePreviewResultBytes,
    );
    expect(
      isProjectionResult({
        type: "result",
        editorEpoch: 1,
        documentRevision: 3,
        projectionGeneration: 5,
        results: [exactMixed],
        rejected: [rejection],
      }),
    ).toBe(true);
    expect(
      isProjectionResult({
        type: "result",
        editorEpoch: 1,
        documentRevision: 3,
        projectionGeneration: 5,
        results: [{ ...exactMixed, sanitizedPayload: `${exactMixed.sanitizedPayload}x` }],
        rejected: [rejection],
      }),
    ).toBe(false);
  });

  test("applies ordered UTF-16-safe changes within the retained source cap", () => {
    expect(insertedBytes([{ from: 0, to: 0, insert: "한" }])).toBe(3);
    expect(
      applySourceChanges("abcdef", [
        { from: 1, to: 2, insert: "B" },
        { from: 4, to: 6, insert: "EF" },
      ]),
    ).toBe("aBcdEF");
    expect(
      applySourceChanges("abcdef", [
        { from: 2, to: 4, insert: "x" },
        { from: 3, to: 5, insert: "y" },
      ]),
    ).toBeNull();
    expect(applySourceChangesBounded("😀a", 5, [{ from: 0, to: 1, insert: "" }])).toBeNull();
    expect(applySourceChangesBounded("😀a", 5, [{ from: 0, to: 2, insert: "한" }])).toEqual({
      source: "한a",
      sourceBytes: 4,
    });
  });

  test("matches the C ABI live-preview limit snapshot", async () => {
    const header = await readFile(
      new URL("../../src/platform/macos/app_host_abi.h", import.meta.url),
      "utf8",
    );
    const macro = (name: string): number => {
      const value = new RegExp(`^#define ${name} (\\d+)u$`, "m").exec(header)?.[1];
      if (value === undefined) throw new Error(`missing ${name}`);
      return Number(value);
    };
    expect(macro("MARU_LIVE_PREVIEW_MAX_WORKERS")).toBe(maxLivePreviewWorkers);
    expect(macro("MARU_LIVE_PREVIEW_SOURCE_BYTES_PER_WORKER")).toBe(maxLivePreviewSourceBytes);
    expect(macro("MARU_LIVE_PREVIEW_RESULT_BYTES_PER_WORKER")).toBe(maxLivePreviewResultBytes);
  });
});
