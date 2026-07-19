import { describe, expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import {
  applySourceChanges,
  applySourceChangesBounded,
  insertedBytes,
  isLivePreviewRequest,
  isProjectionResult,
  maxLivePreviewProjectionCodeUnits,
  maxLivePreviewResultBytes,
  maxLivePreviewSourceBytes,
  maxLivePreviewWorkers,
  projectionResultIsCurrent,
} from "../src/live-preview-protocol";

describe("live preview worker protocol", () => {
  test("accepts bounded seed/apply/project and rejects gaps, invalid ranges, and cap+1", () => {
    expect(isLivePreviewRequest({ type: "seed", documentRevision: 0, source: "# seed" })).toBe(
      true,
    );
    expect(
      isLivePreviewRequest({
        type: "apply",
        baseRevision: 2,
        targetRevision: 3,
        changes: [{ from: 0, to: 1, insert: "A" }],
        projectionGeneration: 4,
        visibleRanges: [
          { from: 0, to: 8, active: false },
          { from: 2, to: 2, active: true },
        ],
      }),
    ).toBe(true);
    expect(
      isLivePreviewRequest({
        type: "project",
        documentRevision: 3,
        projectionGeneration: 5,
        visibleRanges: [{ from: 0, to: 8, active: false }],
      }),
    ).toBe(true);
    expect(
      isLivePreviewRequest({
        type: "project",
        documentRevision: 3,
        projectionGeneration: 5,
        visibleRanges: [],
      }),
    ).toBe(false);
    expect(
      isLivePreviewRequest({
        type: "project",
        documentRevision: 3,
        projectionGeneration: 5,
        visibleRanges: [{ from: 0, to: 8, active: true }],
      }),
    ).toBe(false);
    expect(
      isLivePreviewRequest({
        type: "apply",
        baseRevision: 3,
        targetRevision: 3,
        changes: [],
        projectionGeneration: 4,
        visibleRanges: [],
      }),
    ).toBe(false);
    expect(
      isLivePreviewRequest({
        type: "project",
        documentRevision: 3,
        projectionGeneration: 5,
        visibleRanges: [
          { from: 0, to: 8, active: false },
          { from: 9, to: 10, active: false },
        ],
      }),
    ).toBe(false);
    expect(
      isLivePreviewRequest({
        type: "project",
        documentRevision: 3,
        projectionGeneration: 5,
        visibleRanges: [{ from: 0, to: maxLivePreviewProjectionCodeUnits + 1, active: false }],
      }),
    ).toBe(false);
    expect(
      isLivePreviewRequest({
        type: "apply",
        baseRevision: 2,
        targetRevision: 3,
        changes: [{ from: 4, to: 3, insert: "x" }],
        projectionGeneration: 4,
        visibleRanges: [],
      }),
    ).toBe(false);
    expect(
      isLivePreviewRequest({
        type: "seed",
        documentRevision: 1,
        source: "x".repeat(maxLivePreviewSourceBytes + 1),
      }),
    ).toBe(false);
  });

  test("applies ordered changes and rejects overlap or an out-of-bounds edit", () => {
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
    expect(applySourceChanges("abc", [{ from: 0, to: 4, insert: "" }])).toBeNull();
  });

  test("bounds inserted UTF-8 bytes and rejects oversized or stale results", () => {
    expect(insertedBytes([{ from: 0, to: 0, insert: "한" }])).toBe(3);
    const result = {
      type: "result",
      documentRevision: 7,
      projectionGeneration: 9,
      fragments: [{ from: 0, to: 4, kind: "heading", html: "<h1>x</h1>" }],
    } as const;
    expect(isProjectionResult(result)).toBe(true);
    expect(projectionResultIsCurrent(result, 7, 9)).toBe(true);
    expect(projectionResultIsCurrent(result, 8, 9)).toBe(false);
    expect(
      isProjectionResult({
        ...result,
        fragments: Array.from({ length: 9 }, (_, index) => ({
          from: index,
          to: index + 1,
          kind: "paragraph",
        })),
      }),
    ).toBe(false);
  });

  test("keeps authoritative worker source bytes at or below the cap", () => {
    const exact = "x".repeat(maxLivePreviewSourceBytes);
    expect(
      applySourceChangesBounded(exact, maxLivePreviewSourceBytes, [
        { from: exact.length, to: exact.length, insert: "y" },
      ]),
    ).toBeNull();
    const replaced = applySourceChangesBounded("한a", 4, [{ from: 0, to: 1, insert: "b" }]);
    expect(replaced).toEqual({ source: "ba", sourceBytes: 2 });
    const emoji = "😀".repeat(maxLivePreviewSourceBytes / 4);
    expect(
      applySourceChangesBounded(emoji, maxLivePreviewSourceBytes, [
        { from: 0, to: 1, insert: "" },
        { from: emoji.length, to: emoji.length, insert: "xx" },
      ]),
    ).toBeNull();
    const wholeEmoji = applySourceChangesBounded("😀a", 5, [{ from: 0, to: 2, insert: "한" }]);
    expect(wholeEmoji).toEqual({ source: "한a", sourceBytes: 4 });
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
