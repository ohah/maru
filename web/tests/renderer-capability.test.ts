import { describe, expect, test } from "bun:test";
import {
  atomicRendererChannel,
  atomicRendererMessageMatches,
  capabilitiesEqual,
  isAtomicRendererInit,
  isAtomicRendererRender,
  isAtomicRendererRendered,
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

describe("atomic renderer capability", () => {
  test("requires every non-reusable identity field", () => {
    expect(
      isAtomicRendererInit({
        channel: atomicRendererChannel,
        type: "atomic-init",
        capability,
      }),
    ).toBe(true);
    for (const key of Object.keys(capability) as (keyof RendererCapability)[]) {
      expect(
        isAtomicRendererInit({
          channel: atomicRendererChannel,
          type: "atomic-init",
          capability: { ...capability, [key]: key === "documentRevision" ? -1 : 0 },
        }),
      ).toBe(false);
    }
  });

  test("rejects stale renderer identities", () => {
    expect(capabilitiesEqual(capability, capability)).toBe(true);
    const stale = { ...capability, widgetGeneration: capability.widgetGeneration - 1 };
    expect(capabilitiesEqual(capability, stale)).toBe(false);
    expect(
      atomicRendererMessageMatches(
        {
          channel: atomicRendererChannel,
          type: "atomic-rendered",
          capability: stale,
          height: 80,
        },
        capability,
      ),
    ).toBe(false);
  });

  test("accepts only bounded pathless image assets and measured height", () => {
    expect(
      isAtomicRendererRender({
        channel: atomicRendererChannel,
        type: "atomic-render",
        capability,
        payload: '<img data-maru-asset-id="1">',
        assets: [{ opaqueId: 1, dataUrl: "data:image/png;base64,iVBORw0KGgo=" }],
      }),
    ).toBe(true);
    expect(
      isAtomicRendererRender({
        channel: atomicRendererChannel,
        type: "atomic-render",
        capability,
        payload: "<img>",
        assets: [{ opaqueId: 1, dataUrl: "file:///tmp/secret" }],
      }),
    ).toBe(false);
    expect(
      isAtomicRendererRendered({
        channel: atomicRendererChannel,
        type: "atomic-rendered",
        capability,
        height: Number.POSITIVE_INFINITY,
      }),
    ).toBe(false);
  });
});
