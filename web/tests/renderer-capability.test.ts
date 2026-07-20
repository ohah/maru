import { describe, expect, test } from "bun:test";
import {
  capabilitiesEqual,
  fragmentChannel,
  fragmentMessageMatches,
  isFragmentInit,
  isFragmentRender,
  isFragmentRendered,
  type RendererCapability,
} from "../src/renderer-capability";

const capability: RendererCapability = {
  editorEpoch: 2,
  documentRevision: 3,
  projectionGeneration: 7,
  widgetId: 11,
  widgetGeneration: 13,
  rendererInstance: 17,
};

describe("fragment renderer capability", () => {
  test("requires every non-reusable identity field", () => {
    expect(isFragmentInit({ channel: fragmentChannel, type: "fragment-init", capability })).toBe(
      true,
    );
    for (const key of Object.keys(capability) as (keyof RendererCapability)[]) {
      expect(
        isFragmentInit({
          channel: fragmentChannel,
          type: "fragment-init",
          capability: { ...capability, [key]: key === "documentRevision" ? -1 : 0 },
        }),
      ).toBe(false);
    }
  });

  test("rejects stale or duplicate renderer identities", () => {
    expect(capabilitiesEqual(capability, capability)).toBe(true);
    const stale = { ...capability, widgetGeneration: capability.widgetGeneration - 1 };
    expect(capabilitiesEqual(capability, stale)).toBe(false);
    expect(capabilitiesEqual(capability, { ...capability, editorEpoch: 1 })).toBe(false);
    expect(
      fragmentMessageMatches(
        { channel: fragmentChannel, type: "fragment-rendered", capability: stale, height: 80 },
        capability,
      ),
    ).toBe(false);
  });

  test("bounds fragment HTML and measured height", () => {
    expect(
      isFragmentRender({
        channel: fragmentChannel,
        type: "fragment-render",
        capability,
        html: "<p>safe</p>",
      }),
    ).toBe(true);
    expect(
      isFragmentRendered({
        channel: fragmentChannel,
        type: "fragment-rendered",
        capability,
        height: Number.POSITIVE_INFINITY,
      }),
    ).toBe(false);
  });
});
