import { describe, expect, test } from "bun:test";
import { EditorRevisionClock, isEditableFileMode } from "../src/live-preview-state";

describe("live preview editor state", () => {
  test("read is inert while source and live modes share the editable buffer policy", () => {
    expect(isEditableFileMode("read")).toBe(false);
    expect(isEditableFileMode("source-edit")).toBe(true);
    expect(isEditableFileMode("live-preview")).toBe(true);
  });

  test("document revisions and projection generations advance independently", () => {
    const clock = new EditorRevisionClock();
    expect(clock.nextProjection()).toEqual({
      documentRevision: 0,
      projectionGeneration: 1,
    });
    clock.documentChanged();
    const snapshot = clock.nextProjection();
    expect(snapshot.documentRevision).toBe(1);
    expect(snapshot.projectionGeneration).toBe(2);
    expect(clock.nextProjection().documentRevision).toBe(1);
    expect(clock.projectionGeneration).toBe(3);
  });
});
