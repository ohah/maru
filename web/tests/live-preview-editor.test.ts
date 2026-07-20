import { describe, expect, test } from "bun:test";
import { ChangeSet } from "@codemirror/state";
import {
  fragmentRecordCanBeReused,
  mapLivePreviewRange,
  reconcileFragmentBatch,
} from "../src/live-preview-editor";

describe("live preview fragment frame budget", () => {
  test("never revives a capability from a stale projection generation", () => {
    const capability = {
      editorEpoch: 1,
      documentRevision: 2,
      projectionGeneration: 3,
      widgetId: 4,
      widgetGeneration: 5,
      rendererInstance: 6,
    };
    const range = { from: 10, to: 20 };
    expect(
      fragmentRecordCanBeReused(
        capability,
        { documentRevision: 2, projectionGeneration: 3 },
        range,
        range,
      ),
    ).toBe(true);
    expect(
      fragmentRecordCanBeReused(
        capability,
        { documentRevision: 2, projectionGeneration: 4 },
        range,
        range,
      ),
    ).toBe(false);
  });

  test("removes before adding and changes at most two iframe memberships per batch", () => {
    let current = [1, 2, 3, 4, 5, 6, 7, 8];
    const desired = [11, 12, 13, 14, 15, 16, 17, 18];
    const changes: Array<{ removed: number; added: number }> = [];
    while (
      current.some((value) => !desired.includes(value)) ||
      desired.some((v) => !current.includes(v))
    ) {
      const batch = reconcileFragmentBatch(current, desired, (left, right) => left === right);
      changes.push({ removed: batch.removed, added: batch.added });
      current = batch.next;
    }

    expect(current).toEqual(desired);
    expect(changes.every(({ removed, added }) => removed <= 2 && added <= 2)).toBe(true);
    expect(changes.slice(0, 4).every(({ removed, added }) => removed === 2 && added === 0)).toBe(
      true,
    );
    expect(changes.slice(4).every(({ removed, added }) => removed === 0 && added === 2)).toBe(true);
  });

  test("maps mounted ranges through prefix and full-document deletion", () => {
    const prefix = ChangeSet.of({ from: 0, to: 3, insert: "" }, 10);
    expect(mapLivePreviewRange({ from: 5, to: 9 }, prefix, 7)).toEqual({ from: 2, to: 6 });
    const all = ChangeSet.of({ from: 0, to: 10, insert: "" }, 10);
    expect(mapLivePreviewRange({ from: 2, to: 8 }, all, 0)).toEqual({ from: 0, to: 0 });
  });
});
